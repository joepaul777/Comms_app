class MessageModel {
  final String id;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime timestamp;
  final bool isRead;
  final MessageType type;

  // Reply
  final String? replyToId;
  final String? replyToText;
  final String? replyToSenderName;

  // Media (the link is temporary; each phone keeps its own copy)
  final String? mediaUrl;
  final String? mediaName;
  final int? mediaSize;
  final int? durationMs;

  /// Only used by the offline (nearby) chat, which never leaves the device.
  final String? localFilePath;

  /// Reactions: user id -> emoji.
  final Map<String, String> reactions;

  /// When the text was last edited, if ever.
  final DateTime? editedAt;

  /// Still on its way to the server (never stored).
  final bool pending;

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
    this.mediaUrl,
    this.mediaName,
    this.mediaSize,
    this.durationMs,
    this.localFilePath,
    this.reactions = const {},
    this.pending = false,
    this.editedAt,
  });

  /// Your own text message, sent recently enough to change.
  bool canEdit(String uid, Duration window) =>
      senderId == uid && type == MessageType.text && !pending && DateTime.now().difference(timestamp) < window;

  bool get isMedia => type == MessageType.image || type == MessageType.video || type == MessageType.audio;

  /// When the online copy of the media disappears.
  DateTime get mediaExpiresAt => timestamp.add(const Duration(minutes: 60));

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
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (mediaName != null) 'mediaName': mediaName,
      if (mediaSize != null) 'mediaSize': mediaSize,
      if (durationMs != null) 'durationMs': durationMs,
      if (localFilePath != null) 'localFilePath': localFilePath,
    };
  }

  factory MessageModel.fromMap(Map<String, dynamic> map, {bool pending = false}) {
    return MessageModel(
      id: map['id'] ?? '',
      senderId: map['senderId'] ?? '',
      senderName: map['senderName'] ?? '',
      text: map['text'] ?? '',
      timestamp: map['timestamp'] is int
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
      mediaUrl: map['mediaUrl'],
      mediaName: map['mediaName'],
      mediaSize: (map['mediaSize'] as num?)?.toInt(),
      durationMs: (map['durationMs'] as num?)?.toInt(),
      localFilePath: map['localFilePath'],
      reactions: {
        for (final e in ((map['reactions'] as Map?) ?? const {}).entries)
          if (e.value is String) e.key.toString(): e.value as String,
      },
      pending: pending,
      editedAt: map['editedAt'] is int ? DateTime.fromMillisecondsSinceEpoch(map['editedAt']) : null,
    );
  }
}

enum MessageType {
  text,
  image,
  video,
  audio,
  gif,
  system,
}
