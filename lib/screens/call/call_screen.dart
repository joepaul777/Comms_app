import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../platform/platform.dart';
import '../../services/call_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import '../../services/local_prefs.dart';

/// The one screen for every stage of a call. It closes itself when the call is over.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with TickerProviderStateMixin {
  final CallService _calls = CallService.instance;
  final RTCVideoRenderer _local = RTCVideoRenderer();
  final RTCVideoRenderer _remote = RTCVideoRenderer();
  late final AnimationController _rings = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  Timer? _clock;
  bool _renderersReady = false;
  bool _controlsVisible = true;
  /// Which corner your own picture sits in (it snaps there after being dragged),
  /// and where it is while a finger is moving it.
  Alignment _pipCorner = Alignment.topRight;
  Offset? _pipDrag;
  bool _popped = false;
  int _localVersion = 0;
  String? _appliedSpeaker;

  /// What was last told to the platform about the small floating window.
  String _pipState = '';

  @override
  void initState() {
    super.initState();
    _calls.addListener(_onChange);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_calls.phase == CallPhase.connected && mounted) setState(() {});
    });
    Future.wait([_local.initialize(), _remote.initialize()]).then((_) {
      if (!mounted) return;
      _renderersReady = true;
      // Redraw when a picture's size or turn changes, so it is fitted the right way.
      _local.addListener(_redraw);
      _remote.addListener(_redraw);
      inPictureInPicture.addListener(_redraw);
      _onChange();
    });
  }

  void _onChange() {
    if (!mounted) return;
    if (_calls.phase == CallPhase.ended || _calls.phase == CallPhase.idle) {
      if (_pipState != 'off') {
        _pipState = 'off';
        setPictureInPictureReady(false);
      }
      if (inPictureInPicture.value) closePictureInPicture();
    } else {
      _syncPictureInPicture();
    }
    if (_calls.phase == CallPhase.idle) {
      if (!_popped) {
        _popped = true;
        Navigator.of(context).maybePop();
      }
      return;
    }
    if (_renderersReady) {
      // A swapped camera or microphone keeps the same stream, so it is attached again.
      if (_local.srcObject != _calls.localStream || _localVersion != _calls.localTracksVersion) {
        _localVersion = _calls.localTracksVersion;
        _local.srcObject = null;
        _local.srcObject = _calls.localStream;
      }
      if (_remote.srcObject != _calls.remoteStream) {
        _remote.srcObject = _calls.remoteStream;
        _appliedSpeaker = null;
      }
      // In a browser, play their voice through the chosen speaker.
      final speaker = _calls.speakerId;
      if (kIsWeb && speaker != null && _calls.remoteStream != null && speaker != _appliedSpeaker) {
        _appliedSpeaker = speaker;
        _remote.audioOutput(speaker);
      }
    }
    if (_calls.phase == CallPhase.ended) HapticFeedback.mediumImpact();
    setState(() {});
  }

  void _redraw() {
    if (!mounted) return;
    _syncPictureInPicture();
    setState(() {});
  }

  /// A live video call can go into a small floating window when the person goes home
  /// (phone) or switches tab (browser), shaped like the other person's picture: wide
  /// from a laptop, tall from a phone.
  bool get _canPopOut {
    final call = _calls.call;
    return call != null && call.isVideo && _calls.phase == CallPhase.connected && _calls.remoteStream != null;
  }

  (int, int) get _theirShape {
    final v = _remote.value;
    if (v.width == 0 || v.height == 0) return (9, 16);
    final ratio = v.aspectRatio;
    return ratio >= 1 ? ((ratio * 1000).round(), 1000) : (1000, (1000 / ratio).round());
  }

  void _syncPictureInPicture() {
    final ready = _canPopOut;
    final (w, h) = _theirShape;
    final state = ready ? '$w:$h' : 'off';
    if (state == _pipState) return;
    _pipState = state;
    setPictureInPictureReady(ready, width: w, height: h, streamId: _calls.remoteStream?.id);
  }

  Future<void> _popOut() async {
    if (!_canPopOut) return;
    final ok = await enterPictureInPicture(streamId: _calls.remoteStream?.id);
    if (!ok && mounted) showSnack(context, 'Your device can\'t show the call in a small window', error: true);
  }

  @override
  void dispose() {
    inPictureInPicture.removeListener(_redraw);
    setPictureInPictureReady(false);
    _local.removeListener(_redraw);
    _remote.removeListener(_redraw);
    _calls.removeListener(_onChange);
    _clock?.cancel();
    _rings.dispose();
    _local.srcObject = null;
    _remote.srcObject = null;
    _local.dispose();
    _remote.dispose();
    super.dispose();
  }

  String _status() {
    switch (_calls.phase) {
      case CallPhase.outgoing:
        return 'Calling…';
      case CallPhase.incoming:
        return _calls.call?.isVideo == true ? 'Incoming video call' : 'Incoming voice call';
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.connected:
        final since = _calls.connectedAt;
        return since == null ? 'Connected' : formatDuration(DateTime.now().difference(since));
      case CallPhase.ended:
        return _calls.endMessage;
      case CallPhase.idle:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = _calls.call;
    if (call == null) return const Scaffold(backgroundColor: AppColors.bg);
    final name = Nicknames.instance.name(call.otherId(_calls.myUid), call.otherName(_calls.myUid));
    final photo = call.otherPhoto(_calls.myUid);
    final connectedVideo = call.isVideo && _calls.remoteStream != null && _calls.phase == CallPhase.connected;
    // No picture from them (camera off, or no camera at all): show their photo, not black.
    final theirCameraOff = connectedVideo && (_calls.remoteCameraOff || (_calls.remoteStream?.getVideoTracks().isEmpty ?? true));
    final videoLive = connectedVideo && !theirCameraOff;
    final showLocalVideo = call.isVideo &&
        _calls.localStream != null &&
        !_calls.cameraOff &&
        (_calls.localStream?.getVideoTracks().isNotEmpty ?? false) &&
        _calls.phase != CallPhase.ended;

    // In the phone's small floating window: just their picture (or photo).
    if (inPictureInPicture.value && !kIsWeb) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: videoLive
            ? RTCVideoView(_remote, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            : Center(child: PersonAvatar(uid: call.otherId(_calls.myUid), name: name, fallbackPhoto: photo, size: 72)),
      );
    }

    return PopScope(
      canPop: _calls.phase == CallPhase.idle || _calls.phase == CallPhase.ended,
      // Back during a video call: keep it going in a small floating window.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canPopOut) _popOut();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: videoLive ? () => setState(() => _controlsVisible = !_controlsVisible) : null,
          child: LayoutBuilder(
            builder: (context, box) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Background: the other person's video, or a soft glow.
                  if (videoLive)
                    RTCVideoView(_remote, objectFit: _remoteFit(Size(box.maxWidth, box.maxHeight)))
                  else
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(0, -0.35),
                          radius: 1.1,
                          colors: [Color(0xFF2A2410), AppColors.bg],
                        ),
                      ),
                    ),
                  if (!videoLive)
                    SafeArea(
                      child: Center(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _pulsingAvatar(name, photo, call.otherId(_calls.myUid)),
                              const SizedBox(height: 28),
                              Text(name, style: AppTheme.display(30), textAlign: TextAlign.center),
                              const SizedBox(height: 8),
                              _statusText(),
                              if (theirCameraOff && _calls.phase == CallPhase.connected) ...[
                                const SizedBox(height: 10),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.videocam_off_rounded, size: 16, color: AppColors.textMuted),
                                    const SizedBox(width: 6),
                                    Text('Camera off', style: AppTheme.body(13, color: AppColors.textMuted)),
                                  ],
                                ),
                              ],
                              if (_calls.mediaNote != null && _calls.phase != CallPhase.ended) ...[
                                const SizedBox(height: 10),
                                Text(_calls.mediaNote!, textAlign: TextAlign.center, style: AppTheme.body(13, color: AppColors.error)),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (videoLive)
                    AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: SafeArea(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            margin: const EdgeInsets.only(top: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(20)),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(name, style: AppTheme.display(17, weight: FontWeight.w700)),
                                _statusText(size: 13),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Your own camera: drag it anywhere and it settles in the nearest corner.
                  if (showLocalVideo) _selfView(Size(box.maxWidth, box.maxHeight), videoLive),
                  // Microphone, speaker, camera and noise reduction.
                  if (_calls.phase != CallPhase.incoming && _calls.phase != CallPhase.ended)
                    Positioned(
                      top: MediaQuery.paddingOf(context).top + 12,
                      left: 14,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible || !videoLive ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: Semantics(
                          button: true,
                          label: 'Call settings',
                          child: CircleIconButton(
                            icon: Icons.tune_rounded,
                            size: 44,
                            onTap: _openSettings,
                            background: Colors.black.withValues(alpha: 0.45),
                            foreground: AppColors.text,
                          ),
                        ),
                      ),
                    ),
                  // Pop the video call out into a small floating window.
                  if (_canPopOut)
                    Positioned(
                      top: MediaQuery.paddingOf(context).top + 12,
                      left: 66,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible || !videoLive ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: Semantics(
                          button: true,
                          label: 'Pop out',
                          child: CircleIconButton(
                            icon: Icons.picture_in_picture_alt_rounded,
                            size: 44,
                            onTap: _popOut,
                            background: Colors.black.withValues(alpha: 0.45),
                            foreground: AppColors.text,
                          ),
                        ),
                      ),
                    ),
                  // Controls
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: AnimatedSlide(
                      offset: Offset(0, _controlsVisible || !videoLive ? 0 : 1.2),
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 460),
                              child: _calls.phase == CallPhase.incoming ? _incomingControls() : _activeControls(call.isVideo),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Fill the screen when their picture is the same shape as the screen (a phone held
  /// upright on a phone); otherwise show all of it, so a phone's upright picture isn't
  /// cut down to a strip on a wide computer screen.
  RTCVideoViewObjectFit _remoteFit(Size screen) {
    final v = _remote.value;
    if (v.width == 0 || v.height == 0) return RTCVideoViewObjectFit.RTCVideoViewObjectFitContain;
    final theirsUpright = v.aspectRatio < 1;
    final screenUpright = screen.height >= screen.width;
    return theirsUpright == screenUpright ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain;
  }

  /// Your own picture, the shape your camera sends (upright from a phone, wide from a
  /// laptop), in one of the four corners.
  Widget _selfView(Size screen, bool videoLive) {
    final v = _local.value;
    final aspect = v.width > 0 && v.height > 0 ? v.aspectRatio : (kIsWeb ? 16 / 9 : 3 / 4);
    final longSide = (screen.shortestSide * 0.36).clamp(120.0, 260.0);
    final size = aspect < 1 ? Size(longSide * aspect, longSide) : Size(longSide, longSide / aspect);
    final pad = MediaQuery.paddingOf(context);
    const margin = 14.0;
    final top = pad.top + margin + (videoLive ? 64 : 0);
    // Above the buttons along the bottom.
    final bottom = screen.height - size.height - pad.bottom - 128;
    Offset cornerSpot(Alignment c) => Offset(c.x < 0 ? margin : screen.width - size.width - margin, c.y < 0 ? top : bottom.clamp(top, screen.height));
    final spot = _pipDrag ?? cornerSpot(_pipCorner);

    return AnimatedPositioned(
      duration: _pipDrag == null ? const Duration(milliseconds: 260) : Duration.zero,
      curve: Curves.easeOutCubic,
      left: spot.dx,
      top: spot.dy,
      child: GestureDetector(
        onPanStart: (_) => setState(() => _pipDrag = spot),
        onPanUpdate: (d) => setState(() {
          final next = (_pipDrag ?? spot) + d.delta;
          _pipDrag = Offset(next.dx.clamp(0, screen.width - size.width), next.dy.clamp(0, screen.height - size.height));
        }),
        onPanEnd: (d) => setState(() {
          // The nearest corner, nudged by a flick in its direction.
          final at = (_pipDrag ?? spot) + Offset(size.width / 2, size.height / 2) + d.velocity.pixelsPerSecond * 0.15;
          _pipCorner = Alignment(at.dx < screen.width / 2 ? -1 : 1, at.dy < screen.height / 2 ? -1 : 1);
          _pipDrag = null;
        }),
        // Just the picture with rounded corners and a soft shadow: no coloured frame
        // that could peek out around the video.
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18)],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Container(
              color: Colors.black,
              width: size.width,
              height: size.height,
              child: RTCVideoView(_local, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusText({double size = 16}) {
    final ended = _calls.phase == CallPhase.ended;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Text(
        _status(),
        key: ValueKey('${_calls.phase}-${ended ? _calls.endMessage : ''}'),
        textAlign: TextAlign.center,
        style: AppTheme.body(size, weight: ended ? FontWeight.w700 : FontWeight.w500, color: ended ? AppColors.primary : AppColors.textMuted),
      ),
    );
  }

  Widget _pulsingAvatar(String name, String photo, String uid) {
    final ringing = _calls.phase == CallPhase.outgoing || _calls.phase == CallPhase.incoming || _calls.phase == CallPhase.connecting;
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (ringing)
            AnimatedBuilder(
              animation: _rings,
              builder: (_, _) => Stack(
                alignment: Alignment.center,
                children: List.generate(3, (i) {
                  final t = (_rings.value + i / 3) % 1;
                  return Container(
                    width: 120 + t * 100,
                    height: 120 + t * 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.primary.withValues(alpha: (1 - t) * 0.55), width: 2),
                    ),
                  );
                }),
              ),
            ),
          AnimatedScale(
            scale: _calls.phase == CallPhase.ended ? 0.92 : 1,
            duration: const Duration(milliseconds: 300),
            child: PersonAvatar(uid: uid, name: name, fallbackPhoto: photo, size: 120),
          ),
        ],
      ),
    );
  }

  Widget _incomingControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _BigCallButton(icon: Icons.call_end_rounded, label: 'Decline', color: AppColors.error, onTap: _calls.decline),
        _BigCallButton(
          icon: _calls.call?.isVideo == true ? Icons.videocam_rounded : Icons.call_rounded,
          label: 'Accept',
          color: AppColors.online,
          onTap: _calls.accept,
          bounce: true,
        ),
      ],
    );
  }

  static IconData _outputIcon(String output) {
    switch (output) {
      case 'speaker':
        return Icons.volume_up_rounded;
      case 'bluetooth':
        return Icons.bluetooth_audio_rounded;
      case 'wired-headset':
        return Icons.headset_rounded;
      default:
        return Icons.phone_in_talk_rounded;
    }
  }

  static String _outputName(String output) {
    switch (output) {
      case 'speaker':
        return 'Speaker';
      case 'bluetooth':
        return 'Bluetooth';
      case 'wired-headset':
        return 'Headphones';
      default:
        return 'Phone (in-ear)';
    }
  }

  /// With only the earpiece and speaker, a tap switches between them; with a headset
  /// connected too, it asks which one.
  Future<void> _chooseOutput() async {
    final outputs = _calls.audioOutputs;
    if (outputs.length <= 2) {
      await _calls.toggleSpeaker();
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgAlt,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Play sound through', style: AppTheme.display(18, weight: FontWeight.w700)),
            ),
            for (final output in outputs)
              ListTile(
                leading: Icon(_outputIcon(output), color: output == _calls.audioOutput ? AppColors.primary : AppColors.text),
                title: Text(_outputName(output)),
                trailing: output == _calls.audioOutput ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
                onTap: () => Navigator.pop(sheet, output),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) await _calls.selectAudioOutput(picked);
  }

  /// Microphone, speaker, camera and noise reduction, changeable during the call.
  Future<void> _openSettings() async {
    unawaited(_calls.refreshDevices());
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgAlt,
      builder: (sheet) => ListenableBuilder(
        listenable: _calls,
        builder: (context, _) {
          final video = _calls.call?.isVideo == true;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    child: Text('Call settings', style: AppTheme.display(20, weight: FontWeight.w700)),
                  ),
                  SwitchListTile(
                    value: _calls.noiseReduction,
                    onChanged: _calls.setNoiseReduction,
                    secondary: const Icon(Icons.graphic_eq_rounded, color: AppColors.primary),
                    title: const Text('Noise reduction'),
                    subtitle: const Text('Filters out background noise so your voice comes through clearly'),
                  ),
                  _settingsHeading('Microphone'),
                  if (_calls.microphones.isEmpty)
                    _settingsNote('No microphone found')
                  else
                    for (final mic in _calls.microphones)
                      _choice(
                        icon: Icons.mic_rounded,
                        label: _deviceLabel(mic.label, 'Microphone'),
                        selected: mic.deviceId == _calls.microphoneId || (_calls.microphoneId == null && mic == _calls.microphones.first),
                        onTap: () => _calls.selectMicrophone(mic.deviceId),
                      ),
                  _settingsHeading('Sound'),
                  if (kIsWeb)
                    if (_calls.speakers.isEmpty)
                      _settingsNote("This browser plays calls through your computer's sound settings")
                    else
                      for (final speaker in _calls.speakers)
                        _choice(
                          icon: Icons.volume_up_rounded,
                          label: _deviceLabel(speaker.label, 'Speaker'),
                          selected: speaker.deviceId == (_calls.speakerId ?? 'default') ||
                              (_calls.speakerId == null && !_calls.speakers.any((s) => s.deviceId == 'default') && speaker == _calls.speakers.first),
                          onTap: () => _calls.selectSpeaker(speaker.deviceId),
                        )
                  else
                    for (final output in _calls.audioOutputs)
                      _choice(
                        icon: _outputIcon(output),
                        label: _outputName(output),
                        selected: output == _calls.audioOutput,
                        onTap: () => _calls.selectAudioOutput(output),
                      ),
                  if (video && kIsWeb && _calls.cameras.length > 1) ...[
                    _settingsHeading('Camera'),
                    for (final cam in _calls.cameras)
                      _choice(
                        icon: Icons.videocam_rounded,
                        label: _deviceLabel(cam.label, 'Camera'),
                        selected: cam.deviceId == _calls.cameraId || (_calls.cameraId == null && cam == _calls.cameras.first),
                        onTap: () => _calls.selectCamera(cam.deviceId),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Browsers add things like "Default - " and "(0bda:58fd)" to names; keep the readable part.
  static String _deviceLabel(String label, String fallback) {
    var l = label.replaceAll(RegExp(r'\s*\([0-9a-fA-F]{4}:[0-9a-fA-F]{4}\)'), '').trim();
    if (l.startsWith('Default - ')) l = 'Default (${l.substring(10)})';
    if (l.startsWith('Communications - ')) l = 'Calls default (${l.substring(17)})';
    return l.isEmpty ? fallback : l;
  }

  Widget _settingsHeading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text.toUpperCase(), style: AppTheme.body(12, weight: FontWeight.w700, color: AppColors.textMuted)),
      );

  Widget _settingsNote(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(text, style: AppTheme.body(13.5, color: AppColors.textMuted)),
      );

  Widget _choice({required IconData icon, required String label, required bool selected, required VoidCallback onTap}) => ListTile(
        leading: Icon(icon, color: selected ? AppColors.primary : AppColors.textMuted),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: selected ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
        onTap: onTap,
      );

  Widget _activeControls(bool video) {
    final ended = _calls.phase == CallPhase.ended;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Toggle(icon: _calls.muted ? Icons.mic_off_rounded : Icons.mic_rounded, active: _calls.muted, label: 'Mute', onTap: ended ? null : _calls.toggleMute),
          if (video) ...[
            _Toggle(
              icon: _calls.cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
              active: _calls.cameraOff,
              label: 'Camera',
              onTap: ended ? null : _calls.toggleCamera,
            ),
            // A computer usually has one camera.
            if (!kIsWeb) _Toggle(icon: Icons.cameraswitch_rounded, active: false, label: 'Flip', onTap: ended ? null : _calls.switchCamera),
          ],
          // Speaker, earpiece, wired headset or Bluetooth (a computer uses its own setting).
          if (!kIsWeb)
            _Toggle(
              icon: _outputIcon(_calls.audioOutput),
              active: _calls.audioOutput != 'earpiece',
              label: 'Sound: ${_outputName(_calls.audioOutput)}',
              onTap: ended ? null : _chooseOutput,
            ),
          TapScale(
            onTap: ended ? null : _calls.hangUp,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: ended ? AppColors.borderLight : AppColors.error, shape: BoxShape.circle),
              child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 30),
            ),
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback? onTap;
  const _Toggle({required this.icon, required this.active, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: CircleIconButton(
        icon: icon,
        size: 54,
        onTap: onTap,
        background: active ? AppColors.text : Colors.white.withValues(alpha: 0.12),
        foreground: active ? AppColors.textDark : AppColors.text,
      ),
    );
  }
}

class _BigCallButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool bounce;
  const _BigCallButton({required this.icon, required this.label, required this.color, required this.onTap, this.bounce = false});

  @override
  State<_BigCallButton> createState() => _BigCallButtonState();
}

class _BigCallButtonState extends State<_BigCallButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.bounce) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _c,
          builder: (_, child) => Transform.translate(offset: Offset(0, -6 * Curves.easeInOut.transform(_c.value)), child: child),
          child: TapScale(
            onTap: () {
              HapticFeedback.heavyImpact();
              widget.onTap();
            },
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.45), blurRadius: 24, spreadRadius: 2)],
              ),
              child: Icon(widget.icon, color: Colors.white, size: 34),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(widget.label, style: AppTheme.body(14, weight: FontWeight.w600)),
      ],
    );
  }
}
