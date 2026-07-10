import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../models/call_model.dart';
import 'notification_service.dart';

class CallService {
  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Uuid _uuid = const Uuid();

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  StreamSubscription? _callSubscription;
  StreamSubscription? _callerCandidatesSubscription;
  StreamSubscription? _receiverCandidatesSubscription;

  // Guard against re-entrant cleanup
  bool _isCleaningUp = false;

  // Track call connection time for duration
  DateTime? _connectedAt;

  // ICE connection timeout
  Timer? _iceTimeoutTimer;
  static const _iceTimeoutDuration = Duration(seconds: 30);

  // Callbacks
  Function(MediaStream)? onLocalStream;
  Function(MediaStream)? onRemoteStream;
  Function(CallStatus)? onCallStatusChanged;

  // Stream getters & Status
  CallStatus _currentStatus = CallStatus.ringing;
  CallStatus get currentStatus => _currentStatus;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  // Free STUN + metered.ca free TURN servers for reliable NAT traversal
  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {
        'urls': 'turn:a.relay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:a.relay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:a.relay.metered.ca:443?transport=tcp',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  };

  /// Initiate a call (caller side)
  Future<CallModel> makeCall({
    required String callerId,
    required String callerName,
    required String callerPhoto,
    required String receiverId,
    required String receiverName,
    required String receiverPhoto,
    required CallType type,
  }) async {
    // Reset state for new call
    _isCleaningUp = false;
    _connectedAt = null;
    _currentStatus = CallStatus.ringing;

    final callId = _uuid.v4();

    final call = CallModel(
      id: callId,
      callerId: callerId,
      callerName: callerName,
      callerPhoto: callerPhoto,
      receiverId: receiverId,
      receiverName: receiverName,
      receiverPhoto: receiverPhoto,
      type: type,
      status: CallStatus.ringing,
    );

    await _firestore.collection('calls').doc(callId).set(call.toMap());

    // Notify receiver via push notification
    _sendCallNotification(
      receiverId: receiverId,
      callerName: callerName,
      callId: callId,
      isVideo: type == CallType.video,
    );

    // Initialize WebRTC FIRST, set up ICE collection BEFORE creating offer
    await _initializeWebRTC(type == CallType.video);

    // Collect ICE candidates and send to 'callerCandidates' subcollection
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate != null) {
        _firestore
            .collection('calls')
            .doc(callId)
            .collection('callerCandidates')
            .add(candidate.toMap());
      }
    };

    // Create and set offer
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    await _firestore.collection('calls').doc(callId).update({
      'offer': {'sdp': offer.sdp, 'type': offer.type},
    });

    // Listen for receiver's ICE candidates
    _listenForRemoteCandidates(callId, 'receiverCandidates');

    // Start ICE connection timeout
    _startIceTimeout(callId);

    // Listen for the answer from the receiver
    _callSubscription = _firestore
        .collection('calls')
        .doc(callId)
        .snapshots()
        .listen((snapshot) async {
      final data = snapshot.data();
      if (data == null) return;

      // Apply answer once it arrives
      if (data['answer'] != null &&
          _peerConnection?.signalingState ==
              RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        final answer = data['answer'];
        await _peerConnection?.setRemoteDescription(
          RTCSessionDescription(answer['sdp'], answer['type']),
        );
      }

      // Report status changes
      if (data['status'] != null) {
        final status = CallStatus.values.firstWhere(
          (e) => e.name == data['status'],
          orElse: () => CallStatus.ringing,
        );
        _updateStatus(status);
      }
    });

    return call;
  }

  void _updateStatus(CallStatus status) {
    if (_currentStatus == status) return;
    _currentStatus = status;

    if (status == CallStatus.connected) {
      _connectedAt = DateTime.now();
      _iceTimeoutTimer?.cancel();
    }

    onCallStatusChanged?.call(status);
  }

  /// Start a timer that marks the call as missed if no connection within timeout
  void _startIceTimeout(String callId) {
    _iceTimeoutTimer?.cancel();
    _iceTimeoutTimer = Timer(_iceTimeoutDuration, () {
      if (_currentStatus == CallStatus.ringing) {
        debugPrint('ICE timeout — marking call as missed');
        _firestore.collection('calls').doc(callId).update({
          'status': CallStatus.missed.name,
        });
        _cleanup();
      }
    });
  }

  /// Answer a call (receiver side)
  Future<void> answerCall(String callId, bool isVideo) async {
    _isCleaningUp = false;
    _connectedAt = null;
    _currentStatus = CallStatus.ringing;

    await _initializeWebRTC(isVideo);

    // Collect ICE candidates and send to 'receiverCandidates' subcollection
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate != null) {
        _firestore
            .collection('calls')
            .doc(callId)
            .collection('receiverCandidates')
            .add(candidate.toMap());
      }
    };

    // Get the offer from Firestore
    final callDoc =
        await _firestore.collection('calls').doc(callId).get();
    final data = callDoc.data();
    final offer = data?['offer'];

    if (offer != null) {
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );

      // Create and set answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      await _firestore.collection('calls').doc(callId).update({
        'answer': {'sdp': answer.sdp, 'type': answer.type},
        'status': CallStatus.connected.name,
      });
    }

    // Listen for caller's ICE candidates
    _listenForRemoteCandidates(callId, 'callerCandidates');

    // Listen for call status changes (e.g., caller ends the call)
    _callSubscription = _firestore
        .collection('calls')
        .doc(callId)
        .snapshots()
        .listen((snapshot) {
      final status = snapshot.data()?['status'];
      if (status != null) {
        final callStatus = CallStatus.values.firstWhere(
          (e) => e.name == status,
          orElse: () => CallStatus.connected,
        );
        _updateStatus(callStatus);
      }
    });
  }

  /// Listen for remote ICE candidates and add them to the peer connection
  void _listenForRemoteCandidates(String callId, String collection) {
    final sub = _firestore
        .collection('calls')
        .doc(callId)
        .collection(collection)
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data()!;
          _peerConnection?.addCandidate(
            RTCIceCandidate(
              data['candidate'],
              data['sdpMid'],
              data['sdpMLineIndex'],
            ),
          );
        }
      }
    });

    if (collection == 'callerCandidates') {
      _callerCandidatesSubscription = sub;
    } else {
      _receiverCandidatesSubscription = sub;
    }
  }

  /// Initialize the local WebRTC peer connection and media stream
  Future<void> _initializeWebRTC(bool enableVideo) async {
    _peerConnection = await createPeerConnection(_iceServers);

    final mediaConstraints = {
      'audio': true,
      'video': enableVideo
          ? {'facingMode': 'user', 'width': 640, 'height': 480}
          : false,
    };

    _localStream =
        await navigator.mediaDevices.getUserMedia(mediaConstraints);
    onLocalStream?.call(_localStream!);

    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    // Set max bitrate on video senders for equal quality on both sides
    if (enableVideo) {
      _setVideoBitrate();
    }

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        onRemoteStream?.call(_remoteStream!);
      }
    };

    _peerConnection!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _updateStatus(CallStatus.connected);
      } else if (state ==
              RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _updateStatus(CallStatus.ended);
      }
    };
  }

  /// Cap video bitrate so both sides get equal quality
  Future<void> _setVideoBitrate() async {
    try {
      final senders = await _peerConnection!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          final params = sender.parameters;
          if (params.encodings == null || params.encodings!.isEmpty) {
            params.encodings = [RTCRtpEncoding()];
          }
          for (final encoding in params.encodings!) {
            encoding.maxBitrate = 1500000; // 1.5 Mbps
            encoding.minBitrate = 500000;  // 500 kbps
          }
          await sender.setParameters(params);
        }
      }
    } catch (e) {
      debugPrint('Error setting video bitrate: $e');
    }
  }

  /// End the call — with duration tracking
  Future<void> endCall(String callId) async {
    if (_isCleaningUp) return;
    _isCleaningUp = true;

    // Calculate duration if the call was connected
    int? duration;
    if (_connectedAt != null) {
      duration = DateTime.now().difference(_connectedAt!).inSeconds;
    }

    try {
      final updateData = <String, dynamic>{
        'status': CallStatus.ended.name,
      };
      if (duration != null) {
        updateData['duration'] = duration;
      }
      await _firestore.collection('calls').doc(callId).update(updateData);
    } catch (e) {
      debugPrint('Error updating call status: $e');
    }

    await _cleanup();
  }

  /// Reject an incoming call
  Future<void> rejectCall(String callId) async {
    if (_isCleaningUp) return;
    _isCleaningUp = true;

    try {
      await _firestore.collection('calls').doc(callId).update({
        'status': CallStatus.rejected.name,
      });
    } catch (e) {
      debugPrint('Error rejecting call: $e');
    }

    await _cleanup();
  }

  /// Look up the receiver's FCM token and send a call notification
  Future<void> _sendCallNotification({
    required String receiverId,
    required String callerName,
    required String callId,
    required bool isVideo,
  }) async {
    try {
      final userDoc =
          await _firestore.collection('users').doc(receiverId).get();
      final fcmToken = userDoc.data()?['fcmToken'] as String?;
      if (fcmToken == null || fcmToken.isEmpty) return;

      NotificationService.sendPushNotification(
        recipientFcmToken: fcmToken,
        title: isVideo ? '📹 Incoming Video Call' : '📞 Incoming Voice Call',
        message: '$callerName is calling you',
        data: {
          'type': 'call',
          'id': callId,
          'callerName': callerName,
          'isVideo': isVideo.toString(),
        },
      );
    } catch (_) {
      // Notification failure should never crash the call
    }
  }

  void toggleMute(bool muted) {
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !muted;
    });
  }

  void toggleCamera(bool off) {
    _localStream?.getVideoTracks().forEach((track) {
      track.enabled = !off;
    });
  }

  void toggleSpeaker(bool speakerOn) {
    _localStream?.getAudioTracks().forEach((track) {
      track.enableSpeakerphone(speakerOn);
    });
  }

  Future<void> switchCamera() async {
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      Helper.switchCamera(videoTrack);
    }
  }

  /// Listen for incoming ringing calls for the given user
  Stream<CallModel?> listenForIncomingCalls(String userId) {
    return _firestore
        .collection('calls')
        .where('receiverId', isEqualTo: userId)
        .where('status', isEqualTo: CallStatus.ringing.name)
        .snapshots()
        .map((snapshot) {
      if (snapshot.docs.isNotEmpty) {
        return CallModel.fromMap(snapshot.docs.first.data());
      }
      return null;
    });
  }

  /// Get call history for a user
  Stream<List<CallModel>> getCallHistory(String userId) {
    return _firestore
        .collection('calls')
        .where(
          Filter.or(
            Filter('callerId', isEqualTo: userId),
            Filter('receiverId', isEqualTo: userId),
          ),
        )
        .snapshots()
        .map((snapshot) {
      final docs = snapshot.docs
          .map((doc) => CallModel.fromMap(doc.data()))
          .where((call) =>
              call.status == CallStatus.ended ||
              call.status == CallStatus.missed ||
              call.status == CallStatus.rejected)
          .toList();
      
      docs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return docs;
    });
  }

  Future<void> _cleanup() async {
    _iceTimeoutTimer?.cancel();
    _iceTimeoutTimer = null;
    _connectedAt = null;

    await _callSubscription?.cancel();
    await _callerCandidatesSubscription?.cancel();
    await _receiverCandidatesSubscription?.cancel();
    _callSubscription = null;
    _callerCandidatesSubscription = null;
    _receiverCandidatesSubscription = null;

    _localStream?.getTracks().forEach((track) => track.stop());
    await _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    await _peerConnection?.close();
    _peerConnection = null;

    // Reset callbacks
    onLocalStream = null;
    onRemoteStream = null;
    onCallStatusChanged = null;
  }

  /// Clean up per-call resources (NOT the singleton itself)
  Future<void> cleanupCall() async {
    if (_isCleaningUp) return;
    await _cleanup();
  }
}
