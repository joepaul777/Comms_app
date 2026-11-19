import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/message_model.dart';
import '../services/media_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'full_screen_image_viewer.dart';
import '../platform/platform.dart';

/// Where a message's media is up to on this phone.
class MediaState {
  final File? file;
  final double? progress; // set while downloading
  final bool expired; // the link is gone and this phone never got a copy
  final bool failed; // the download did not work but may on a retry
  final VoidCallback retry;
  const MediaState({this.file, this.progress, this.expired = false, this.failed = false, required this.retry});
}

/// Loads this phone's copy of a message's media, downloading it the first time it is seen.
class MediaLoader extends StatefulWidget {
  final MessageModel message;
  final Widget Function(BuildContext context, MediaState state) builder;
  const MediaLoader({super.key, required this.message, required this.builder});

  @override
  State<MediaLoader> createState() => _MediaLoaderState();
}

class _MediaLoaderState extends State<MediaLoader> {
  File? _file;
  double? _progress;
  bool _expired = false;
  bool _failed = false;
  bool _retried = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MediaLoader old) {
    super.didUpdateWidget(old);
    if (old.message.id != widget.message.id || old.message.mediaUrl != widget.message.mediaUrl) _load();
  }

  Future<void> _load() async {
    final media = MediaService.instance;
    final local = await media.localCopy(widget.message);
    if (local != null) {
      if (mounted) setState(() => _file = local);
      return;
    }
    if (widget.message.mediaUrl == null || widget.message.mediaUrl!.isEmpty) return;
    if (DateTime.now().isAfter(widget.message.mediaExpiresAt)) {
      if (mounted) setState(() => _expired = true);
      return;
    }
    if (mounted) {
      setState(() {
        _progress = 0;
        _failed = false;
      });
    }
    final file = await media.download(widget.message, onProgress: (p) {
      if (mounted) setState(() => _progress = p);
    });
    if (!mounted) return;
    if (file == null && !_retried) {
      // One quiet retry covers a brief drop in connection.
      _retried = true;
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) await _load();
      return;
    }
    final gone = file == null && DateTime.now().isAfter(widget.message.mediaExpiresAt.subtract(const Duration(minutes: 2)));
    setState(() {
      _file = file;
      _progress = null;
      _expired = gone;
      _failed = file == null && !gone;
    });
  }

  void _retry() {
    _retried = true;
    _load();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
        context,
        MediaState(file: _file, progress: _progress, expired: _expired, failed: _failed, retry: _retry),
      );
}

class _Placeholder extends StatelessWidget {
  final IconData icon;
  final String label;
  final double? progress;
  final VoidCallback? onTap;
  const _Placeholder({required this.icon, required this.label, this.progress, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: AppColors.bgElevated,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Column(
              key: ValueKey('$label${progress != null}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (progress != null)
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(value: progress! > 0 ? progress : null, strokeWidth: 3),
                  )
                else
                  Icon(icon, color: onTap != null ? AppColors.primary : AppColors.textMuted, size: 32),
                const SizedBox(height: 8),
                Text(label, style: AppTheme.body(12.5, color: AppColors.textMuted), textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder for media that is not on this phone yet.
_Placeholder _placeholderFor(MediaState s, {required String noun, required IconData icon, required IconData goneIcon}) {
  if (s.expired) return _Placeholder(icon: goneIcon, label: '$noun expired');
  if (s.failed) {
    return _Placeholder(icon: Icons.refresh_rounded, label: 'Couldn\'t load ${noun.toLowerCase()}\nTap to retry', onTap: s.retry);
  }
  if (s.progress != null) {
    final pct = s.progress! > 0 ? ' ${(s.progress! * 100).round()}%' : '';
    return _Placeholder(icon: icon, label: 'Loading ${noun.toLowerCase()}…$pct', progress: s.progress);
  }
  return _Placeholder(icon: icon, label: noun);
}

class ImageMessage extends StatelessWidget {
  final MessageModel message;
  const ImageMessage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MediaLoader(
      message: message,
      builder: (context, state) {
        final file = state.file;
        if (file == null) {
          return AspectRatio(
            aspectRatio: 4 / 3,
            child: _placeholderFor(state, noun: 'Photo', icon: Icons.image_outlined, goneIcon: Icons.hide_image_outlined),
          );
        }
        return GestureDetector(
          onTap: () => Navigator.of(context).push(PageRouteBuilder(
            opaque: false,
            barrierColor: Colors.black,
            pageBuilder: (_, _, _) => FullScreenImageViewer(imageProvider: localImage(file), heroTag: 'img-${message.id}'),
            transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
          )),
          child: Hero(
            tag: 'img-${message.id}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360, minHeight: 120),
              child: Image(
                image: localImage(file, cacheWidth: 900),
                fit: BoxFit.cover,
                width: double.infinity,
                // Fade the photo in once it has been decoded.
                frameBuilder: (_, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 300), child: child),
              ),
            ),
          ),
        );
      },
    );
  }
}

class VideoMessage extends StatelessWidget {
  final MessageModel message;
  const VideoMessage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MediaLoader(
      message: message,
      builder: (context, state) {
        final file = state.file;
        return AspectRatio(
          aspectRatio: 16 / 11,
          child: file == null
              ? _placeholderFor(state, noun: 'Video', icon: Icons.videocam_outlined, goneIcon: Icons.videocam_off_outlined)
              : GestureDetector(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoViewer(file: file))),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _VideoThumbnail(file: file),
                      Center(
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), shape: BoxShape.circle),
                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 34),
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _VideoThumbnail extends StatefulWidget {
  final File file;
  const _VideoThumbnail({required this.file});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    final controller = localVideo(widget.file);
    controller.initialize().then((_) {
      if (mounted) setState(() => _controller = controller);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return Container(color: AppColors.bgElevated);
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c)),
    );
  }
}

class VideoViewer extends StatefulWidget {
  final File file;
  const VideoViewer({super.key, required this.file});

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  late final VideoPlayerController _controller = localVideo(widget.file);

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _controller.play();
    });
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _controller.value;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, leading: const CloseButton()),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: v.isInitialized
                    ? GestureDetector(
                        onTap: () => v.isPlaying ? _controller.pause() : _controller.play(),
                        child: AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_controller)),
                      )
                    : const CircularProgressIndicator(),
              ),
            ),
            if (v.isInitialized)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                      onPressed: () => v.isPlaying ? _controller.pause() : _controller.play(),
                    ),
                    Expanded(
                      child: VideoProgressIndicator(
                        _controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(playedColor: AppColors.primary, bufferedColor: AppColors.borderLight),
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
