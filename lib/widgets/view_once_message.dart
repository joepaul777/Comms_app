import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../models/message_model.dart';
import '../services/media_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'media_message_widget.dart';

/// A view-once photo or video in the chat. It never shows a preview: the receiver taps
/// to open it, and after the last view it just says "Opened".
class ViewOnceMessage extends StatefulWidget {
  final MessageModel message;
  final bool mine;
  final String myUid;
  final List<String> others; // everyone else in the chat
  final Future<void> Function(File file)? onOpen;
  const ViewOnceMessage({super.key, required this.message, required this.mine, required this.myUid, required this.others, this.onOpen});

  @override
  State<ViewOnceMessage> createState() => _ViewOnceMessageState();
}

class _ViewOnceMessageState extends State<ViewOnceMessage> {
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _tidy();
  }

  @override
  void didUpdateWidget(covariant ViewOnceMessage old) {
    super.didUpdateWidget(old);
    _tidy();
  }

  /// Nothing of a used-up (or own) view-once photo stays on this phone.
  void _tidy() {
    if (widget.mine || widget.message.viewsLeft(widget.myUid) <= 0) MediaService.instance.deleteCopy(widget.message);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final video = m.type == MessageType.video;
    final fg = widget.mine ? AppColors.textDark : AppColors.text;
    final kind = video ? 'Video' : 'Photo';
    final limitText = m.viewLimit == 2 ? 'View twice' : 'View once';

    if (widget.mine) {
      final opened = widget.others.where((o) => (m.viewedBy[o] ?? 0) > 0).length;
      final status = widget.others.length > 1
          ? (opened == 0 ? limitText : 'Opened by $opened')
          : (opened > 0 ? 'Opened' : limitText);
      return _row(fg, opened > 0, kind, status, null);
    }

    final left = m.viewsLeft(widget.myUid);
    if (left <= 0) return _row(fg, true, kind, 'Opened', null);

    return MediaLoader(
      message: m,
      builder: (context, state) {
        final file = state.file;
        String status;
        VoidCallback? tap;
        if (file != null) {
          status = left == 1 ? 'Tap to view · last view' : 'Tap to view · $left views';
          tap = _opening || widget.onOpen == null
              ? null
              : () async {
                  setState(() => _opening = true);
                  await widget.onOpen!(file);
                  if (mounted) setState(() => _opening = false);
                };
        } else if (state.expired) {
          status = 'Expired';
        } else if (state.failed) {
          status = 'Couldn\'t load · tap to retry';
          tap = state.retry;
        } else {
          status = 'Loading…';
        }
        return _row(fg, false, kind, status, tap, loading: file == null && !state.expired && !state.failed);
      },
    );
  }

  Widget _row(Color fg, bool used, String kind, String status, VoidCallback? onTap, {bool loading = false}) {
    final accent = widget.mine ? AppColors.textDark : AppColors.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (loading)
                    CircularProgressIndicator(strokeWidth: 2, color: accent)
                  else
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: used ? Colors.transparent : accent.withValues(alpha: widget.mine ? 0.15 : 0.18),
                        border: Border.all(color: accent.withValues(alpha: used ? 0.4 : 0.9), width: 2),
                      ),
                    ),
                  Text(
                    '${widget.message.viewLimit ?? 1}',
                    style: AppTheme.display(16, weight: FontWeight.w800, color: accent.withValues(alpha: used ? 0.45 : 1)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(kind, style: AppTheme.body(15, weight: FontWeight.w700, color: fg.withValues(alpha: used ? 0.6 : 1))),
                Text(status, style: AppTheme.body(12, color: fg.withValues(alpha: 0.65))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen view of a view-once photo or video. Screenshots and screen recording are blocked.
class ViewOnceViewer extends StatefulWidget {
  final File file;
  final bool isVideo;
  final bool lastView;
  const ViewOnceViewer({super.key, required this.file, required this.isVideo, required this.lastView});

  @override
  State<ViewOnceViewer> createState() => _ViewOnceViewerState();
}

class _ViewOnceViewerState extends State<ViewOnceViewer> {
  static const _window = MethodChannel('comms/lock_screen');
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    _window.invokeMethod('setSecure', true).catchError((_) {});
    if (widget.isVideo) {
      _video = VideoPlayerController.file(widget.file)
        ..initialize().then((_) {
          if (!mounted) return;
          setState(() {});
          _video!.play();
        });
      _video!.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _window.invokeMethod('setSecure', false).catchError((_) {});
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: widget.isVideo
                  ? (v != null && v.value.isInitialized
                      ? GestureDetector(
                          onTap: () => v.value.isPlaying ? v.pause() : v.play(),
                          child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
                        )
                      : const CircularProgressIndicator())
                  : InteractiveViewer(child: Image.file(widget.file, fit: BoxFit.contain)),
            ),
            Positioned(
              top: 4,
              left: 4,
              right: 16,
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white), onPressed: () => Navigator.pop(context)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                    child: Text(
                      widget.lastView ? 'Last view' : 'You can open this once more',
                      style: AppTheme.body(12.5, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            if (v != null && v.value.isInitialized)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: VideoProgressIndicator(v, allowScrubbing: true, colors: const VideoProgressColors(playedColor: AppColors.primary)),
              ),
          ],
        ),
      ),
    );
  }
}
