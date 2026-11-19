import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/ui.dart';
import '../../platform/platform.dart';

/// What to do with the picked photo or video.
class MediaPreviewResult {
  /// null: normal; 1: view once; 2: view twice.
  final int? viewLimit;
  const MediaPreviewResult(this.viewLimit);
}

/// Shows a picked photo or video before it is sent, with the view-once button beside Send.
class MediaPreviewScreen extends StatefulWidget {
  final File file;
  final bool isVideo;
  final String recipient;
  const MediaPreviewScreen({super.key, required this.file, required this.isVideo, required this.recipient});

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  int? _viewLimit;
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _video = localVideo(widget.file)
        ..setLooping(true)
        ..initialize().then((_) {
          if (!mounted) return;
          setState(() {});
          _video!.play();
        });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  /// Off -> view once -> view twice -> off.
  void _cycle() {
    HapticFeedback.selectionClick();
    setState(() => _viewLimit = switch (_viewLimit) { null => 1, 1 => 2, _ => null });
  }

  String get _label => switch (_viewLimit) {
        1 => 'View once',
        2 => 'View twice',
        _ => 'Kept in chat',
      };

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white), onPressed: () => Navigator.pop(context)),
                  Expanded(
                    child: Text(
                      'To ${widget.recipient}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.body(15, weight: FontWeight.w600, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: widget.isVideo
                    ? (v != null && v.value.isInitialized
                        ? GestureDetector(
                            onTap: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
                            child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
                          )
                        : const CircularProgressIndicator())
                    : InteractiveViewer(child: Image(image: localImage(widget.file), fit: BoxFit.contain)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(a), child: child),
                      ),
                      child: Row(
                        key: ValueKey(_viewLimit),
                        children: [
                          Icon(
                            _viewLimit == null ? Icons.chat_bubble_outline_rounded : Icons.visibility_rounded,
                            size: 18,
                            color: _viewLimit == null ? Colors.white54 : AppColors.primary,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _viewLimit == null ? _label : '$_label · then it disappears',
                              style: AppTheme.body(13.5, color: _viewLimit == null ? Colors.white60 : AppColors.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _ViewOnceButton(limit: _viewLimit, onTap: _cycle),
                  const SizedBox(width: 12),
                  TapScale(
                    onTap: () => Navigator.pop(context, MediaPreviewResult(_viewLimit)),
                    child: Container(
                      width: 58,
                      height: 58,
                      decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                      child: const Icon(Icons.send_rounded, color: AppColors.textDark),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A circle with the number of views: dashed and empty when off, yellow with 1 or 2 when on.
class _ViewOnceButton extends StatelessWidget {
  final int? limit;
  final VoidCallback onTap;
  const _ViewOnceButton({required this.limit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = limit != null;
    return Tooltip(
      message: 'View once',
      child: TapScale(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: on ? AppColors.primary : Colors.white.withValues(alpha: 0.08),
            shape: BoxShape.circle,
            border: Border.all(color: on ? AppColors.primary : Colors.white38, width: 2),
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
              child: Text(
                '${limit ?? 1}',
                key: ValueKey(limit),
                style: AppTheme.display(19, weight: FontWeight.w800, color: on ? AppColors.textDark : Colors.white60),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
