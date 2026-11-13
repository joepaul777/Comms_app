import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/call_model.dart';
import '../../models/user_model.dart';
import '../../services/call_service.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';

class CallHistoryScreen extends StatefulWidget {
  final UserModel me;
  const CallHistoryScreen({super.key, required this.me});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  late final Stream<List<CallModel>> _history = CallService.instance.history(widget.me.uid);
  bool _missedOnly = false;

  bool _isMissed(CallModel c) =>
      c.receiverId == widget.me.uid && (c.status == CallStatus.missed || (c.status == CallStatus.rejected && c.endedBy != widget.me.uid));

  Future<void> _callBack(CallModel c) async {
    final other = await UserService.instance.getUser(c.otherId(widget.me.uid));
    if (other == null) return;
    final error = await CallService.instance.startCall(me: widget.me, other: other, type: c.type);
    if (error != null && mounted) showSnack(context, error, error: true);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          const PageHeader(title: 'Calls'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                _FilterPill(label: 'All', selected: !_missedOnly, onTap: () => setState(() => _missedOnly = false)),
                const SizedBox(width: 8),
                _FilterPill(label: 'Missed', selected: _missedOnly, onTap: () => setState(() => _missedOnly = true)),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<CallModel>>(
              stream: _history,
              builder: (context, snap) {
                if (snap.hasError) {
                  return const EmptyState(icon: Icons.cloud_off_rounded, title: 'Can\'t load calls', message: 'Check your connection and try again.');
                }
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final calls = _missedOnly ? snap.data!.where(_isMissed).toList() : snap.data!;
                if (calls.isEmpty) {
                  return EmptyState(
                    icon: _missedOnly ? Icons.phone_missed_rounded : Icons.call_rounded,
                    title: _missedOnly ? 'No missed calls' : 'No calls yet',
                    message: 'Start a voice or video call from any chat.',
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 120),
                  itemCount: calls.length,
                  itemBuilder: (context, i) => FadeSlideIn(index: i, child: _tile(calls[i])),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(CallModel c) {
    final outgoing = c.callerId == widget.me.uid;
    final missed = _isMissed(c);
    final IconData icon;
    final Color color;
    final String detail;
    if (missed) {
      icon = Icons.call_missed_rounded;
      color = AppColors.missed;
      detail = 'Missed';
    } else if (outgoing) {
      icon = Icons.call_made_rounded;
      color = AppColors.outgoing;
      detail = switch (c.endReason) {
        'declined' => 'Declined',
        'no-answer' => 'No answer',
        'busy' => 'Busy',
        'cancelled' => 'Cancelled',
        _ => c.duration != null ? formatDuration(Duration(seconds: c.duration!)) : 'Outgoing',
      };
    } else {
      icon = Icons.call_received_rounded;
      color = AppColors.incoming;
      detail = c.status == CallStatus.rejected ? 'Declined' : (c.duration != null ? formatDuration(Duration(seconds: c.duration!)) : 'Incoming');
    }
    final name = c.otherName(widget.me.uid);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Avatar(name: name, photoUrl: c.otherPhoto(widget.me.uid), size: 48),
      title: Text(name, style: AppTheme.body(15.5, weight: FontWeight.w600, color: missed ? AppColors.missed : AppColors.text)),
      subtitle: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text('$detail · ${_when(c.timestamp)}', overflow: TextOverflow.ellipsis, style: AppTheme.body(13, color: AppColors.textMuted)),
          ),
        ],
      ),
      trailing: CircleIconButton(
        icon: c.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
        background: AppColors.primarySoft,
        foreground: AppColors.primary,
        size: 40,
        tooltip: 'Call back',
        onTap: () => _callBack(c),
      ),
    );
  }

  static String _when(DateTime t) {
    final now = DateTime.now();
    if (DateUtils.isSameDay(t, now)) return DateFormat.jm().format(t);
    if (DateUtils.isSameDay(t, now.subtract(const Duration(days: 1)))) return 'Yesterday';
    return DateFormat.MMMd().format(t);
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterPill({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TapScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.bgAlt,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: selected ? AppColors.primary : AppColors.border),
        ),
        child: Text(label, style: AppTheme.body(13.5, weight: FontWeight.w700, color: selected ? AppColors.textDark : AppColors.textMuted)),
      ),
    );
  }
}
