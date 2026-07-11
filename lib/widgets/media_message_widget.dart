import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';
import '../../models/message_model.dart';
import '../../services/media_service.dart';
import '../../theme/app_colors.dart';

class MediaMessageWidget extends StatefulWidget {
  final MessageModel message;
  final bool isMine;

  const MediaMessageWidget({super.key, required this.message, required this.isMine});

  @override
  State<MediaMessageWidget> createState() => _MediaMessageWidgetState();
}

class _MediaMessageWidgetState extends State<MediaMessageWidget> {
  final MediaService _mediaService = MediaService();
  bool _isDownloading = false;
  String? _localPath;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _localPath = widget.message.localFilePath;
    _checkLocalFile();
  }

  Future<void> _checkLocalFile() async {
    if (_localPath != null) {
      final file = File(_localPath!);
      if (await file.exists()) {
        _initializeVideoIfNeeded();
        return;
      }
    }
    setState(() => _localPath = null);
  }

  void _initializeVideoIfNeeded() {
    if (widget.message.type == MessageType.video && _localPath != null) {
      _videoController = VideoPlayerController.file(File(_localPath!))
        ..initialize().then((_) {
          if (mounted) setState(() {});
        });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _downloadMedia() async {
    if (widget.message.mediaUrl == null) return;
    setState(() => _isDownloading = true);
    
    final fileName = widget.message.mediaUrl!.split('%2F').last.split('?').first;
    final path = await _mediaService.downloadMedia(
      url: widget.message.mediaUrl!,
      fileName: fileName,
    );
    
    if (path != null) {
      // Once downloaded by receiver, delete from cloud to save space
      if (!widget.isMine) {
         _mediaService.deleteMediaFromCloud(widget.message.id, fileName);
      }
      setState(() {
        _localPath = path;
        _isDownloading = false;
      });
      _initializeVideoIfNeeded();
    } else {
      setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_localPath == null) {
      // Show Download UI
      return Container(
        width: 200,
        height: 150,
        decoration: BoxDecoration(
          color: AppColors.bgAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: _isDownloading
              ? const CircularProgressIndicator(color: AppColors.primary)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.message.type == MessageType.video
                          ? Icons.videocam_rounded
                          : Icons.image_rounded,
                      color: AppColors.textMuted,
                      size: 32,
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _downloadMedia,
                      icon: const Icon(Icons.download_rounded, size: 16),
                      label: const Text('Download'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.textDark,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
    }

    // File downloaded and available locally
    if (widget.message.type == MessageType.video) {
      return Container(
        width: 220,
        height: 300,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.black,
        ),
        child: _videoController != null && _videoController!.value.isInitialized
            ? ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: _videoController!.value.aspectRatio,
                      child: VideoPlayer(_videoController!),
                    ),
                    IconButton(
                      icon: Icon(
                        _videoController!.value.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_filled_rounded,
                        color: Colors.white,
                        size: 48,
                      ),
                      onPressed: () {
                        setState(() {
                          _videoController!.value.isPlaying
                              ? _videoController!.pause()
                              : _videoController!.play();
                        });
                      },
                    ),
                  ],
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }

    // Image or GIF
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        File(_localPath!),
        width: 220,
        fit: BoxFit.cover,
      ),
    );
  }
}
