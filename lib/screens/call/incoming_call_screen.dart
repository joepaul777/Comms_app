import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_colors.dart';
import '../../models/call_model.dart';
import '../../services/call_service.dart';
import 'audio_call_screen.dart';
import 'video_call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  final CallModel call;

  const IncomingCallScreen({super.key, required this.call});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  final CallService _callService = CallService();
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    // Play the device's default ringtone when the screen opens
    FlutterRingtonePlayer().playRingtone(looping: true, volume: 1.0);
  }

  @override
  void dispose() {
    // Always stop the ringtone when this screen is closed
    FlutterRingtonePlayer().stop();
    super.dispose();
  }

  Future<void> _rejectCall() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    FlutterRingtonePlayer().stop();
    await _callService.rejectCall(widget.call.id);
    if (mounted) Navigator.pop(context);
  }

  void _acceptCall() {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    FlutterRingtonePlayer().stop();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => widget.call.type == CallType.video
            ? VideoCallScreen(call: widget.call, isIncoming: true)
            : AudioCallScreen(call: widget.call, isIncoming: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            // Caller avatar
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: AppColors.bgAlt,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.5),
                  width: 3,
                ),
                image: widget.call.callerPhoto.isNotEmpty
                    ? DecorationImage(
                        image: NetworkImage(widget.call.callerPhoto),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: widget.call.callerPhoto.isEmpty
                  ? Center(
                      child: Text(
                        widget.call.callerName.isNotEmpty
                            ? widget.call.callerName[0].toUpperCase()
                            : '?',
                        style: GoogleFonts.outfit(
                          fontSize: 40,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 24),
            Text(
              widget.call.callerName,
              style: GoogleFonts.outfit(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.call.type == CallType.video
                  ? 'Incoming Video Call'
                  : 'Incoming Audio Call',
              style: GoogleFonts.inter(
                fontSize: 16,
                color: AppColors.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(flex: 3),
            // Accept / Reject buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 60),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Reject button
                  Column(
                    children: [
                      GestureDetector(
                        onTap: _rejectCall,
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
                      const SizedBox(height: 10),
                      Text(
                        'Decline',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                  // Accept button
                  Column(
                    children: [
                      GestureDetector(
                        onTap: _acceptCall,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: AppColors.online,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.online.withValues(alpha: 0.4),
                                blurRadius: 16,
                              ),
                            ],
                          ),
                          child: Icon(
                            widget.call.type == CallType.video
                                ? Icons.videocam_rounded
                                : Icons.call_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Accept',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
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
