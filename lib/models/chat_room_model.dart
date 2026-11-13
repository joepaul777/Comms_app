class ChatRoomModel {
  final String id;
  final ChatRoomType type;
  final List<String> participants;
  final String? groupName;
  final String? groupIcon;
  final String? adminId;
  final String lastMessage;
  final String lastMessageSenderId;
  final DateTime lastMessageTime;
  final Map<String, int> unreadCount;
  final DateTime createdAt;

  /// Who is typing right now: user id -> a value that changes while they keep typing.
  final Map<String, int> typing;

  /// Read receipts: user id -> timestamp of the newest message they have seen,
  /// and when (by their clock) they saw it.
  final Map<String, int> readUpTo;
  final Map<String, int> readAt;

  ChatRoomModel({
    required this.id,
    required this.type,
    required this.participants,
    this.groupName,
    this.groupIcon,
    this.adminId,
    this.lastMessage = '',
    this.lastMessageSenderId = '',
    DateTime? lastMessageTime,
    this.unreadCount = const {},
    DateTime? createdAt,
    this.typing = const {},
    this.readUpTo = const {},
    this.readAt = const {},
  })  : lastMessageTime = lastMessageTime ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      'participants': participants,
      'groupName': groupName,
      'groupIcon': groupIcon,
      'adminId': adminId,
      'lastMessage': lastMessage,
      'lastMessageSenderId': lastMessageSenderId,
      'lastMessageTime': lastMessageTime.millisecondsSinceEpoch,
      'unreadCount': unreadCount,
      'createdAt': createdAt.millisecondsSinceEpoch,
    };
  }

  factory ChatRoomModel.fromMap(Map<String, dynamic> map) {
    return ChatRoomModel(
      id: map['id'] ?? '',
      type: ChatRoomType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => ChatRoomType.direct,
      ),
      participants: List<String>.from(map['participants'] ?? []),
      groupName: map['groupName'],
      groupIcon: map['groupIcon'],
      adminId: map['adminId'],
      lastMessage: map['lastMessage'] ?? '',
      lastMessageSenderId: map['lastMessageSenderId'] ?? '',
      lastMessageTime: map['lastMessageTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['lastMessageTime'])
          : DateTime.now(),
      unreadCount: Map<String, int>.from(map['unreadCount'] ?? {}),
      createdAt: map['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['createdAt'])
          : DateTime.now(),
      readUpTo: _ints(map['readUpTo']),
      readAt: _ints(map['readAt']),
      typing: {
        for (final e in ((map['typing'] as Map?) ?? const {}).entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      },
    );
  }

  ChatRoomModel copyWith({
    String? lastMessage,
    String? lastMessageSenderId,
    DateTime? lastMessageTime,
    Map<String, int>? unreadCount,
    List<String>? participants,
    String? groupName,
    String? groupIcon,
  }) {
    return ChatRoomModel(
      id: id,
      type: type,
      participants: participants ?? this.participants,
      groupName: groupName ?? this.groupName,
      groupIcon: groupIcon ?? this.groupIcon,
      adminId: adminId,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageSenderId: lastMessageSenderId ?? this.lastMessageSenderId,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt,
    );
  }

  bool get isGroup => type == ChatRoomType.group;

  static Map<String, int> _ints(dynamic raw) => {
        for (final e in ((raw as Map?) ?? const {}).entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      };
}

enum ChatRoomType {
  direct,
  group,
}
