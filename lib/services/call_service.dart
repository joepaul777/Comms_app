import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../config.dart';
import '../models/call_model.dart';
import '../models/user_model.dart';
import '../platform/platform.dart';
import 'notification_service.dart';
import 'push_api.dart';
import 'rate_limiter.dart';
import 'user_service.dart';

enum CallPhase { idle, outgoing, incoming, connecting, connected, ended }

/// Runs one call at a time and keeps both phones in step through the call document.
///
/// Every way a call can finish is written to the document (status + endReason), so the
/// other phone always learns what happened: declined, cancelled, no answer, busy,
/// hung up or connection lost.
class CallService extends ChangeNotifier {
  CallService._() {
    addListener(_syncLockScreen);
  }

  static const _lockScreen = MethodChannel('comms/lock_screen');
  bool _overLockScreen = false;

  /// Only a ringing or live call may show over the lock screen.
  void _syncLockScreen() {
    final inCall = phase != CallPhase.idle && phase != CallPhase.ended;
    if (inCall == _overLockScreen) return;
    _overLockScreen = inCall;
    _lockScreen.invokeMethod('setInCall', inCall).catchError((_) {});
  }
  static final CallService instance = CallService._();
  factory CallService() => instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final SendGate _gate = SendGate(
    minGap: AppConfig.minCallGap,
    maxPerWindow: AppConfig.callsPerFiveMinutes,
    window: const Duration(minutes: 5),
    noun: 'calls',
  );

  CallPhase phase = CallPhase.idle;
  CallModel? call;
  String myUid = '';
  bool get isCaller => call?.callerId == myUid;
  bool get isActive => phase != CallPhase.idle;

  /// Shown on the call screen once it is over: "Declined", "No answer" and so on.
  String endMessage = '';

  MediaStream? localStream;
  MediaStream? remoteStream;
  bool muted = false;
  bool speakerOn = false;
  bool cameraOff = false;
  DateTime? connectedAt;

  /// Shown on the call screen when this device's microphone or camera couldn't be used.
  String? mediaNote;

  RTCPeerConnection? _pc;
  StreamSubscription? _callSub;
  StreamSubscription? _candidateSub;
  Timer? _ringTimer;
  Timer? _busyTimer;
  Timer? _dropTimer;
  Timer? _closeTimer;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _finishing = false;
  bool _ringing = false;

  /// Goes up with every call, so work started for an old call can tell it is too late.
  int _session = 0;

  // ---------------------------------------------------------------------------
  // Placing a call
  // ---------------------------------------------------------------------------

  /// Starts a call. Returns a message to show if it could not start.
  Future<String?> startCall({required UserModel me, required UserModel other, required CallType type}) async {
    if (isActive) return 'You are already on a call';
    try {
      _gate.check();
    } on RateLimitException catch (e) {
      return e.message;
    }
    if (!await _permissions(type == CallType.video)) {
      return type == CallType.video ? 'Comms needs the camera and microphone for video calls' : 'Comms needs the microphone for calls';
    }

    myUid = me.uid;
    _resetState();
    final fresh = await UserService.instance.getUser(other.uid, fresh: true).catchError((_) => null) ?? other;
    final callId = const Uuid().v4();
    var model = CallModel(
      id: callId,
      callerId: me.uid,
      callerName: me.name,
      callerPhoto: _shareablePhoto(me.photoUrl),
      receiverId: other.uid,
      receiverName: other.name,
      receiverPhoto: _shareablePhoto(other.photoUrl),
      type: type,
    );

    // The other person is already ringing or talking to someone.
    if (fresh.isBusy) {
      model = CallModel.fromMap({...model.toMap(), 'status': CallStatus.missed.name, 'endReason': EndReason.busy});
      call = model;
      phase = CallPhase.ended;
      endMessage = '${other.firstName} is on another call';
      notifyListeners();
      _gate.record();
      try {
        await _createCallDoc(me, model);
      } catch (_) {}
      _scheduleClose();
      return null;
    }

    call = model;
    phase = CallPhase.outgoing;
    notifyListeners();
    _gate.record();

    try {
      await _createCallDoc(me, model);
    } on RateLimitException catch (e) {
      _finishLocally('Not sent');
      return e.message;
    } catch (e) {
      debugPrint('call create failed: $e');
      _finishLocally('Could not start the call');
      return 'Could not start the call. Check your connection.';
    }

    _startBusyHeartbeat();
    unawaited(PushApi.call(callId));
    _ringTimer = Timer(AppConfig.ringTimeout, () {
      if (phase == CallPhase.outgoing) _finish(status: CallStatus.missed, reason: EndReason.noAnswer, message: 'No answer');
    });

    try {
      await _openConnection(type == CallType.video);
      _pc!.onIceCandidate = (c) => _sendCandidate(callId, 'callerCandidates', c);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      if (phase != CallPhase.outgoing) return null; // hung up while setting up
      await _db.collection('calls').doc(callId).update({'offer': {'sdp': offer.sdp, 'type': offer.type}});
      _listenCandidates(callId, 'receiverCandidates');
      _watchCall(callId);
    } catch (e) {
      debugPrint('call setup failed: $e');
      await _finish(status: CallStatus.missed, reason: EndReason.failed, message: 'Could not start the call');
    }
    return null;
  }

