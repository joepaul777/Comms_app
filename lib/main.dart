import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'services/notification_service.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const CommsApp());
  NotificationService.instance.initialize();
}

class CommsApp extends StatelessWidget {
  const CommsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comms',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      navigatorKey: navigatorKey,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          final Widget page;
          if (snapshot.connectionState == ConnectionState.waiting) {
            page = const _Splash();
          } else if (snapshot.hasData) {
            page = HomeScreen(key: ValueKey(snapshot.data!.uid), uid: snapshot.data!.uid);
          } else {
            page = const LoginScreen();
          }
          return AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: page);
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.8, end: 1),
          duration: const Duration(milliseconds: 700),
          curve: Curves.elasticOut,
          builder: (_, v, child) => Transform.scale(scale: v, child: child),
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(26)),
            child: Center(child: Text('CO.', style: AppTheme.display(28, weight: FontWeight.w900, color: AppColors.textDark))),
          ),
        ),
      ),
    );
  }
}
