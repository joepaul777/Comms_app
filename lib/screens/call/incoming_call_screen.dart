import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_colors.dart';
import '../../models/call_model.dart';
import '../../services/call_service.dart';
import 'audio_call_screen.dart';
import 'video_call_screen.dart';

class IncomingCallScreen extends StatelessWidget {
  final CallModel call;

  const IncomingCallScreen({super.key, required this.call});

  @override
  Widget build(BuildContext context) {
    final callService = CallService();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            // Caller info
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
                image: call.callerPhoto.isNotEmpty
                    ? DecorationImage(
                        image: NetworkImage(call.callerPhoto),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: call.callerPhoto.isEmpty
                  ? Center(
                      child: Text(
                        call.callerName.isNotEmpty
                            ? call.callerName[0].toUpperCase()
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
              call.callerName,
              style: GoogleFonts.outfit(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              call.type == CallType.video
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
                  // Reject
                  Column(
                    children: [
                      GestureDetector(
                        onTap: () async {
                          await callService.rejectCall(call.id);
                          if (context.mounted) Navigator.pop(context);
                        },
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
                  // Accept
                  Column(
                    children: [
                      GestureDetector(
                        onTap: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => call.type == CallType.video
                                  ? VideoCallScreen(
                                      call: call,
                                      isIncoming: true,
                                    )
                                  : AudioCallScreen(
                                      call: call,
                                      isIncoming: true,
                                    ),
                            ),
                          );
                        },
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: AppColors.online,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color:
                                    AppColors.online.withValues(alpha: 0.4),
                                blurRadius: 16,
                              ),
                            ],
                          ),
                          child: Icon(
                            call.type == CallType.video
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