  /// Writes the call document together with the caller's rate fields, as the database requires.
  Future<void> _createCallDoc(UserModel me, CallModel model) async {
    final newWindow = SendGate.startsNewWindow(me.callWindowStart, const Duration(minutes: 5), DateTime.now());
    Future<void> commit(bool startWindow) {
      final batch = _db.batch();
      batch.set(_db.collection('calls').doc(model.id), model.toMap());
      batch.update(
        _db.collection('users').doc(me.uid),
        SendGate.fields(lastField: 'lastCallAt', startField: 'callWindowStart', countField: 'callWindowCount', newWindow: startWindow),
      );
      return batch.commit();
    }

    try {
      await commit(newWindow);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      try {
        await commit(!newWindow);
      } on FirebaseException catch (e2) {
        if (e2.code == 'permission-denied') throw RateLimitException(const Duration(seconds: 10), 'Too many calls. Wait a moment');
        rethrow;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Receiving a call
  // ---------------------------------------------------------------------------

  /// Called when a ringing call for this person shows up. Returns true if it will be shown.
  Future<bool> handleIncoming(CallModel incoming, String uid) async {
    if (incoming.status != CallStatus.ringing) return false;
    if (call?.id == incoming.id) return phase == CallPhase.incoming;
    // A call that has been ringing for too long is stale.
    if (DateTime.now().difference(incoming.timestamp) > AppConfig.ringTimeout + const Duration(seconds: 5)) {
      await _markMissed(incoming.id, EndReason.noAnswer);
      return false;
    }
    if (isActive) {
      // Only one call at a time: the newcomer hears that this person is busy.
      await _markMissed(incoming.id, EndReason.busy);
      return false;
    }
    myUid = uid;
    _resetState();
    call = incoming;
    phase = CallPhase.incoming;
    notifyListeners();
    _startRinging();
    unawaited(NotificationService.instance.showRinging(incoming));
    _startBusyHeartbeat();
    _watchCall(incoming.id);
    _ringTimer = Timer(AppConfig.ringTimeout + const Duration(seconds: 3), () {
      if (phase == CallPhase.incoming) _finish(status: CallStatus.missed, reason: EndReason.noAnswer, message: 'Missed call');
    });
    return true;
  }

  Future<void> _markMissed(String callId, String reason) async {
    try {
      final ref = _db.collection('calls').doc(callId);
      final changed = await _db.runTransaction<bool>((tx) async {
        final snap = await tx.get(ref);
        if (snap.data()?['status'] != CallStatus.ringing.name) return false;
        tx.update(ref, {'status': CallStatus.missed.name, 'endReason': reason, 'endedBy': myUid.isEmpty ? null : myUid});
        return true;
      });
      if (changed) unawaited(PushApi.callUpdate(callId));
    } catch (e) {
      debugPrint('mark missed failed: $e');
    }
  }

  Future<void> accept() async {
    final current = call;
    if (current == null || phase != CallPhase.incoming) return;
    _stopRinging();
    _ringTimer?.cancel();
    unawaited(NotificationService.instance.cancelCall(current.id));
    if (!await _permissions(current.isVideo)) {
      await _finish(status: CallStatus.rejected, reason: EndReason.declined, message: 'Microphone permission needed');
      return;
    }
    phase = CallPhase.connecting;
    notifyListeners();
    try {
      await _openConnection(current.isVideo);
      _pc!.onIceCandidate = (c) => _sendCandidate(current.id, 'receiverCandidates', c);

      // The offer can arrive a moment after the call starts ringing.
      Map<String, dynamic>? offer = current.offer;
      if (offer == null) {
        final snap = await _db
            .collection('calls')
            .doc(current.id)
            .snapshots()
            .firstWhere((s) => s.data()?['offer'] != null || s.data()?['status'] != CallStatus.ringing.name)
            .timeout(const Duration(seconds: 15));
        offer = snap.data()?['offer'] == null ? null : Map<String, dynamic>.from(snap.data()!['offer']);
      }
      if (offer == null || phase != CallPhase.connecting) return;

      await _pc!.setRemoteDescription(RTCSessionDescription(offer['sdp'], offer['type']));
      await _flushCandidates();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _db.collection('calls').doc(current.id).update({
        'answer': {'sdp': answer.sdp, 'type': answer.type},
        'status': CallStatus.connected.name,
      });
      _listenCandidates(current.id, 'callerCandidates');
    } catch (e) {
      debugPrint('accept failed: $e');
      if (phase == CallPhase.connecting) {
        await _finish(status: CallStatus.ended, reason: EndReason.failed, message: 'Could not connect');
      }
    }
  }

  Future<void> decline() async {
    if (phase != CallPhase.incoming) return;
    await _finish(status: CallStatus.rejected, reason: EndReason.declined, message: 'Declined');
  }

  /// Red button: cancels a call that is still ringing, or ends one in progress.
  Future<void> hangUp() async {
    switch (phase) {
      case CallPhase.outgoing:
        await _finish(status: CallStatus.missed, reason: EndReason.cancelled, message: 'Cancelled');
        break;
      case CallPhase.incoming:
        await decline();
        break;
      case CallPhase.connecting:
      case CallPhase.connected:
        await _finish(status: CallStatus.ended, reason: EndReason.hungUp, message: 'Call ended');
        break;
      case CallPhase.ended:
        _closeNow();
        break;
      case CallPhase.idle:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Following the other phone
  // ---------------------------------------------------------------------------

  void _watchCall(String callId) {
    _callSub?.cancel();
    _callSub = _db.collection('calls').doc(callId).snapshots().listen((snap) async {
      final data = snap.data();
      if (data == null || _finishing) return;
      final latest = CallModel.fromMap(data);
      call = latest;

      if (isCaller && latest.answer != null && !_remoteDescriptionSet && _pc != null) {
        _remoteDescriptionSet = true;
        try {
          await _pc!.setRemoteDescription(RTCSessionDescription(latest.answer!['sdp'], latest.answer!['type']));
          await _flushCandidates();
          if (phase == CallPhase.outgoing) {
            _ringTimer?.cancel();
            phase = CallPhase.connecting;
            notifyListeners();
          }
        } catch (e) {
          debugPrint('apply answer failed: $e');
        }
      }

      // The same account can be signed in on a phone and in a browser, and both ring.
      // Once one of them answers or declines, the other one stops.
      if (phase == CallPhase.incoming && !isCaller && (latest.status == CallStatus.connected || latest.answer != null)) {
        _endLocally('Answered on another device', elsewhere: true);
        return;
      }

      if (latest.isOver && phase != CallPhase.ended) {
        if (latest.endedBy != myUid) {
          _onRemoteEnded(latest);
        } else {
          // Ended by this person on their other device.
          _endLocally(latest.status == CallStatus.rejected ? 'Declined' : 'Call ended', elsewhere: true);
        }
      }
    });
  }

  void _onRemoteEnded(CallModel ended) {
    String message;
    switch (ended.endReason) {
      case EndReason.declined:
        message = 'Declined';
        break;
      case EndReason.cancelled:
        message = 'Missed call';
        break;
      case EndReason.noAnswer:
        message = isCaller ? 'No answer' : 'Missed call';
        break;
      case EndReason.busy:
        message = isCaller ? '${ended.receiverName.split(' ').first} is on another call' : 'Missed call';
        break;
      case EndReason.failed:
        message = 'Connection lost';
        break;
      default:
        message = ended.status == CallStatus.rejected ? 'Declined' : 'Call ended';
    }
    if (!isCaller && ended.status == CallStatus.missed) {
      unawaited(NotificationService.instance.showMissedCall(ended));
    }
    _endLocally(message);
  }

  // ---------------------------------------------------------------------------
  // Media and connection
  // ---------------------------------------------------------------------------

  Future<bool> _permissions(bool video) async {
    // The browser asks for the microphone and camera itself when the call starts.
    if (kIsWeb) return true;
    final statuses = await [Permission.microphone, if (video) Permission.camera].request();
    // Lets the call use Bluetooth headphones (Android 12+). Optional: without it the
    // call just can't switch to them.
    try {
      await Permission.bluetoothConnect.request();
    } catch (_) {}
    return statuses.values.every((s) => s.isGranted);
  }

  /// The microphone and camera, settling for less when something is missing: a
  /// computer without a webcam still joins a video call with its voice, and one whose
  /// microphone is blocked still hears the other person.
  Future<MediaStream?> _getMedia(bool video) async {
    const audio = {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true};
    final attempts = <Map<String, dynamic>>[
      {'audio': audio, 'video': video ? {'facingMode': 'user', 'width': 1280, 'height': 720, 'frameRate': 30} : false},
      if (video) {'audio': audio, 'video': true},
      if (video) {'audio': audio, 'video': false},
      {'audio': true, 'video': false},
      if (video) {'audio': false, 'video': true},
    ];
    Object? problem;
    for (final constraints in attempts) {
      try {
        return await navigator.mediaDevices.getUserMedia(constraints);
      } catch (e) {
        problem = e;
      }
    }
    debugPrint('no microphone or camera: $problem');
    return null;
  }

  Future<void> _openConnection(bool video) async {
    final session = _session;
    final servers = await PushApi.iceServers();
    final pc = await createPeerConnection({'iceServers': servers, 'sdpSemantics': 'unified-plan'});
    final stream = await _getMedia(video);
    // The call was declined or cancelled while the camera was starting: let go of it
    // straight away, or it stays on and the next call can't use it.
    if (session != _session || phase == CallPhase.ended || phase == CallPhase.idle) {
      for (final t in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await stream?.dispose();
      await pc.close();
      throw StateError('call ended while starting');
    }
    _pc = pc;
    localStream = stream;
    final tracks = localStream?.getTracks() ?? const <MediaStreamTrack>[];
    for (final track in tracks) {
      await _pc!.addTrack(track, localStream!);
    }
    final hasAudio = tracks.any((t) => t.kind == 'audio');
    final hasVideo = tracks.any((t) => t.kind == 'video');
    mediaNote = !hasAudio
        ? (kIsWeb ? 'Your microphone is off or blocked in this browser' : 'Your microphone is not available')
        : video && !hasVideo
            ? 'No camera found, so only your voice is sent'
            : null;
    // Whoever starts the call still asks to receive what they can't send, so the other
    // person's voice and video come through.
    if (isCaller) {
      if (!hasAudio) {
        await _pc!.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeAudio, init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
      }
      if (video && !hasVideo) {
        await _pc!.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeVideo, init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
      }
    }
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteStream = event.streams.first;
        notifyListeners();
      }
    };
    _pc!.onIceConnectionState = _onIceState;
    await _setUpAudio(video);
    await WakelockPlus.enable().catchError((_) {});
    notifyListeners();
  }

  void _onIceState(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _dropTimer?.cancel();
        if (phase == CallPhase.connecting || phase == CallPhase.outgoing) {
          _ringTimer?.cancel();
          phase = CallPhase.connected;
          connectedAt ??= DateTime.now();
          notifyListeners();
        }
        break;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        // Networks hiccup; give it a few seconds to recover.
        _dropTimer?.cancel();
        _dropTimer = Timer(const Duration(seconds: 10), () {
          if (phase == CallPhase.connected) _finish(status: CallStatus.ended, reason: EndReason.failed, message: 'Connection lost');
        });
        break;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        if (phase == CallPhase.connected || phase == CallPhase.connecting) {
          _finish(status: CallStatus.ended, reason: EndReason.failed, message: 'Connection lost');
        }
        break;
      default:
        break;
    }
  }

  void _sendCandidate(String callId, String side, RTCIceCandidate candidate) {
    // Browsers end the list with an empty candidate; there is nothing to send.
    if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
    _db.collection('calls').doc(callId).collection(side).add(candidate.toMap()).catchError((e) {
      debugPrint('candidate send failed: $e');
      return _db.collection('calls').doc(callId);
    });
  }

  void _listenCandidates(String callId, String side) {
    _candidateSub?.cancel();
    _candidateSub = _db.collection('calls').doc(callId).collection(side).snapshots().listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        final d = change.doc.data()!;
        final candidate = RTCIceCandidate(d['candidate'], d['sdpMid'], d['sdpMLineIndex']);
        if (_remoteDescriptionSet || !isCaller) {
          _pc?.addCandidate(candidate).catchError((e) => debugPrint('candidate add failed: $e'));
        } else {
          _pendingCandidates.add(candidate);
        }
      }
    });
  }

