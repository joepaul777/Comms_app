class MessageModel {
  final String id;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime timestamp;
  final bool isRead;
  final MessageType type;

  // Reply fields
  final String? replyToId;
  final String? replyToText;
  final String? replyToSenderName;

  MessageModel({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    this.isRead = false,
    this.type = MessageType.text,
    this.replyToId,
    this.replyToText,
    this.replyToSenderName,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'text': text,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isRead': isRead,
      'type': type.name,
      if (replyToId != null) 'replyToId': replyToId,
      if (replyToText != null) 'replyToText': replyToText,
      if (replyToSenderName != null) 'replyToSenderName': replyToSenderName,
    };
  }

  factory MessageModel.fromMap(Map<String, dynamic> map) {
    return MessageModel(
      id: map['id'] ?? '',
      senderId: map['senderId'] ?? '',
      senderName: map['senderName'] ?? '',
      text: map['text'] ?? '',
      timestamp: map['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['timestamp'])
          : DateTime.now(),
      isRead: map['isRead'] ?? false,
      type: MessageType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => MessageType.text,
      ),
      replyToId: map['replyToId'],
      replyToText: map['replyToText'],
      replyToSenderName: map['replyToSenderName'],
    );
  }
}

enum MessageType {
  text,
  image,
  system,
}
