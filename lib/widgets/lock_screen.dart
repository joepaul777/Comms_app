import 'package:flutter/material.dart';
import '../services/app_lock.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Covers the whole app while it is locked, and asks for the phone's lock straight away.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => AppLock.instance.unlock());
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bg,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(26)),
                child: Center(child: Text('CO.', style: AppTheme.display(28, weight: FontWeight.w900, color: AppColors.textDark))),
              ),
              const SizedBox(height: 22),
              Text('Comms is locked', style: AppTheme.display(22)),
              const SizedBox(height: 6),
              Text('Use your fingerprint, face or screen lock', style: AppTheme.body(14, color: AppColors.textMuted)),
              const SizedBox(height: 26),
              ElevatedButton.icon(
                onPressed: AppLock.instance.unlock,
                icon: const Icon(Icons.lock_open_rounded),
                label: const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
