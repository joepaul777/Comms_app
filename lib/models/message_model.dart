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

  /// View-once media: how many times each person may open it (1 or 2), and how often they have.
  final int? viewLimit;
  final Map<String, int> viewedBy;

  /// Only used by the offline (nearby) chat, which never leaves the device.
  final String? localFilePath;

  /// Reactions: user id -> emoji.
  final Map<String, String> reactions;

  /// When the text was last edited, if ever.
  final DateTime? editedAt;

  /// Still on its way to the server (never stored).
  final bool pending;

  /// The end-to-end encrypted contents, as stored (see E2E). Null for old plain messages.
  final Map<String, dynamic>? enc;

  /// The key the contents were locked with; it also unlocks the photo, video or voice note.
  final List<int>? contentKey;

  /// Encrypted, but this phone can't unlock it (it was sent to another phone of yours).
  final bool locked;

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
    this.viewLimit,
    this.viewedBy = const {},
    this.localFilePath,
    this.reactions = const {},
    this.pending = false,
    this.editedAt,
    this.enc,
    this.contentKey,
    this.locked = false,
  });

  static const lockedText = "🔒 This message can't be read on this phone";

  bool get isEncrypted => enc != null;

  /// This message with its encrypted contents filled in, from what [E2E.open] gave back
  /// (null when it could not be unlocked).
  MessageModel withContents(Map<String, dynamic>? payload, List<int>? key) {
    final ok = payload != null;
    String? str(String k) => ok ? payload[k] as String? : null;
    return MessageModel(
      id: id,
      senderId: senderId,
      senderName: senderName,
      text: ok ? (str('t') ?? '') : lockedText,
      timestamp: timestamp,
      isRead: isRead,
      // Something this phone can't open is shown as a short note instead.
      type: ok ? type : MessageType.text,
      replyToId: replyToId,
      replyToText: str('r'),
      replyToSenderName: str('rn') ?? replyToSenderName,
      mediaUrl: str('u'),
      mediaName: str('m'),
      mediaSize: mediaSize,
      durationMs: durationMs,
      viewLimit: ok ? viewLimit : null,
      viewedBy: viewedBy,
      reactions: reactions,
      pending: pending,
      editedAt: editedAt,
      enc: enc,
      contentKey: key,
      locked: !ok,
    );
  }

  /// The encrypted parts of a message, before locking.
  static Map<String, dynamic> contentsOf({required String text, String? mediaUrl, String? mediaName, String? replyToText, String? replyToSenderName}) => {
        if (text.isNotEmpty) 't': text,
        if (mediaUrl != null) 'u': mediaUrl,
        if (mediaName != null) 'm': mediaName,
        if (replyToText != null) 'r': replyToText,
        if (replyToSenderName != null) 'rn': replyToSenderName,
      };

  /// Your own text message, sent recently enough to change.
  bool canEdit(String uid, Duration window) =>
      senderId == uid && type == MessageType.text && !pending && !locked && DateTime.now().difference(timestamp) < window;

  bool get isViewOnce => viewLimit != null && (type == MessageType.image || type == MessageType.video);

  /// Views left for this person (view-once media only).
  int viewsLeft(String uid) => (viewLimit ?? 0) - (viewedBy[uid] ?? 0);

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
      if (viewLimit != null) 'viewLimit': viewLimit,
      if (localFilePath != null) 'localFilePath': localFilePath,
      if (enc != null) 'enc': enc,
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
      viewLimit: (map['viewLimit'] as num?)?.toInt(),
      viewedBy: {
        for (final e in ((map['viewedBy'] as Map?) ?? const {}).entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      },
      localFilePath: map['localFilePath'],
      reactions: {
        for (final e in ((map['reactions'] as Map?) ?? const {}).entries)
          if (e.value is String) e.key.toString(): e.value as String,
      },
      pending: pending,
      editedAt: map['editedAt'] is int ? DateTime.fromMillisecondsSinceEpoch(map['editedAt']) : null,
      enc: map['enc'] is Map ? Map<String, dynamic>.from(map['enc'] as Map) : null,
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
