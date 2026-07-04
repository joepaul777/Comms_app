class CallModel {
  final String id;
  final String callerId;
  final String callerName;
  final String callerPhoto;
  final String receiverId;
  final String receiverName;
  final String receiverPhoto;
  final CallType type;
  final CallStatus status;
  final DateTime timestamp;
  final int? duration; // in seconds

  // WebRTC signaling
  final Map<String, dynamic>? offer;
  final Map<String, dynamic>? answer;

  CallModel({
    required this.id,
    required this.callerId,
    required this.callerName,
    this.callerPhoto = '',
    required this.receiverId,
    required this.receiverName,
    this.receiverPhoto = '',
    required this.type,
    this.status = CallStatus.ringing,
    DateTime? timestamp,
    this.duration,
    this.offer,
    this.answer,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'callerId': callerId,
      'callerName': callerName,
      'callerPhoto': callerPhoto,
      'receiverId': receiverId,
      'receiverName': receiverName,
      'receiverPhoto': receiverPhoto,
      'type': type.name,
      'status': status.name,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'duration': duration,
      'offer': offer,
      'answer': answer,
    };
  }

  factory CallModel.fromMap(Map<String, dynamic> map) {
    return CallModel(
      id: map['id'] ?? '',
      callerId: map['callerId'] ?? '',
      callerName: map['callerName'] ?? '',
      callerPhoto: map['callerPhoto'] ?? '',
      receiverId: map['receiverId'] ?? '',
      receiverName: map['receiverName'] ?? '',
      receiverPhoto: map['receiverPhoto'] ?? '',
      type: CallType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => CallType.audio,
      ),
      status: CallStatus.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => CallStatus.ringing,
      ),
      timestamp: map['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['timestamp'])
          : DateTime.now(),
      duration: map['duration'],
      offer: map['offer'] != null
          ? Map<String, dynamic>.from(map['offer'])
          : null,
      answer: map['answer'] != null
          ? Map<String, dynamic>.from(map['answer'])
          : null,
    );
  }

  CallModel copyWith({
    CallStatus? status,
    int? duration,
    Map<String, dynamic>? offer,
    Map<String, dynamic>? answer,
  }) {
    return CallModel(
      id: id,
      callerId: callerId,
      callerName: callerName,
      callerPhoto: callerPhoto,
      receiverId: receiverId,
      receiverName: receiverName,
      receiverPhoto: receiverPhoto,
      type: type,
      status: status ?? this.status,
      timestamp: timestamp,
      duration: duration ?? this.duration,
      offer: offer ?? this.offer,
      answer: answer ?? this.answer,
    );
  }
}

enum CallType {
  audio,
  video,
}

enum CallStatus {
  ringing,
  connected,
  ended,
  missed,
  rejected,
}
