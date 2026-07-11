import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../models/message_model.dart';
import '../../services/media_service.dart';
import '../../theme/app_colors.dart';

class AudioMessageWidget extends StatefulWidget {
  final MessageModel message;
  final bool isMine;

  const AudioMessageWidget({super.key, required this.message, required this.isMine});

  @override
  State<AudioMessageWidget> createState() => _AudioMessageWidgetState();
}

class _AudioMessageWidgetState extends State<AudioMessageWidget> {
  final MediaService _mediaService = MediaService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  bool _isDownloading = false;
  String? _localPath;
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _localPath = widget.message.localFilePath;
    _checkLocalFile();

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state == PlayerState.playing);
      }
    });
    _audioPlayer.onDurationChanged.listen((newDuration) {
      if (mounted) setState(() => _duration = newDuration);
    });
    _audioPlayer.onPositionChanged.listen((newPosition) {
      if (mounted) setState(() => _position = newPosition);
    });
  }

  Future<void> _checkLocalFile() async {
    if (_localPath != null) {
      final file = File(_localPath!);
      if (await file.exists()) {
        await _audioPlayer.setSourceDeviceFile(_localPath!);
        return;
      }
    }
    setState(() => _localPath = null);
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
      if (!widget.isMine) {
         _mediaService.deleteMediaFromCloud(widget.message.id, fileName);
      }
      setState(() {
        _localPath = path;
        _isDownloading = false;
      });
      await _audioPlayer.setSourceDeviceFile(_localPath!);
    } else {
      setState(() => _isDownloading = false);
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(d.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(d.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    if (_localPath == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _isDownloading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                )
              : IconButton(
                  icon: const Icon(Icons.download_rounded, color: AppColors.primary),
                  onPressed: _downloadMedia,
                ),
          const SizedBox(width: 8),
          Text(
            'Voice Message',
            style: GoogleFonts.inter(fontSize: 14, color: AppColors.text),
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: widget.isMine ? AppColors.textDark : AppColors.primary,
          ),
          onPressed: () {
            if (_isPlaying) {
              _audioPlayer.pause();
            } else {
              _audioPlayer.resume();
            }
          },
        ),
        Expanded(
          child: Slider(
            value: _position.inSeconds.toDouble(),
            max: _duration.inSeconds.toDouble() > 0 ? _duration.inSeconds.toDouble() : 1.0,
            activeColor: widget.isMine ? AppColors.textDark : AppColors.primary,
            inactiveColor: (widget.isMine ? AppColors.textDark : AppColors.primary).withOpacity(0.3),
            onChanged: (val) {
              _audioPlayer.seek(Duration(seconds: val.toInt()));
            },
          ),
        ),
        Text(
          _formatDuration(_position.inSeconds > 0 ? _position : _duration),
          style: GoogleFonts.inter(
            fontSize: 12,
            color: widget.isMine ? AppColors.textDark : AppColors.textMuted,
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}