  Future<void> _flushCandidates() async {
    _remoteDescriptionSet = true;
    for (final c in _pendingCandidates) {
      await _pc?.addCandidate(c).catchError((e) => debugPrint('candidate add failed: $e'));
    }
    _pendingCandidates.clear();
  }

  // ---------------------------------------------------------------------------
  // Controls
  // ---------------------------------------------------------------------------

  void toggleMute() {
    muted = !muted;
    for (final t in localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() => selectAudioOutput(audioOutput == 'speaker' ? _phoneOutput() : 'speaker');

  // ---------------------------------------------------------------------------
  // Where the sound goes (phones)
  // ---------------------------------------------------------------------------

  /// The ways sound can come out, in the order shown: 'earpiece', 'speaker',
  /// 'wired-headset', 'bluetooth'. Only those this phone has right now.
  List<String> audioOutputs = const [];

  /// The one in use.
  String audioOutput = 'earpiece';

  static const _outputOrder = ['earpiece', 'speaker', 'wired-headset', 'bluetooth'];

  /// What to use when nothing else is chosen: a headset if one is connected,
  /// otherwise the earpiece (or the speaker when there is none).
  String _phoneOutput() {
    if (audioOutputs.contains('bluetooth')) return 'bluetooth';
    if (audioOutputs.contains('wired-headset')) return 'wired-headset';
    return audioOutputs.contains('earpiece') ? 'earpiece' : 'speaker';
  }

  Future<void> _refreshOutputs() async {
    try {
      final ids = (await Helper.audiooutputs).map((d) => d.deviceId).toSet();
      audioOutputs = _outputOrder.where(ids.contains).toList();
    } catch (e) {
      debugPrint('audio outputs failed: $e');
    }
    if (audioOutputs.isEmpty) audioOutputs = const ['earpiece', 'speaker'];
  }

  /// Like a phone call: a headset if one is connected, otherwise the speaker for
  /// video calls and the earpiece for voice calls.
  Future<void> _setUpAudio(bool video) async {
    if (kIsWeb) return;
    await _refreshOutputs();
    final headset = _phoneOutput();
    await selectAudioOutput(headset == 'bluetooth' || headset == 'wired-headset' ? headset : (video ? 'speaker' : headset));
    navigator.mediaDevices.ondevicechange = (_) => _onDevicesChanged();
  }

  /// A headset was connected or disconnected during the call.
  Future<void> _onDevicesChanged() async {
    if (!isActive || phase == CallPhase.ended || kIsWeb) return;
    final before = audioOutputs.toSet();
    await _refreshOutputs();
    final added = audioOutputs.where((d) => !before.contains(d) && (d == 'bluetooth' || d == 'wired-headset')).toList();
    if (added.isNotEmpty) {
      await selectAudioOutput(added.last);
    } else if (!audioOutputs.contains(audioOutput)) {
      await selectAudioOutput(call?.isVideo == true ? 'speaker' : _phoneOutput());
    } else {
      notifyListeners();
    }
  }

  /// Sends the call's sound to [output] (one of [audioOutputs]).
  Future<void> selectAudioOutput(String output) async {
    if (kIsWeb) return;
    try {
      await Helper.selectAudioOutput(output);
    } catch (e) {
      debugPrint('select audio output failed: $e');
      if (output == 'speaker' || output == 'earpiece') await _setSpeaker(output == 'speaker');
    }
    audioOutput = output;
    speakerOn = output == 'speaker';
    notifyListeners();
  }

  void toggleCamera() {
    cameraOff = !cameraOff;
    for (final t in localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !cameraOff;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    try {
      await Helper.switchCamera(track);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Finishing
  // ---------------------------------------------------------------------------

  /// Ends the call from this phone and tells the other one why.
  Future<void> _finish({required CallStatus status, required String reason, required String message}) async {
    final current = call;
    if (current == null || _finishing || phase == CallPhase.ended) return;
    _finishing = true;
    final seconds = connectedAt == null ? null : DateTime.now().difference(connectedAt!).inSeconds;
    _endLocally(message);
    try {
      await _db.collection('calls').doc(current.id).update({
        'status': status.name,
        'endReason': reason,
        'endedBy': myUid,
        'endedAt': DateTime.now().millisecondsSinceEpoch,
        if (seconds != null) 'duration': seconds,
      });
      unawaited(PushApi.callUpdate(current.id));
    } catch (e) {
      debugPrint('call end write failed: $e');
    }
  }

  void _finishLocally(String message) {
    _endLocally(message);
  }

  /// [elsewhere]: the call carries on (or ended) on this person's other device, so
  /// this one must not mark them as free.
  void _endLocally(String message, {bool elsewhere = false}) {
    endMessage = message;
    phase = CallPhase.ended;
    _stopRinging();
    unawaited(_releaseMedia(keepBusy: elsewhere));
    if (call != null) unawaited(NotificationService.instance.cancelCall(call!.id));
    notifyListeners();
    _scheduleClose();
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 2200), _closeNow);
  }

  void _closeNow() {
    _closeTimer?.cancel();
    phase = CallPhase.idle;
    call = null;
    _finishing = false;
    notifyListeners();
  }

  Future<void> _releaseMedia({bool keepBusy = false}) async {
    _ringTimer?.cancel();
    _dropTimer?.cancel();
    _busyTimer?.cancel();
    await _callSub?.cancel();
    await _candidateSub?.cancel();
    _callSub = null;
    _candidateSub = null;
    for (final t in localStream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await localStream?.dispose();
    localStream = null;
    remoteStream = null;
    await _pc?.close();
    _pc = null;
    if (myUid.isNotEmpty && !keepBusy) unawaited(UserService.instance.setBusy(myUid, false));
    if (!kIsWeb) navigator.mediaDevices.ondevicechange = null;
    await _setSpeaker(false);
    await WakelockPlus.disable().catchError((_) {});
  }

  void _resetState() {
    _session++;
    _closeTimer?.cancel();
    endMessage = '';
    muted = false;
    speakerOn = false;
    cameraOff = false;
    connectedAt = null;
    mediaNote = null;
    audioOutput = 'earpiece';
    audioOutputs = const [];
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _finishing = false;
  }

  void _startBusyHeartbeat() {
    UserService.instance.setBusy(myUid, true);
    _busyTimer?.cancel();
    _busyTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (isActive && phase != CallPhase.ended) UserService.instance.setBusy(myUid, true);
    });
  }

  /// Phones switch between earpiece and loudspeaker; a computer just has its speakers.
  Future<void> _setSpeaker(bool on) async {
    if (kIsWeb) return;
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }

  void _startRinging() {
    _ringing = true;
    startRingtone();
  }

  void _stopRinging() {
    if (!_ringing) return;
    _ringing = false;
    stopRingtone();
  }

  /// Data URLs are too large to copy into every call record.
  String _shareablePhoto(String url) => url.startsWith('data:') ? '' : url;

  // ---------------------------------------------------------------------------
  // Listening and history
  // ---------------------------------------------------------------------------

  /// Ringing calls addressed to this person.
  Stream<List<CallModel>> incomingCalls(String uid) {
    return _db
        .collection('calls')
        .where('receiverId', isEqualTo: uid)
        .where('status', isEqualTo: CallStatus.ringing.name)
        .snapshots()
        .map((s) => s.docs.map((d) => CallModel.fromMap(d.data())).toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp)));
  }

