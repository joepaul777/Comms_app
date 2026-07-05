import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_colors.dart';
import '../../services/call_service.dart';
import '../../models/call_model.dart';

class VideoCallScreen extends StatefulWidget {
  final CallModel call;
  final bool isIncoming;

  const VideoCallScreen({
    super.key,
    required this.call,
    required this.isIncoming,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  final CallService _callService = CallService();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isFrontCamera = true;
  bool _showControls = true;
  CallStatus _status = CallStatus.ringing;
  int _callDuration = 0;
  Timer? _timer;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    _status = _callService.currentStatus;
    if (_status == CallStatus.connected) {
      _startTimer();
    }
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    if (_callService.localStream != null) {
      _localRenderer.srcObject = _callService.localStream;
    }
    _callService.onLocalStream = (stream) {
      if (mounted) {
        setState(() {
          _localRenderer.srcObject = stream;
        });
      }
    };

    if (_callService.remoteStream != null) {
      _remoteRenderer.srcObject = _callService.remoteStream;
    }
    _callService.onRemoteStream = (stream) {
      if (mounted) {
        setState(() {
          _remoteRenderer.srcObject = stream;
        });
      }
    };

    _callService.onCallStatusChanged = (status) {
      if (mounted) {
        setState(() => _status = status);
        if (status == CallStatus.connected) {
          _startTimer();
        } else if (status == CallStatus.ended ||
            status == CallStatus.rejected) {
          _endCall();
        }
      }
    };

    if (widget.isIncoming) {
      await _callService.answerCall(widget.call.id, true);
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _callDuration++);
    });
    _startHideControlsTimer();
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _status == CallStatus.connected) {
        setState(() => _showControls = false);
      }
    });
  }

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _endCall() async {
    _timer?.cancel();
    _hideControlsTimer?.cancel();
    await _callService.endCall(widget.call.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hideControlsTimer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _callService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _status == CallStatus.connected;
    final otherName = widget.isIncoming
        ? widget.call.callerName
        : widget.call.receiverName;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () {
          setState(() => _showControls = !_showControls);
          if (_showControls) _startHideControlsTimer();
        },
        child: Stack(
          children: [
            // Remote video (full screen)
            if (isConnected && _remoteRenderer.srcObject != null)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              // Waiting screen
              Container(
                width: double.infinity,
                height: double.infinity,
                color: AppColors.bg,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: AppColors.bgAlt,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.5),
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          otherName.isNotEmpty
                              ? otherName[0].toUpperCase()
                              : '?',
                          style: GoogleFonts.outfit(
                            fontSize: 40,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      otherName,
                      style: GoogleFonts.outfit(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.isIncoming ? 'Connecting...' : 'Calling...',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),

            // Local video (PiP)
            if (_localRenderer.srcObject != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 16,
                right: 16,
                child: GestureDetector(
                  onTap: () {}, // Prevent parent tap
                  child: Container(
                    width: 110,
                    height: 155,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.3),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _isCameraOff
                        ? Container(
                            color: AppColors.bgAlt,
                            child: const Center(
                              child: Icon(
                                Icons.videocam_off_rounded,
                                color: AppColors.textMuted,
                                size: 28,
                              ),
                            ),
                          )
                        : RTCVideoView(
                            _localRenderer,
                            mirror: _isFrontCamera,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          ),
                  ),
                ),
              ),

            // Top bar
            if (_showControls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top + 8,
                      left: 16,
                      right: 16,
                      bottom: 12,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.7),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back_rounded),
                          color: Colors.white,
                          onPressed: _endCall,
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                otherName,
                                style: GoogleFonts.outfit(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              if (isConnected)
                                Text(
                                  _formatDuration(_callDuration),
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    color: AppColors.online,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 48), // Balance the back button
                      ],
                    ),
                  ),
                ),
              ),

            // Bottom controls
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    padding: EdgeInsets.only(
                      top: 20,
                      bottom: MediaQuery.of(context).padding.bottom + 24,
                      left: 24,
                      right: 24,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.8),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _VideoCallButton(
                          icon: _isMuted
                              ? Icons.mic_off_rounded
                              : Icons.mic_rounded,
                          isActive: _isMuted,
                          onTap: () {
                            setState(() => _isMuted = !_isMuted);
                            _callService.toggleMute(_isMuted);
                          },
                        ),
                        _VideoCallButton(
                          icon: _isCameraOff
                              ? Icons.videocam_off_rounded
                              : Icons.videocam_rounded,
                          isActive: _isCameraOff,
                          onTap: () {
                            setState(() => _isCameraOff = !_isCameraOff);
                            _callService.toggleCamera(_isCameraOff);
                          },
                        ),
                        _VideoCallButton(
                          icon: Icons.cameraswitch_rounded,
                          isActive: false,
                          onTap: () {
                            setState(() => _isFrontCamera = !_isFrontCamera);
                            _callService.switchCamera();
                          },
                        ),
                        // End call
                        GestureDetector(
                          onTap: _endCall,
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: AppColors.error,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      AppColors.error.withValues(alpha: 0.4),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.call_end_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VideoCallButton extends StatelessWidget {
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const _VideoCallButton({
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: isActive
              ? Colors.white.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.1),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.2),
          ),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}
