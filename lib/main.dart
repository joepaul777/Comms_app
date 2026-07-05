import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'theme/app_theme.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'services/notification_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Initialize notification service (FCM, local notifications)
  await NotificationService().initialize();

  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF171717),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const CommsApp());
}

class CommsApp extends StatefulWidget {
  const CommsApp({super.key});

  @override
  State<CommsApp> createState() => _CommsAppState();
}

class _CommsAppState extends State<CommsApp> {
  @override
  void initState() {
    super.initState();
    // Wire up the notification tap handler to navigate to the right screen
    NotificationService().onNotificationTap = (type, id) {
      if (type == 'chat') {
        // Navigate to the home screen — user can tap the chat from the list
        navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (route) => false,
        );
      } else if (type == 'call') {
        // Navigate to home screen — the incoming call listener will pick it up
        navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (route) => false,
        );
      }
    };
  }

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
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const _SplashScreen();
          }

          if (snapshot.hasData) {
            // Save FCM token each time user is confirmed signed-in
            NotificationService().onUserSignedIn();
            return const HomeScreen();
          }

          return const LoginScreen();
        },
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF171717),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: const Color(0xFFFACC15).withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: const Center(
                child: Text(
                  'CO.',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFFACC15),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Color(0xFFFACC15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
