import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/notification_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Comms Web only: on an iPhone in Safari, how to add Comms to the Home Screen (so it
/// opens like an app and can notify); elsewhere, a one-tap way to turn notifications on.
class WebTips extends StatefulWidget {
  const WebTips({super.key});

  @override
  State<WebTips> createState() => _WebTipsState();
}

enum _Tip { none, installOnIphone, notifications }

class _WebTipsState extends State<WebTips> {
  _Tip _tip = _Tip.none;
  static bool _dismissed = false; // until the page is reloaded

  @override
  void initState() {
    super.initState();
    if (kIsWeb && !_dismissed) _decide();
  }

  Future<void> _decide() async {
    final service = NotificationService.instance;
    _Tip tip = _Tip.none;
    if (service.isApplePhone && !service.isInstalled) {
      tip = _Tip.installOnIphone;
    } else if (await service.permissionState() == 'default') {
      tip = _Tip.notifications;
    }
    if (mounted) setState(() => _tip = tip);
  }

  Future<void> _turnOn() async {
    final on = await NotificationService.instance.askPermission();
    if (!mounted) return;
    setState(() => _tip = _Tip.none);
    if (!on) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Notifications are off. You can allow them in your browser settings.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_tip == _Tip.none) return const SizedBox.shrink();
    final install = _tip == _Tip.installOnIphone;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(install ? Icons.add_to_home_screen_rounded : Icons.notifications_active_rounded, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(install ? 'Use Comms like an app' : 'Get notified', style: AppTheme.body(14.5, weight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                    install
                        ? 'Tap the Share button below, then "Add to Home Screen". Open Comms from there to get notifications for messages and calls.'
                        : 'Hear about new messages and calls, even when Comms is closed.',
                    style: AppTheme.body(13, color: AppColors.textMuted, height: 1.4),
                  ),
                  if (!install) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 36,
                      child: ElevatedButton(onPressed: _turnOn, child: const Text('Turn on notifications')),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Not now',
              icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
              onPressed: () {
                _dismissed = true;
                setState(() => _tip = _Tip.none);
              },
            ),
          ],
        ),
      ),
    );
  }
}
