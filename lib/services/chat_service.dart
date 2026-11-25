import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../config.dart';
import '../models/chat_room_model.dart';
import '../models/message_model.dart';
import '../models/user_model.dart';
import 'e2e_service.dart';
import 'push_api.dart';
import 'rate_limiter.dart';
import 'shared_stream.dart';
import 'user_service.dart';

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
    return _db.collection('chatRooms').where('participants', arrayContains: uid).snapshots().asyncMap((snapshot) async {
      final rooms = <ChatRoomModel>[];
      for (final d in snapshot.docs) {
        rooms.add(await _openPreview(ChatRoomModel.fromMap(d.data())));
      }
      rooms.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
      return rooms;
    });
  }

  static const lockedPreview = '🔒 Message';

  /// Fills in the chat list preview from its encrypted copy.
  Future<ChatRoomModel> _openPreview(ChatRoomModel room) async {
    final enc = room.lastEnc;
    if (enc == null) return room;
    final opened = await E2E.instance.open(enc, aad: E2E.lastAad(room.id));
    return room.copyWith(lastMessage: opened?.payload['t'] as String? ?? lockedPreview);
  }

  /// Unlocks an encrypted message (plain old messages pass straight through).
  Future<MessageModel> _open(String roomId, MessageModel m) async {
    final enc = m.enc;
    if (enc == null) return m;
    final opened = await E2E.instance.open(enc, aad: E2E.messageAad(roomId, m.id));
    return m.withContents(opened?.payload, opened?.contentKey);
  }

  /// Everyone in the chat who can receive encrypted messages: user id -> public key.
  /// In a two-person chat the other person must have a key; in a group, anyone still
  /// on an old version is left out (and sees "update Comms to read this").
  Future<Map<String, String>> recipientKeys(ChatRoomModel room, String myUid) async {
    if (!await E2E.instance.ready() || E2E.instance.uid != myUid) {
      throw StateError('Encryption is not set up on this phone');
    }
    final others = room.participants.where((id) => id != myUid).toList();
    // Keys can change (a new phone), so don't trust a copy older than a few minutes.
    final users = {for (final u in await UserService.instance.getUsers(others, maxAge: const Duration(minutes: 5))) u.uid: u};
    final keys = <String, String>{myUid: E2E.instance.publicKey!};
    final missing = <String>[];
    for (final id in others) {
      var key = users[id]?.publicKey;
      // They may have only just updated.
      key ??= (await UserService.instance.getUser(id, fresh: true))?.publicKey;
      if (key == null) {
        missing.add(id);
      } else {
        keys[id] = key;
      }
    }
    if (missing.isNotEmpty && !room.isGroup) throw NoKeyException(missing);
    return keys;
  }

  Stream<ChatRoomModel?> chatRoom(String id) {
    return _db.collection('chatRooms').doc(id).snapshots().map((d) => d.exists ? ChatRoomModel.fromMap(d.data()!) : null);
  }

  final Map<String, SharedStream<List<MessageModel>>> _messageStreams = {};

  /// The newest [limit] messages, newest first (which suits a reversed list).
  /// Shared between screens, and only messages that changed are read again.
  Stream<List<MessageModel>> messages(String roomId, {int limit = 60}) {
    final key = '$roomId|$limit';
    return (_messageStreams[key] ??= SharedStream<List<MessageModel>>(
      () {
        final parsed = <String, MessageModel>{};
        return _db
            .collection('chatRooms')
            .doc(roomId)
            .collection('messages')
            .orderBy('timestamp', descending: true)
            .limit(limit)
            .snapshots(includeMetadataChanges: true)
            .asyncMap((s) async {
          for (final change in s.docChanges) {
            if (change.type == DocumentChangeType.removed) {
              parsed.remove(change.doc.id);
            } else {
              parsed[change.doc.id] = await _open(roomId, MessageModel.fromMap(change.doc.data()!, pending: change.doc.metadata.hasPendingWrites));
            }
          }
          final list = <MessageModel>[];
          for (final d in s.docs) {
            final m = parsed[d.id];
            if (m != null && m.pending == d.metadata.hasPendingWrites) {
              list.add(m);
            } else {
              list.add(parsed[d.id] = await _open(roomId, MessageModel.fromMap(d.data(), pending: d.metadata.hasPendingWrites)));
            }
          }
          return list;
        });
      },
      onClosed: () => _messageStreams.remove(key),
    ))
        .stream;
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
    int? viewLimit,
    MessageModel? replyTo,
    List<int>? contentKey,
    bool walkie = false,
  }) async {
    if (type != MessageType.system) _gate.check();
    final replyText = replyTo == null ? null : previewFor(replyTo.type, replyTo.text);
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
      viewLimit: viewLimit,
      replyToId: replyTo?.id,
      replyToText: replyText,
      replyToSenderName: replyTo?.senderName,
    );

    var stored = message.toMap();
    var preview = viewLimit != null
        ? (type == MessageType.video ? '🎥 View-once video' : '📷 View-once photo')
        : walkie
            ? '📻 Walkie-talkie'
            : previewFor(type, text);
    Map<String, dynamic>? lastEnc;
    if (type != MessageType.system) {
      // Only the people in the chat can read what is in it; the database just holds scrambled bytes.
      final keys = await recipientKeys(room, sender.uid);
      final contents = MessageModel.contentsOf(
        text: text,
        mediaUrl: mediaUrl,
        mediaName: mediaName,
        replyToText: replyText,
        replyToSenderName: replyTo?.senderName,
        walkie: walkie,
      );
      final enc = await E2E.instance.seal(contents, keys, aad: E2E.messageAad(room.id, message.id), contentKey: contentKey);
      stored = {
        for (final e in stored.entries)
          if (!const {'mediaUrl', 'mediaName', 'replyToText', 'replyToSenderName'}.contains(e.key)) e.key: e.value,
        'text': E2E.compatText,
        'enc': enc,
      };
      lastEnc = await E2E.instance.seal({'t': preview}, keys, aad: E2E.lastAad(room.id));
      // What shows where the preview can't be unlocked: never the words themselves.
      if (type == MessageType.text) preview = lockedPreview;
    }

    final current = me?.uid == sender.uid ? me! : sender;
    final newWindow = SendGate.startsNewWindow(current.msgWindowStart, const Duration(minutes: 1), DateTime.now());

    Future<void> commit(bool startWindow) {
      final batch = _db.batch();
      final roomRef = _db.collection('chatRooms').doc(room.id);
      batch.set(roomRef.collection('messages').doc(message.id), stored);
      batch.update(roomRef, {
        'lastMessage': preview,
        'lastEnc': lastEnc ?? FieldValue.delete(),
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

  /// Records that this person has seen everything up to [upTo] (a message timestamp).
  Future<void> markSeen(String roomId, String uid, int upTo) async {
    try {
      await _db.collection('chatRooms').doc(roomId).update({
        'readUpTo.$uid': upTo,
        'readAt.$uid': DateTime.now().millisecondsSinceEpoch,
        'unreadCount.$uid': 0,
      });
    } catch (e) {
      debugPrint('markSeen failed: $e');
    }
  }

  /// Changes the words of one of your own recent text messages.
  Future<void> editMessage(ChatRoomModel room, MessageModel message, String text) async {
    final keys = await recipientKeys(room, message.senderId);
    final contents = MessageModel.contentsOf(text: text, replyToText: message.replyToText, replyToSenderName: message.replyToSenderName);
    final batch = _db.batch();
    final roomRef = _db.collection('chatRooms').doc(room.id);
    batch.update(roomRef.collection('messages').doc(message.id), {
      'text': E2E.compatText,
      'enc': await E2E.instance.seal(contents, keys, aad: E2E.messageAad(room.id, message.id)),
      'editedAt': DateTime.now().millisecondsSinceEpoch,
    });
    // Keep the chat list preview right when the newest message is the one edited.
    if (room.lastMessageSenderId == message.senderId &&
        room.lastMessageTime.millisecondsSinceEpoch == message.timestamp.millisecondsSinceEpoch) {
      batch.update(roomRef, {
        'lastMessage': lockedPreview,
        'lastEnc': await E2E.instance.seal({'t': text}, keys, aad: E2E.lastAad(room.id)),
      });
    }
    await batch.commit();
  }

  /// Uses up one view of a view-once photo or video. Returns how many times this person
  /// has now opened it, or null when there are no views left.
  Future<int?> useView(String roomId, String messageId, String uid) {
    final ref = _db.collection('chatRooms').doc(roomId).collection('messages').doc(messageId);
    return _db.runTransaction<int?>((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data();
      if (data == null) return null;
      final limit = (data['viewLimit'] as num?)?.toInt() ?? 0;
      final seen = ((data['viewedBy'] as Map?)?[uid] as num?)?.toInt() ?? 0;
      if (seen >= limit) return null;
      tx.update(ref, {'viewedBy.$uid': seen + 1});
      return seen + 1;
    });
  }

  /// Sets this person's reaction to a message, or removes it when [emoji] is null.
  Future<void> react(String roomId, String messageId, String uid, String? emoji) {
    return _db.collection('chatRooms').doc(roomId).collection('messages').doc(messageId).update({
      'reactions.$uid': emoji ?? FieldValue.delete(),
    });
  }

  /// Lets the others in the chat see that this person is typing.
  Future<void> setTyping(String roomId, String uid, bool typing) async {
    try {
      await _db.collection('chatRooms').doc(roomId).update({
        'typing.$uid': typing ? DateTime.now().millisecondsSinceEpoch : FieldValue.delete(),
      });
    } catch (_) {
      // Only a hint; never worth bothering the person about.
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
