import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_room_model.dart';
import '../models/message_model.dart';
import 'notification_service.dart';

class ChatService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Uuid _uuid = const Uuid();

  // Get or create a direct chat room between two users
  Future<ChatRoomModel> getOrCreateDirectChat(
    String currentUid,
    String otherUid,
  ) async {
    // Check if a direct chat already exists between these users
    final query = await _firestore
        .collection('chatRooms')
        .where('type', isEqualTo: ChatRoomType.direct.name)
        .where('participants', arrayContains: currentUid)
        .get();

    for (final doc in query.docs) {
      final participants = List<String>.from(doc.data()['participants']);
      if (participants.contains(otherUid) && participants.length == 2) {
        return ChatRoomModel.fromMap(doc.data());
      }
    }

    // Create new direct chat room
    final chatRoom = ChatRoomModel(
      id: _uuid.v4(),
      type: ChatRoomType.direct,
      participants: [currentUid, otherUid],
    );

    await _firestore
        .collection('chatRooms')
        .doc(chatRoom.id)
        .set(chatRoom.toMap());

    return chatRoom;
  }

  // Create a group chat
  Future<ChatRoomModel> createGroupChat({
    required String adminId,
    required String groupName,
    required List<String> memberIds,
  }) async {
    final participants = [adminId, ...memberIds];
    final chatRoom = ChatRoomModel(
      id: _uuid.v4(),
      type: ChatRoomType.group,
      participants: participants,
      groupName: groupName,
      adminId: adminId,
    );

    await _firestore
        .collection('chatRooms')
        .doc(chatRoom.id)
        .set(chatRoom.toMap());

    // Send system message
    await sendMessage(
      chatRoomId: chatRoom.id,
      senderId: adminId,
      senderName: 'System',
      text: 'Group "$groupName" created',
      type: MessageType.system,
    );

    return chatRoom;
  }

  // Get chat rooms for a user — sorted client-side to avoid needing a composite index
  Stream<List<ChatRoomModel>> getChatRooms(String uid) {
    return _firestore
        .collection('chatRooms')
        .where('participants', arrayContains: uid)
        .snapshots()
        .map((snapshot) {
      final rooms = snapshot.docs
          .map((doc) => ChatRoomModel.fromMap(doc.data()))
          .toList();
      // Sort by lastMessageTime descending (most recent first)
      rooms.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
      return rooms;
    });
  }

  // Get messages in a chat room
  Stream<List<MessageModel>> getMessages(String chatRoomId) {
    return _firestore
        .collection('chatRooms')
        .doc(chatRoomId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => MessageModel.fromMap(doc.data()))
            .toList());
  }

  // Send a message
  Future<void> sendMessage({
    required String chatRoomId,
    required String senderId,
    required String senderName,
    required String text,
    MessageType type = MessageType.text,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
  }) async {
    final message = MessageModel(
      id: _uuid.v4(),
      senderId: senderId,
      senderName: senderName,
      text: text,
      timestamp: DateTime.now(),
      type: type,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
    );

    final batch = _firestore.batch();

    // Add message
    batch.set(
      _firestore
          .collection('chatRooms')
          .doc(chatRoomId)
          .collection('messages')
          .doc(message.id),
      message.toMap(),
    );

    // Update chat room last message
    batch.update(
      _firestore.collection('chatRooms').doc(chatRoomId),
      {
        'lastMessage': text,
        'lastMessageSenderId': senderId,
        'lastMessageTime': DateTime.now().millisecondsSinceEpoch,
      },
    );

    await batch.commit();

    // Send push notifications to all participants except the sender
    _sendMessageNotifications(
      chatRoomId: chatRoomId,
      senderId: senderId,
      senderName: senderName,
      text: text,
    );
  }

  /// Look up each participant's FCM token and send them a push notification
  Future<void> _sendMessageNotifications({
    required String chatRoomId,
    required String senderId,
    required String senderName,
    required String text,
  }) async {
    try {
      final chatRoomDoc =
          await _firestore.collection('chatRooms').doc(chatRoomId).get();
      if (!chatRoomDoc.exists) return;

      final chatRoom = ChatRoomModel.fromMap(chatRoomDoc.data()!);
      final recipients =
          chatRoom.participants.where((id) => id != senderId).toList();

      final isGroup = chatRoom.isGroup;
      final chatName =
          isGroup ? (chatRoom.groupName ?? 'Group Chat') : senderName;
      final body = isGroup ? '$senderName: $text' : text;

      for (final uid in recipients) {
        final userDoc = await _firestore.collection('users').doc(uid).get();
        final fcmToken = userDoc.data()?['fcmToken'] as String?;
        if (fcmToken == null || fcmToken.isEmpty) continue;

        NotificationService.sendPushNotification(
          recipientFcmToken: fcmToken,
          title: chatName,
          message: body,
          data: {'type': 'chat', 'id': chatRoomId},
        );
      }
    } catch (_) {
      // Notification failure should never crash the chat
    }
  }

  // Mark messages as read
  Future<void> markMessagesAsRead(String chatRoomId, String uid) async {
    await _firestore.collection('chatRooms').doc(chatRoomId).update({
      'unreadCount.$uid': 0,
    });
  }

  // Add member to group
  Future<void> addMemberToGroup(String chatRoomId, String memberId) async {
    await _firestore.collection('chatRooms').doc(chatRoomId).update({
      'participants': FieldValue.arrayUnion([memberId]),
    });
  }

  // Remove member from group
  Future<void> removeMemberFromGroup(
      String chatRoomId, String memberId) async {
    await _firestore.collection('chatRooms').doc(chatRoomId).update({
      'participants': FieldValue.arrayRemove([memberId]),
    });
  }

  // Get a chat room by ID
  Stream<ChatRoomModel?> getChatRoom(String chatRoomId) {
    return _firestore
        .collection('chatRooms')
        .doc(chatRoomId)
        .snapshots()
        .map((doc) => doc.exists ? ChatRoomModel.fromMap(doc.data()!) : null);
  }

  // Delete a chat room
  Future<void> deleteChatRoom(String chatRoomId) async {
    // Delete all messages first
    final messages = await _firestore
        .collection('chatRooms')
        .doc(chatRoomId)
        .collection('messages')
        .get();

    final batch = _firestore.batch();
    for (final doc in messages.docs) {
      batch.delete(doc.reference);
    }
    batch.delete(_firestore.collection('chatRooms').doc(chatRoomId));
    await batch.commit();
  }
}
