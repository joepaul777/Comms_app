import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/ui.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..forward();
  late final AnimationController _float = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
  bool _busy = false;

  @override
  void dispose() {
    _intro.dispose();
    _float.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      await AuthService.instance.signInWithGoogle();
    } on FirebaseAuthException catch (e) {
      if (mounted) showSnack(context, e.message ?? 'Sign-in failed', error: true);
    } catch (e) {
      if (mounted) showSnack(context, 'Sign-in failed. Check your connection and try again.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Animation<double> _step(double start, double end) =>
      CurvedAnimation(parent: _intro, curve: Interval(start, end, curve: Curves.easeOutCubic));

  Widget _reveal(double start, Widget child) {
    final a = _step(start, (start + 0.5).clamp(0, 1));
    return FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Soft drifting glow
          AnimatedBuilder(
            animation: _float,
            builder: (_, _) => Positioned(
              top: -120 + _float.value * 40,
              right: -100 + _float.value * 30,
              child: Container(
                width: 360,
                height: 360,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Color(0x40FACC15), Color(0x00FACC15)]),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _reveal(
                        0,
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(24)),
                          child: Center(child: Text('CO.', style: AppTheme.display(26, weight: FontWeight.w900, color: AppColors.textDark))),
                        ),
                      ),
                      const SizedBox(height: 36),
                      _reveal(0.15, Text('Talk to your\npeople.', style: AppTheme.display(44, weight: FontWeight.w900))),
                      const SizedBox(height: 14),
                      _reveal(
                        0.3,
                        Text('Chats, voice notes, photos, and crystal-clear voice and video calls. All in one place.',
                            style: AppTheme.body(16, color: AppColors.textMuted, height: 1.5)),
                      ),
                      const SizedBox(height: 28),
                      _reveal(
                        0.4,
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: const [
                            _Feature(icon: Icons.chat_bubble_rounded, label: 'Chat'),
                            _Feature(icon: Icons.mic_rounded, label: 'Voice notes'),
                            _Feature(icon: Icons.call_rounded, label: 'Calls'),
                            _Feature(icon: Icons.videocam_rounded, label: 'Video'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 44),
                      _reveal(
                        0.55,
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _busy ? null : _signIn,
                            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(58)),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: _busy
                                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.textDark))
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          width: 26,
                                          height: 26,
                                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                          child: Center(child: Text('G', style: AppTheme.display(15, weight: FontWeight.w900, color: const Color(0xFF4285F4)))),
                                        ),
                                        const SizedBox(width: 12),
                                        const Text('Continue with Google'),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _reveal(0.65, Center(child: Text('Version 3.0', style: AppTheme.body(12.5, color: AppColors.textFaint)))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Feature({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: AppColors.bgAlt, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.border)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(label, style: AppTheme.body(13, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}
