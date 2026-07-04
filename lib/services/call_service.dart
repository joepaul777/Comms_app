import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../models/call_model.dart';

class CallService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Uuid _uuid = const Uuid();

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // Callbacks
  Function(MediaStream)? onLocalStream;
  Function(MediaStream)? onRemoteStream;
  Function(CallStatus)? onCallStatusChanged;

  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ],
  };

  // Initiate a call
  Future<CallModel> makeCall({
    required String callerId,
    required String callerName,
    required String callerPhoto,
    required String receiverId,
    required String receiverName,
    required String receiverPhoto,
    required CallType type,
  }) async {
    final callId = _uuid.v4();

    // Create call document
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

    // Set up WebRTC
    await _initializeWebRTC(type == CallType.video);
    await _createOffer(callId);

    return call;
  }

  // Answer a call
  Future<void> answerCall(String callId, bool isVideo) async {

    await _initializeWebRTC(isVideo);

    // Get the offer
    final callDoc = await _firestore.collection('calls').doc(callId).get();
    final offer = callDoc.data()?['offer'];

    if (offer != null) {
      await _peerConnection?.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );

      // Create answer
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);

      await _firestore.collection('calls').doc(callId).update({
        'answer': {'sdp': answer.sdp, 'type': answer.type},
        'status': CallStatus.connected.name,
      });
    }

    // Listen for remote ICE candidates
    _listenForIceCandidates(callId, 'callerCandidates');
  }

  // Initialize WebRTC
  Future<void> _initializeWebRTC(bool enableVideo) async {
    _peerConnection = await createPeerConnection(_iceServers);

    // Get local media stream
    final mediaConstraints = {
      'audio': true,
      'video': enableVideo
          ? {'facingMode': 'user', 'width': 640, 'height': 480}
          : false,
    };

    _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    onLocalStream?.call(_localStream!);

    // Add tracks to peer connection
    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    // Listen for remote streams
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        onRemoteStream?.call(_remoteStream!);
      }
    };

    // Handle ICE connection state changes
    _peerConnection!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        onCallStatusChanged?.call(CallStatus.ended);
      }
    };
  }

  // Create offer (caller side)
  Future<void> _createOffer(String callId) async {
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    await _firestore.collection('calls').doc(callId).update({
      'offer': {'sdp': offer.sdp, 'type': offer.type},
    });

    // Listen for ICE candidates
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      _firestore
          .collection('calls')
          .doc(callId)
          .collection('callerCandidates')
          .add(candidate.toMap());
    };

    // Listen for answer
    _firestore
        .collection('calls')
        .doc(callId)
        .snapshots()
        .listen((snapshot) async {
      final data = snapshot.data();
      if (data != null && data['answer'] != null) {
        final answer = data['answer'];
        if (_peerConnection?.signalingState ==
            RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          await _peerConnection?.setRemoteDescription(
            RTCSessionDescription(answer['sdp'], answer['type']),
          );
        }
      }
      if (data != null) {
        final status = CallStatus.values.firstWhere(
          (e) => e.name == data['status'],
          orElse: () => CallStatus.ringing,
        );
        onCallStatusChanged?.call(status);
      }
    });

    // Listen for remote ICE candidates
    _listenForIceCandidates(callId, 'receiverCandidates');
  }

  void _listenForIceCandidates(String callId, String collection) {
    _firestore
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

    // Also send our ICE candidates
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      final targetCollection =
          collection == 'callerCandidates' ? 'receiverCandidates' : 'callerCandidates';
      _firestore
          .collection('calls')
          .doc(callId)
          .collection(targetCollection)
          .add(candidate.toMap());
    };
  }

  // End call
  Future<void> endCall(String callId) async {
    await _firestore.collection('calls').doc(callId).update({
      'status': CallStatus.ended.name,
    });
    await _cleanup();
  }

  // Reject call
  Future<void> rejectCall(String callId) async {
    await _firestore.collection('calls').doc(callId).update({
      'status': CallStatus.rejected.name,
    });
    await _cleanup();
  }

  // Toggle mute
  void toggleMute(bool muted) {
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !muted;
    });
  }

  // Toggle camera
  void toggleCamera(bool off) {
    _localStream?.getVideoTracks().forEach((track) {
      track.enabled = !off;
    });
  }

  // Toggle speaker
  void toggleSpeaker(bool speakerOn) {
    _localStream?.getAudioTracks().forEach((track) {
      track.enableSpeakerphone(speakerOn);
    });
  }

  // Switch camera
  Future<void> switchCamera() async {
    final videoTrack = _localStream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      Helper.switchCamera(videoTrack);
    }
  }

  // Listen for incoming calls
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

  // Get call history
  Stream<List<CallModel>> getCallHistory(String userId) {
    return _firestore
        .collection('calls')
        .where('status', whereIn: [
          CallStatus.ended.name,
          CallStatus.missed.name,
          CallStatus.rejected.name,
        ])
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => CallModel.fromMap(doc.data()))
            .where((call) =>
                call.callerId == userId || call.receiverId == userId)
            .toList());
  }

  // Cleanup
  Future<void> _cleanup() async {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream = null;
    await _peerConnection?.close();
    _peerConnection = null;
  }

  Future<void> dispose() async {
    await _cleanup();
  }
}