  Future<CallModel?> getCall(String id) async {
    final snap = await _db.collection('calls').doc(id).get();
    return snap.exists ? CallModel.fromMap(snap.data()!) : null;
  }

  /// Finished calls, newest first.
  Stream<List<CallModel>> history(String uid) {
    final made = _db.collection('calls').where('callerId', isEqualTo: uid).orderBy('timestamp', descending: true).limit(60).snapshots();
    final received = _db.collection('calls').where('receiverId', isEqualTo: uid).orderBy('timestamp', descending: true).limit(60).snapshots();
    final controller = StreamController<List<CallModel>>();
    var a = <CallModel>[];
    var b = <CallModel>[];
    void emit() {
      final all = [...a, ...b].where((c) => c.isOver).toList()..sort((x, y) => y.timestamp.compareTo(x.timestamp));
      controller.add(all);
    }

    late final StreamSubscription s1;
    late final StreamSubscription s2;
    controller.onListen = () {
      s1 = made.listen((s) {
        a = s.docs.map((d) => CallModel.fromMap(d.data())).toList();
        emit();
      }, onError: controller.addError);
      s2 = received.listen((s) {
        b = s.docs.map((d) => CallModel.fromMap(d.data())).toList();
        emit();
      }, onError: controller.addError);
    };
    controller.onCancel = () async {
      await s1.cancel();
      await s2.cancel();
    };
    return controller.stream;
  }

  /// Marks calls that were left ringing (for example after a crash) as missed.
  Future<void> cleanupStale(String uid) async {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch;
    for (final field in ['callerId', 'receiverId']) {
      try {
        final snap = await _db.collection('calls').where(field, isEqualTo: uid).where('status', whereIn: ['ringing', 'connected']).get();
        for (final doc in snap.docs) {
          final ts = doc.data()['timestamp'];
          if (ts is int && ts < cutoff && doc.id != call?.id) {
            await doc.reference.update({
              'status': doc.data()['status'] == 'ringing' ? CallStatus.missed.name : CallStatus.ended.name,
              'endReason': doc.data()['status'] == 'ringing' ? EndReason.noAnswer : EndReason.failed,
            });
          }
        }
      } catch (e) {
        debugPrint('stale cleanup failed: $e');
      }
    }
  }
}
