import 'package:flutter/material.dart';
import '../../services/update_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// "A new version is ready" sheet with a one-tap download and install.
Future<void> showUpdateSheet(BuildContext context, ReleaseInfo release) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _UpdateSheet(release: release),
  );
}

class _UpdateSheet extends StatefulWidget {
  final ReleaseInfo release;
  const _UpdateSheet({required this.release});

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  double? _progress;

  Future<void> _install() async {
    setState(() => _progress = 0);
    await UpdateService.install(widget.release, onProgress: (p) {
      if (mounted) setState(() => _progress = p);
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(18)),
              child: const Icon(Icons.rocket_launch_rounded, color: AppColors.textDark, size: 28),
            ),
            const SizedBox(height: 16),
            Text('Comms ${widget.release.version} is here', style: AppTheme.display(24)),
            const SizedBox(height: 8),
            Text(widget.release.notes.isEmpty ? 'A newer version of Comms is ready to install.' : widget.release.notes,
                style: AppTheme.body(14.5, color: AppColors.textMuted, height: 1.5)),
            const SizedBox(height: 22),
            if (_progress != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(value: _progress! > 0 ? _progress : null, minHeight: 8, backgroundColor: AppColors.border),
              ),
              const SizedBox(height: 8),
              Text(_progress! >= 1 ? 'Opening the installer…' : 'Downloading… ${(_progress! * 100).round()}%',
                  style: AppTheme.body(13, color: AppColors.textMuted)),
            ] else
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Later', style: TextStyle(color: AppColors.textMuted)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(onPressed: _install, icon: const Icon(Icons.download_rounded), label: const Text('Update now')),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
