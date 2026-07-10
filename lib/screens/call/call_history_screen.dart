import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../services/call_service.dart';
import '../../models/call_model.dart';
import '../../utils/image_utils.dart';

class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  final CallService _callService = CallService();
  final AuthService _authService = AuthService();

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    final hour = time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour);
    final period = time.hour >= 12 ? 'PM' : 'AM';
    final minute = time.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute $period';

    if (diff.inDays == 0) return timeStr;
    if (diff.inDays == 1) return 'Yesterday, $timeStr';
    return '${time.day}/${time.month}, $timeStr';
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds == 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = _authService.currentUserId;
    if (currentUid == null) return const SizedBox();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(
          'Calls',
          style: GoogleFonts.outfit(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: AppColors.text,
          ),
        ),
      ),
      body: StreamBuilder<List<CallModel>>(
        stream: _callService.getCallHistory(currentUid),
        builder: (context, snapshot) {
          final calls = snapshot.data ?? [];

          if (calls.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.call_outlined,
                    size: 64,
                    color: AppColors.textMuted.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No calls yet',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Start a call from a chat',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppColors.textMuted.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: calls.length,
            itemBuilder: (context, index) {
              final call = calls[index];
              final isOutgoing = call.callerId == currentUid;
              final otherName =
                  isOutgoing ? call.receiverName : call.callerName;
              final otherPhoto =
                  isOutgoing ? call.receiverPhoto : call.callerPhoto;
              final isMissed = call.status == CallStatus.missed ||
                  call.status == CallStatus.rejected;

              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    // Avatar
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.bgElevated,
                        borderRadius: BorderRadius.circular(14),
                        image: otherPhoto.isNotEmpty
                            ? DecorationImage(
                                image: getImageProvider(otherPhoto),
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
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 14),
                    // Info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            otherName,
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: isMissed
                                  ? AppColors.error
                                  : AppColors.text,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(
                                isOutgoing
                                    ? Icons.call_made_rounded
                                    : Icons.call_received_rounded,
                                size: 14,
                                color: isMissed
                                    ? AppColors.error
                                    : isOutgoing
                                        ? AppColors.outgoing
                                        : AppColors.incoming,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _formatTime(call.timestamp),
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: AppColors.textMuted,
                                ),
                              ),
                              if (call.duration != null && call.duration! > 0)
                                Text(
                                  ' • ${_formatDuration(call.duration)}',
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Call type icon
                    Icon(
                      call.type == CallType.video
                          ? Icons.videocam_rounded
                          : Icons.call_rounded,
                      color: AppColors.primary,
                      size: 22,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
