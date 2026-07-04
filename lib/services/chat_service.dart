import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_room_model.dart';
import '../models/message_model.dart';

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

  // Get chat rooms for a user
  Stream<List<ChatRoomModel>> getChatRooms(String uid) {
    return _firestore
        .collection('chatRooms')
        .where('participants', arrayContains: uid)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ChatRoomModel.fromMap(doc.data()))
            .toList());
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
  }) async {
    final message = MessageModel(
      id: _uuid.v4(),
      senderId: senderId,
      senderName: senderName,
      text: text,
      timestamp: DateTime.now(),
      type: type,
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
