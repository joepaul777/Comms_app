import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_colors.dart';
import '../../services/call_service.dart';
import '../../models/call_model.dart';

class AudioCallScreen extends StatefulWidget {
  final CallModel call;
  final bool isIncoming;

  const AudioCallScreen({
    super.key,
    required this.call,
    required this.isIncoming,
  });

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen>
    with TickerProviderStateMixin {
  final CallService _callService = CallService();
  bool _isMuted = false;
  bool _isSpeaker = false;
  CallStatus _status = CallStatus.ringing;
  int _callDuration = 0;
  Timer? _timer;
  bool _hasEnded = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Sync initial status
    _status = _callService.currentStatus;
    if (_status == CallStatus.connected) {
      _startTimer();
      _pulseController.stop();
    }

    _callService.onCallStatusChanged = (status) {
      if (!mounted || _hasEnded) return;
      setState(() => _status = status);
      if (status == CallStatus.connected) {
        _startTimer();
        _pulseController.stop();
      } else if (status == CallStatus.rejected) {
        _handleRejected();
      } else if (status == CallStatus.ended ||
          status == CallStatus.missed) {
        _handleEnded();
      }
    };

    if (widget.isIncoming) {
      _callService.answerCall(widget.call.id, false);
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _callDuration++);
    });
  }

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Called when the OTHER side rejected the call
  void _handleRejected() {
    if (_hasEnded) return;
    _hasEnded = true;
    _timer?.cancel();
    _pulseController.stop();

    // Show "Call Declined" briefly, then pop
    if (mounted) {
      setState(() => _status = CallStatus.rejected);
    }

    Future.delayed(const Duration(seconds: 2), () {
      _callService.cleanupCall();
      if (mounted) Navigator.pop(context);
    });
  }

  /// Called when the call ends normally or due to timeout
  void _handleEnded() {
    if (_hasEnded) return;
    _hasEnded = true;
    _timer?.cancel();
    _pulseController.stop();
    _callService.cleanupCall();
    if (mounted) Navigator.pop(context);
  }

  /// Called when the USER taps the end-call button
  Future<void> _endCall() async {
    if (_hasEnded) return;
    _hasEnded = true;
    _timer?.cancel();
    _pulseController.stop();
    await _callService.endCall(widget.call.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseController.dispose();
    // DON'T call _callService.dispose() — it's a singleton
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _status == CallStatus.connected;
    final isRejected = _status == CallStatus.rejected;
    final otherName = widget.isIncoming
        ? widget.call.callerName
        : widget.call.receiverName;
    final otherPhoto = widget.isIncoming
        ? widget.call.callerPhoto
        : widget.call.receiverPhoto;

    String statusText;
    if (isConnected) {
      statusText = _formatDuration(_callDuration);
    } else if (isRejected) {
      statusText = 'Call Declined';
    } else if (_status == CallStatus.missed) {
      statusText = 'No Answer';
    } else if (_status == CallStatus.ringing) {
      statusText = widget.isIncoming ? 'Incoming call...' : 'Calling...';
    } else {
      statusText = _status.name;
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            // Avatar
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: isConnected || isRejected
                      ? 1.0
                      : _pulseAnimation.value,
                  child: child,
                );
              },
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: AppColors.bgAlt,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isRejected
                        ? AppColors.error.withValues(alpha: 0.5)
                        : isConnected
                            ? AppColors.online
                            : AppColors.primary.withValues(alpha: 0.5),
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (isRejected
                              ? AppColors.error
                              : isConnected
                                  ? AppColors.online
                                  : AppColors.primary)
                          .withValues(alpha: 0.2),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                  image: otherPhoto.isNotEmpty
                      ? DecorationImage(
                          image: NetworkImage(otherPhoto),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: otherPhoto.isEmpty
                    ? Center(
                        child: Text(
                          otherName.isNotEmpty
                              ? otherName[0].toUpperCase()
                              : '?',
                          style: GoogleFonts.outfit(
                            fontSize: 48,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primary,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 24),
            // Name
            Text(
              otherName,
              style: GoogleFonts.outfit(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 8),
            // Status
            Text(
              statusText,
              style: GoogleFonts.inter(
                fontSize: 16,
                color: isConnected
                    ? AppColors.online
                    : isRejected
                        ? AppColors.error
                        : AppColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(flex: 3),
            // Controls — hide if rejected
            if (!isRejected)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallButton(
                      icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      label: _isMuted ? 'Unmute' : 'Mute',
                      isActive: _isMuted,
                      onTap: () {
                        setState(() => _isMuted = !_isMuted);
                        _callService.toggleMute(_isMuted);
                      },
                    ),
                    _CallButton(
                      icon: _isSpeaker
                          ? Icons.volume_up_rounded
                          : Icons.volume_down_rounded,
                      label: 'Speaker',
                      isActive: _isSpeaker,
                      onTap: () {
                        setState(() => _isSpeaker = !_isSpeaker);
                        _callService.toggleSpeaker(_isSpeaker);
                      },
                    ),
                    // End call button
                    GestureDetector(
                      onTap: _endCall,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.error,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.error.withValues(alpha: 0.4),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.call_end_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.primary.withValues(alpha: 0.2)
                  : AppColors.bgAlt,
              shape: BoxShape.circle,
              border: Border.all(
                color: isActive ? AppColors.primary : AppColors.border,
              ),
            ),
            child: Icon(
              icon,
              color: isActive ? AppColors.primary : AppColors.textMuted,
              size: 24,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
