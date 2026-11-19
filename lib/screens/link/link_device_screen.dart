import 'package:flutter/material.dart';
import '../../platform/platform.dart';
import '../../services/auth_service.dart';
import '../../services/device_link.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// How the link screen ended.
enum LinkOutcome { linked, startFresh }

/// Shown in a browser whose account already has its key on a phone: asks the phone
/// to hand the key over, so this browser can read the same messages.
class LinkDeviceScreen extends StatefulWidget {
  final String uid;
  const LinkDeviceScreen({super.key, required this.uid});

  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  String? _code;
  String? _problem;
  VoidCallback? _cancel;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    _cancel?.call();
    setState(() {
      _code = null;
      _problem = null;
    });
    try {
      final (code, done, cancel) = await DeviceLink.ask(widget.uid, deviceName);
      _cancel = cancel;
      if (!mounted) return cancel();
      setState(() => _code = code);
      final linked = await done.timeout(DeviceLink.lifetime);
      if (!mounted) return;
      if (linked) {
        _finished = true;
        Navigator.of(context).pop(LinkOutcome.linked);
      } else if (!_finished) {
        setState(() => _problem = 'Your phone said no. Try again if that was a mistake.');
      }
    } catch (e) {
      _cancel?.call();
      if (mounted) {
        setState(() => _problem = 'That didn\'t work. Check your connection and try again.');
      }
    }
  }

  @override
  void dispose() {
    if (!_finished) _cancel?.call();
    super.dispose();
  }

  Future<void> _startFresh() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Start fresh in this browser?'),
        content: const Text(
          'New messages will be locked for this browser instead of your phone. '
          'Your phone won\'t be able to read them until you switch back, and older messages stay readable only on your phone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Start fresh', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _finished = true;
    _cancel?.call();
    Navigator.of(context).pop(LinkOutcome.startFresh);
  }

  Widget _step(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
            child: Center(child: Text(number, style: AppTheme.body(13, weight: FontWeight.w800, color: AppColors.primary))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: AppTheme.body(15, height: 1.45))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(20)),
                      child: const Icon(Icons.devices_rounded, color: AppColors.textDark, size: 32),
                    ),
                    const SizedBox(height: 28),
                    Text('Link this browser', style: AppTheme.display(34, weight: FontWeight.w900)),
                    const SizedBox(height: 10),
                    Text(
                      'Your messages are end-to-end encrypted, so only your phone can unlock them. Your phone can share that with this browser.',
                      style: AppTheme.body(15.5, color: AppColors.textMuted, height: 1.5),
                    ),
                    const SizedBox(height: 28),
                    _step('1', 'Open Comms on your phone (version 2.2 or newer).'),
                    _step('2', 'It will ask to link $deviceName. Check the code there matches this one.'),
                    _step('3', 'Tap Link. This page opens your chats straight away.'),
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
                      decoration: BoxDecoration(
                        color: AppColors.bgCard,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: _problem == null ? AppColors.border : AppColors.error.withValues(alpha: 0.5)),
                      ),
                      child: _problem != null
                          ? Column(
                              children: [
                                Text(_problem!, textAlign: TextAlign.center, style: AppTheme.body(14.5, color: AppColors.text, height: 1.45)),
                                const SizedBox(height: 16),
                                ElevatedButton(onPressed: _ask, child: const Text('Try again')),
                              ],
                            )
                          : Column(
                              children: [
                                Text('Code', style: AppTheme.body(13, weight: FontWeight.w700, color: AppColors.textMuted)),
                                const SizedBox(height: 6),
                                code == null
                                    ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator())
                                    : SelectableText(code, style: AppTheme.display(44, weight: FontWeight.w900, color: AppColors.primary)),
                                const SizedBox(height: 10),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textMuted)),
                                    const SizedBox(width: 10),
                                    Text('Waiting for your phone', style: AppTheme.body(13.5, color: AppColors.textMuted)),
                                  ],
                                ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 22),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(onPressed: _startFresh, child: const Text('Lost your phone? Start fresh here')),
                        TextButton(
                          onPressed: () {
                            _finished = true;
                            _cancel?.call();
                            Navigator.of(context).pop();
                            AuthService.instance.signOut();
                          },
                          child: const Text('Sign out', style: TextStyle(color: AppColors.textMuted)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
