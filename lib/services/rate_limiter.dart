import 'package:cloud_firestore/cloud_firestore.dart';

/// Thrown when someone is sending faster than allowed.
class RateLimitException implements Exception {
  final Duration wait;
  final String message;
  RateLimitException(this.wait, this.message);

  @override
  String toString() => message;
}

/// Local copy of the database's sending limits, so people get a friendly message
/// instead of a refused write. The database still has the final say.
class SendGate {
  final Duration minGap;
  final int maxPerWindow;
  final Duration window;
  final String noun;
  final DateTime Function() _clock;
  final List<DateTime> _recent = [];

  SendGate({
    required this.minGap,
    required this.maxPerWindow,
    required this.window,
    required this.noun,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Throws [RateLimitException] if sending now would be too fast.
  void check() {
    final now = _clock();
    _recent.removeWhere((t) => now.difference(t) >= window);
    if (_recent.isNotEmpty) {
      final sinceLast = now.difference(_recent.last);
      if (sinceLast < minGap) {
        throw RateLimitException(minGap - sinceLast, 'Slow down a little');
      }
    }
    if (_recent.length >= maxPerWindow) {
      final wait = window - now.difference(_recent.first);
      final seconds = (wait.inMilliseconds / 1000).ceil();
      throw RateLimitException(wait, 'Too many $noun. Try again in ${seconds}s');
    }
  }

  void record() => _recent.add(_clock());

  /// Whether the database will treat this send as the start of a new window.
  /// Near the boundary the guess can be wrong; callers retry once with the other answer.
  static bool startsNewWindow(Timestamp? windowStart, Duration window, DateTime now) {
    if (windowStart == null) return true;
    return now.isAfter(windowStart.toDate().add(window).add(const Duration(milliseconds: 500)));
  }

  /// The fields to write on the sender's user document alongside the send.
  static Map<String, dynamic> fields({
    required String lastField,
    required String startField,
    required String countField,
    required bool newWindow,
  }) {
    return {
      lastField: FieldValue.serverTimestamp(),
      if (newWindow) startField: FieldValue.serverTimestamp(),
      countField: newWindow ? 1 : FieldValue.increment(1),
    };
  }
}
