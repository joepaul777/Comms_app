import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/message_model.dart';
import '../services/media_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'full_screen_image_viewer.dart';

/// Loads this phone's copy of a message's media, downloading it the first time it is seen.
class MediaLoader extends StatefulWidget {
  final MessageModel message;
  final Widget Function(BuildContext context, File? file, double? progress, bool expired) builder;
  const MediaLoader({super.key, required this.message, required this.builder});

  @override
  State<MediaLoader> createState() => _MediaLoaderState();
}

class _MediaLoaderState extends State<MediaLoader> {
  File? _file;
  double? _progress;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MediaLoader old) {
    super.didUpdateWidget(old);
    if (old.message.id != widget.message.id || (old.message.mediaUrl == null && widget.message.mediaUrl != null)) _load();
  }

  Future<void> _load() async {
    final media = MediaService.instance;
    final local = await media.localCopy(widget.message);
    if (local != null) {
      if (mounted) setState(() => _file = local);
      return;
    }
    if (widget.message.mediaUrl == null) return;
    if (DateTime.now().isAfter(widget.message.mediaExpiresAt)) {
      if (mounted) setState(() => _expired = true);
      return;
    }
    if (mounted) setState(() => _progress = 0);
    final file = await media.download(widget.message, onProgress: (p) {
      if (mounted) setState(() => _progress = p);
    });
    if (!mounted) return;
    setState(() {
      _file = file;
      _progress = null;
      _expired = file == null && DateTime.now().isAfter(widget.message.mediaExpiresAt.subtract(const Duration(minutes: 5)));
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _file, _progress, _expired);
}

class _Placeholder extends StatelessWidget {
  final IconData icon;
  final String label;
  final double? progress;
  const _Placeholder({required this.icon, required this.label, this.progress});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bgElevated,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress != null)
              SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(value: progress! > 0 ? progress : null, strokeWidth: 3),
              )
            else
              Icon(icon, color: AppColors.textMuted, size: 32),
            const SizedBox(height: 8),
            Text(label, style: AppTheme.body(12.5, color: AppColors.textMuted), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class ImageMessage extends StatelessWidget {
  final MessageModel message;
  const ImageMessage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MediaLoader(
      message: message,
      builder: (context, file, progress, expired) {
        if (file == null) {
          return AspectRatio(
            aspectRatio: 4 / 3,
            child: _Placeholder(
              icon: expired ? Icons.hide_image_outlined : Icons.image_outlined,
              label: expired ? 'Photo expired' : (progress != null ? 'Saving photo…' : 'Photo'),
              progress: expired ? null : progress,
            ),
          );
        }
        return GestureDetector(
          onTap: () => Navigator.of(context).push(PageRouteBuilder(
            opaque: false,
            barrierColor: Colors.black,
            pageBuilder: (_, _, _) => FullScreenImageViewer(imageProvider: FileImage(file), heroTag: 'img-${message.id}'),
            transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
          )),
          child: Hero(
            tag: 'img-${message.id}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360, minHeight: 120),
              child: Image.file(file, fit: BoxFit.cover, width: double.infinity, cacheWidth: 900),
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
      builder: (context, file, progress, expired) {
        return AspectRatio(
          aspectRatio: 16 / 11,
          child: file == null
              ? _Placeholder(
                  icon: expired ? Icons.videocam_off_outlined : Icons.videocam_outlined,
                  label: expired ? 'Video expired' : (progress != null ? 'Saving video… ${((progress) * 100).round()}%' : 'Video'),
                  progress: expired ? null : progress,
                )
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
    final controller = VideoPlayerController.file(widget.file);
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
  late final VideoPlayerController _controller = VideoPlayerController.file(widget.file);

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
