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
  final int? duration; // seconds

  /// Why the call stopped (see [EndReason]); empty while it is live.
  final String endReason;
  final String? endedBy;

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
    this.endReason = '',
    this.endedBy,
    this.offer,
    this.answer,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isVideo => type == CallType.video;
  bool get isOver => status == CallStatus.ended || status == CallStatus.missed || status == CallStatus.rejected;

  String otherId(String me) => me == callerId ? receiverId : callerId;
  String otherName(String me) => me == callerId ? receiverName : callerName;
  String otherPhoto(String me) => me == callerId ? receiverPhoto : callerPhoto;

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
      'endReason': endReason,
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
      type: CallType.values.firstWhere((e) => e.name == map['type'], orElse: () => CallType.audio),
      status: CallStatus.values.firstWhere((e) => e.name == map['status'], orElse: () => CallStatus.ended),
      timestamp: map['timestamp'] is int ? DateTime.fromMillisecondsSinceEpoch(map['timestamp']) : DateTime.now(),
      duration: (map['duration'] as num?)?.toInt(),
      endReason: map['endReason'] ?? '',
      endedBy: map['endedBy'],
      offer: map['offer'] != null ? Map<String, dynamic>.from(map['offer']) : null,
      answer: map['answer'] != null ? Map<String, dynamic>.from(map['answer']) : null,
    );
  }
}

enum CallType { audio, video }

/// Kept identical to version 1 so older phones still understand every call.
enum CallStatus { ringing, connected, ended, missed, rejected }

class EndReason {
  EndReason._();
  static const declined = 'declined';
  static const cancelled = 'cancelled';
  static const noAnswer = 'no-answer';
  static const busy = 'busy';
  static const hungUp = 'hung-up';
  static const failed = 'failed';
}
