import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String name;
  final String email;
  final String photoUrl;
  final bool isOnline;
  final DateTime lastSeen;
  final List<String> contacts;
  final DateTime createdAt;

  /// Set while this person is ringing or on a call, so others see them as busy.
  final DateTime? busyUntil;

  /// Their phone's public encryption key (see E2E). Null on old versions of Comms.
  final String? publicKey;

  // Sending limits (written together with each message or call, checked by the database)
  final Timestamp? lastMessageAt;
  final Timestamp? msgWindowStart;
  final int msgWindowCount;
  final Timestamp? lastCallAt;
  final Timestamp? callWindowStart;
  final int callWindowCount;

  UserModel({
    required this.uid,
    required this.name,
    required this.email,
    this.photoUrl = '',
    this.isOnline = false,
    DateTime? lastSeen,
    this.contacts = const [],
    DateTime? createdAt,
    this.busyUntil,
    this.publicKey,
    this.lastMessageAt,
    this.msgWindowStart,
    this.msgWindowCount = 0,
    this.lastCallAt,
    this.callWindowStart,
    this.callWindowCount = 0,
  })  : lastSeen = lastSeen ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  bool get isBusy => busyUntil != null && busyUntil!.isAfter(DateTime.now());

  /// Fields for a brand new user document (the database refuses rate fields here).
  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'nameLower': name.toLowerCase(),
      'email': email,
      'photoUrl': photoUrl,
      'isOnline': isOnline,
      'lastSeen': lastSeen.millisecondsSinceEpoch,
      'createdAt': createdAt.millisecondsSinceEpoch,
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map) {
    DateTime? millis(dynamic v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    return UserModel(
      uid: map['uid'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      photoUrl: map['photoUrl'] ?? '',
      isOnline: map['isOnline'] ?? false,
      lastSeen: millis(map['lastSeen']),
      contacts: List<String>.from(map['contacts'] ?? const []),
      createdAt: millis(map['createdAt']),
      busyUntil: millis(map['busyUntil']),
      publicKey: map['publicKey'] is String && (map['publicKey'] as String).isNotEmpty ? map['publicKey'] as String : null,
      lastMessageAt: map['lastMessageAt'] is Timestamp ? map['lastMessageAt'] : null,
      msgWindowStart: map['msgWindowStart'] is Timestamp ? map['msgWindowStart'] : null,
      msgWindowCount: (map['msgWindowCount'] as num?)?.toInt() ?? 0,
      lastCallAt: map['lastCallAt'] is Timestamp ? map['lastCallAt'] : null,
      callWindowStart: map['callWindowStart'] is Timestamp ? map['callWindowStart'] : null,
      callWindowCount: (map['callWindowCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// The same person with their private contact list (kept apart from the public profile).
  UserModel withContacts(List<String> list) => UserModel(
        uid: uid,
        name: name,
        email: email,
        photoUrl: photoUrl,
        isOnline: isOnline,
        lastSeen: lastSeen,
        contacts: list,
        createdAt: createdAt,
        busyUntil: busyUntil,
        publicKey: publicKey,
        lastMessageAt: lastMessageAt,
        msgWindowStart: msgWindowStart,
        msgWindowCount: msgWindowCount,
        lastCallAt: lastCallAt,
        callWindowStart: callWindowStart,
        callWindowCount: callWindowCount,
      );

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return parts.isNotEmpty ? parts[0][0].toUpperCase() : '?';
  }

  String get firstName => name.trim().split(RegExp(r'\s+')).first;
}
