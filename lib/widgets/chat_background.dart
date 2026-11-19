import 'dart:io';
import 'package:flutter/material.dart';
import '../services/local_prefs.dart';
import '../theme/app_colors.dart';

/// Turns any photo into something that fits Comms: colours are softened and warmed
/// towards the app's yellow, so a bright beach photo and a dark city photo both end
/// up looking like they belong.
const _themeTone = ColorFilter.matrix(<double>[
  // 40% the photo's own colour, 60% a gold-toned version of its brightness
  0.4 + 0.6 * 0.2126, 0.6 * 0.7152, 0.6 * 0.0722, 0, 0,
  0.6 * 0.2126 * 0.82, 0.4 + 0.6 * 0.7152 * 0.82, 0.6 * 0.0722 * 0.82, 0, 0,
  0.6 * 0.2126 * 0.35, 0.6 * 0.7152 * 0.35, 0.4 + 0.6 * 0.0722 * 0.35, 0, 0,
  0, 0, 0, 1, 0,
]);

/// A wallpaper photo, toned and dimmed so messages stay easy to read.
class ThemedWallpaper extends StatelessWidget {
  final File photo;
  final double dim;
  final bool tint;
  const ThemedWallpaper({super.key, required this.photo, required this.dim, this.tint = true});

  Widget _image(double width) => Image.file(photo, fit: BoxFit.cover, cacheWidth: width.round(), gaplessPlayback: true);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (tint)
          ColorFiltered(colorFilter: _themeTone, child: _image(width))
        else
          _image(width),
        ColoredBox(color: Colors.black.withValues(alpha: dim)),
        // Darker at the top and bottom, where the header and the typing bar sit.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x99000000), Color(0x00000000), Color(0x00000000), Color(0x99000000)],
              stops: [0, 0.18, 0.8, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// The background of a chat: its own wallpaper if one is set, otherwise the usual glow.
class ChatBackground extends StatelessWidget {
  final String roomId;
  final Widget child;
  const ChatBackground({super.key, required this.roomId, required this.child});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Wallpapers.instance,
      builder: (context, _) {
        final wallpaper = Wallpapers.instance.of(roomId);
        if (wallpaper == null) {
          return Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(center: Alignment(0.9, -1.1), radius: 1.4, colors: [Color(0x14FACC15), Color(0x00000000)]),
            ),
            child: child,
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: ThemedWallpaper(photo: File(wallpaper.path), dim: wallpaper.dim, tint: wallpaper.tint)),
            child,
          ],
        );
      },
    );
  }
}

/// What was chosen on the wallpaper preview.
class WallpaperChoice {
  final double dim;
  final bool tint;
  const WallpaperChoice(this.dim, this.tint);
}

/// Shows how a photo will look behind the chat, with a slider for how dark it is
/// and a switch for the yellow Comms tone.
class WallpaperPreviewScreen extends StatefulWidget {
  final File photo;
  final double initialDim;
  final bool initialTint;
  const WallpaperPreviewScreen({super.key, required this.photo, this.initialDim = 0.55, this.initialTint = true});

  @override
  State<WallpaperPreviewScreen> createState() => _WallpaperPreviewScreenState();
}

class _WallpaperPreviewScreenState extends State<WallpaperPreviewScreen> {
  late double _dim = widget.initialDim;
  late bool _tint = widget.initialTint;

  Widget _bubble(String text, bool mine) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? AppColors.primary : AppColors.bubbleOther,
          borderRadius: BorderRadius.circular(18),
          border: mine ? null : Border.all(color: AppColors.border),
        ),
        child: Text(text, style: TextStyle(color: mine ? AppColors.textDark : AppColors.text, fontSize: 15)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ThemedWallpaper(photo: widget.photo, dim: _dim, tint: _tint),
          SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white), onPressed: () => Navigator.pop(context)),
                    const Expanded(child: Text('Wallpaper', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700))),
                  ],
                ),
                const Spacer(),
                _bubble('This is how your chat will look 👀', false),
                _bubble('Looks good!', true),
                const SizedBox(height: 24),
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  decoration: BoxDecoration(color: AppColors.bg.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(22)),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.palette_rounded, color: AppColors.primary, size: 20),
                          const SizedBox(width: 8),
                          const Expanded(child: Text('Yellow filter', style: TextStyle(color: AppColors.text))),
                          Switch(value: _tint, onChanged: (v) => setState(() => _tint = v)),
                        ],
                      ),
                      Row(
                        children: [
                          const Icon(Icons.brightness_6_rounded, color: AppColors.primary, size: 20),
                          const SizedBox(width: 8),
                          const Text('Dim', style: TextStyle(color: AppColors.text)),
                          Expanded(
                            child: Slider(value: _dim, min: 0.2, max: 0.85, onChanged: (v) => setState(() => _dim = v)),
                          ),
                        ],
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(context, WallpaperChoice(_dim, _tint)),
                          child: const Text('Set wallpaper'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
