/// App-wide settings for Comms 2.0.
class AppConfig {
  AppConfig._();

  /// The Cloudflare Worker that sends notifications and hands out call relays.
  /// Filled in after `wrangler deploy` prints the address.
  static const String pushServer = 'https://comms-push.prathikjoepaul.workers.dev';

  /// Media links from tmpfiles.org stop working after this long.
  static const Duration mediaLifetime = Duration(minutes: 60);

  /// tmpfiles.org accepts files up to 100 MB.
  static const int maxUploadBytes = 95 * 1024 * 1024;

  /// How long an unanswered call keeps ringing.
  static const Duration ringTimeout = Duration(seconds: 40);

  /// How long after sending a text message it can still be edited (the database rule allows 16 min).
  static const Duration editWindow = Duration(minutes: 15);

  /// Local sending limits (the database enforces the same ones).
  static const Duration minMessageGap = Duration(milliseconds: 800);
  static const int messagesPerMinute = 30;
  static const Duration minCallGap = Duration(seconds: 10);
  static const int callsPerFiveMinutes = 6;

  static const int maxVoiceSeconds = 300;
}
