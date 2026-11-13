import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../config.dart';
import '../models/chat_room_model.dart';
import '../models/message_model.dart';
import '../models/user_model.dart';
import 'push_api.dart';
import 'rate_limiter.dart';

class ChatService {
  ChatService._();
  static final ChatService instance = ChatService._();
  factory ChatService() => instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Uuid _uuid = const Uuid();

  final SendGate _gate = SendGate(
    minGap: AppConfig.minMessageGap,
    maxPerWindow: AppConfig.messagesPerMinute,
    window: const Duration(minutes: 1),
    noun: 'messages',
  );

  /// The signed-in user's own document, kept fresh so sends know the current limits.
  UserModel? me;

  String newId() => _uuid.v4();

  /// Throws [RateLimitException] if a message can't be sent right now.
  void checkCanSend() => _gate.check();

  Future<ChatRoomModel> getOrCreateDirectChat(String myUid, String otherUid) async {
    final existing = await _db
        .collection('chatRooms')
        .where('participants', arrayContains: myUid)
        .where('type', isEqualTo: ChatRoomType.direct.name)
        .get();
    for (final doc in existing.docs) {
      final room = ChatRoomModel.fromMap(doc.data());
      if (room.participants.length == 2 && room.participants.contains(otherUid)) return room;
    }
    // A fixed id means two people starting a chat at the same moment get the same room.
    final ids = [myUid, otherUid]..sort();
    final room = ChatRoomModel(id: 'dm_${ids[0]}_${ids[1]}', type: ChatRoomType.direct, participants: ids);
    // Merge only the fixed fields, so a chat the other person just created keeps its messages summary.
    await _db.collection('chatRooms').doc(room.id).set({
      'id': room.id,
      'type': room.type.name,
      'participants': room.participants,
      'createdAt': room.createdAt.millisecondsSinceEpoch,
    }, SetOptions(merge: true));
    return room;
  }

  Future<ChatRoomModel> createGroupChat({
    required UserModel admin,
    required String groupName,
    required List<String> memberIds,
  }) async {
    final room = ChatRoomModel(
      id: newId(),
      type: ChatRoomType.group,
      participants: [admin.uid, ...memberIds.where((id) => id != admin.uid)],
      groupName: groupName.trim(),
      adminId: admin.uid,
    );
    await _db.collection('chatRooms').doc(room.id).set(room.toMap());
    await sendMessage(room: room, sender: admin, text: '${admin.firstName} created "${room.groupName}"', type: MessageType.system);
    return room;
  }

  Stream<List<ChatRoomModel>> chatRooms(String uid) {
    return _db.collection('chatRooms').where('participants', arrayContains: uid).snapshots().map((snapshot) {
      final rooms = snapshot.docs.map((d) => ChatRoomModel.fromMap(d.data())).toList();
      rooms.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
      return rooms;
    });
  }

  Stream<ChatRoomModel?> chatRoom(String id) {
    return _db.collection('chatRooms').doc(id).snapshots().map((d) => d.exists ? ChatRoomModel.fromMap(d.data()!) : null);
  }

  /// Newest first, which suits a reversed chat list.
  Stream<List<MessageModel>> messages(String roomId, {int limit = 300}) {
    return _db
        .collection('chatRooms')
        .doc(roomId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map((d) => MessageModel.fromMap(d.data())).toList());
  }

  static String previewFor(MessageType type, String text) {
    switch (type) {
      case MessageType.image:
        return '📷 Photo';
      case MessageType.video:
        return '🎥 Video';
      case MessageType.audio:
        return '🎤 Voice message';
      case MessageType.gif:
        return 'GIF';
      default:
        return text;
    }
  }

  /// Sends a message. The database only accepts it together with an update to the
  /// sender's rate fields, which is what keeps people from flooding a chat.
  Future<void> sendMessage({
    required ChatRoomModel room,
    required UserModel sender,
    required String text,
    MessageType type = MessageType.text,
    String? id,
    String? mediaUrl,
    String? mediaName,
    int? mediaSize,
    int? durationMs,
    MessageModel? replyTo,
  }) async {
    if (type != MessageType.system) _gate.check();
    final message = MessageModel(
      id: id ?? newId(),
      senderId: sender.uid,
      senderName: sender.name,
      text: text,
      timestamp: DateTime.now(),
      type: type,
      mediaUrl: mediaUrl,
      mediaName: mediaName,
      mediaSize: mediaSize,
      durationMs: durationMs,
      replyToId: replyTo?.id,
      replyToText: replyTo == null ? null : previewFor(replyTo.type, replyTo.text),
      replyToSenderName: replyTo?.senderName,
    );

    final current = me?.uid == sender.uid ? me! : sender;
    final newWindow = SendGate.startsNewWindow(current.msgWindowStart, const Duration(minutes: 1), DateTime.now());

    Future<void> commit(bool startWindow) {
      final batch = _db.batch();
      final roomRef = _db.collection('chatRooms').doc(room.id);
      batch.set(roomRef.collection('messages').doc(message.id), message.toMap());
      batch.update(roomRef, {
        'lastMessage': previewFor(type, text),
        'lastMessageSenderId': sender.uid,
        'lastMessageTime': message.timestamp.millisecondsSinceEpoch,
        for (final uid in room.participants)
          if (uid != sender.uid && type != MessageType.system) 'unreadCount.$uid': FieldValue.increment(1),
      });
      batch.update(
        _db.collection('users').doc(sender.uid),
        SendGate.fields(lastField: 'lastMessageAt', startField: 'msgWindowStart', countField: 'msgWindowCount', newWindow: startWindow),
      );
      return batch.commit();
    }

    _gate.record();
    try {
      await commit(newWindow);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      // Our guess about the one-minute window was off; the other answer should be right.
      await Future.delayed(const Duration(milliseconds: 750));
      try {
        await commit(!newWindow);
      } on FirebaseException catch (e2) {
        if (e2.code == 'permission-denied') {
          throw RateLimitException(const Duration(seconds: 5), 'Too many messages. Wait a moment');
        }
        rethrow;
      }
    }
    if (type != MessageType.system) unawaited(PushApi.message(room.id, message.id));
  }

  Future<void> markRead(ChatRoomModel room, String uid) async {
    if ((room.unreadCount[uid] ?? 0) == 0) return;
    try {
      await _db.collection('chatRooms').doc(room.id).update({'unreadCount.$uid': 0});
    } catch (e) {
      debugPrint('markRead failed: $e');
    }
  }

  Future<void> deleteMessage(String roomId, String messageId) {
    return _db.collection('chatRooms').doc(roomId).collection('messages').doc(messageId).delete();
  }

  Future<void> addMember(String roomId, String uid) {
    return _db.collection('chatRooms').doc(roomId).update({'participants': FieldValue.arrayUnion([uid])});
  }

  Future<void> removeMember(String roomId, String uid) {
    return _db.collection('chatRooms').doc(roomId).update({'participants': FieldValue.arrayRemove([uid])});
  }

  Future<void> renameGroup(String roomId, String name) {
    return _db.collection('chatRooms').doc(roomId).update({'groupName': name.trim()});
  }

  /// Deletes a chat and its messages for everyone in it.
  Future<void> deleteChat(String roomId) async {
    final roomRef = _db.collection('chatRooms').doc(roomId);
    while (true) {
      final page = await roomRef.collection('messages').limit(400).get();
      if (page.docs.isEmpty) break;
      final batch = _db.batch();
      for (final doc in page.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
    await roomRef.delete();
  }
}
