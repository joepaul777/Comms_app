import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import '../models/user_model.dart';
import 'chat_service.dart';
import 'user_service.dart';
import 'local_prefs.dart';
import '../platform/platform.dart';

/// "Send this text to this person", asked for by the JACE assistant.
class AssistantRequest {
  final String name;
  final String text;
  const AssistantRequest(this.name, this.text);
}

/// A person who might be the one JACE meant, best first.
class NameMatch {
  final UserModel user;
  final double score;
  const NameMatch(this.user, this.score);
}

/// Receives requests from JACE and works out who they are for.
class AssistantService {
  AssistantService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'request') _add(call.arguments);
    });
  }
  static final AssistantService instance = AssistantService._();

  static const _channel = MethodChannel('comms/assistant');
  final _requests = StreamController<AssistantRequest>.broadcast();

  Stream<AssistantRequest> get requests => _requests.stream;

  void _add(dynamic raw) {
    if (raw is! Map) return;
    final name = (raw['name'] ?? '').toString().trim();
    if (name.isEmpty) return;
    _requests.add(AssistantRequest(name, (raw['text'] ?? '').toString().trim()));
  }

  /// A request that opened the app before it was ready.
  Future<AssistantRequest?> takePending() async {
    try {
      final raw = await _channel.invokeMethod('takePending');
      if (raw is! Map) return null;
      final name = (raw['name'] ?? '').toString().trim();
      return name.isEmpty ? null : AssistantRequest(name, (raw['text'] ?? '').toString().trim());
    } catch (_) {
      return null;
    }
  }

  /// Everyone this person talks to: their contacts and anyone they have a chat with.
  Future<List<UserModel>> people(UserModel me) async {
    final ids = <String>{...me.contacts};
    try {
      final rooms = await ChatService.instance.chatRooms(me.uid).first.timeout(const Duration(seconds: 8));
      for (final room in rooms) {
        if (!room.isGroup) ids.addAll(room.participants.where((id) => id != me.uid));
      }
    } catch (_) {}
    ids.remove(me.uid);
    return UserService.instance.getUsers(ids.toList());
  }

  /// People ranked by how well their name fits what was heard.
  Future<List<NameMatch>> rank(String heard, List<UserModel> people) async {
    final learned = await _learned();
    final key = normalize(heard);
    final matches = [
      for (final p in people)
        NameMatch(
          p,
          learned[key] == p.uid
              ? 1.0
              : max(nameScore(key, normalize(p.name)), nameScore(key, normalize(Nicknames.instance.of(p.uid) ?? ''))),
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return matches;
  }

  /// True when the best match is clearly the one meant.
  static bool isSure(List<NameMatch> ranked) {
    if (ranked.isEmpty || ranked.first.score < 0.75) return false;
    return ranked.length == 1 || ranked.first.score - ranked[1].score >= 0.15;
  }

  /// Remembers that this spoken name means this person, for next time.
  Future<void> learn(String heard, String uid) async {
    final map = await _learned();
    map[normalize(heard)] = uid;
    try {
      await (await _file()).writeAsString(jsonEncode(map));
    } catch (_) {}
  }

  Future<File> _file() async => File('${(await supportDirectory()).path}/assistant_names.json');

  Future<Map<String, String>> _learned() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      return Map<String, String>.from(jsonDecode(await f.readAsString()) as Map);
    } catch (_) {
      return {};
    }
  }

  // ---- Name matching -------------------------------------------------------

  static String normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 0..1: how likely [name] is the person called [heard].
  static double nameScore(String heard, String name) {
    if (heard.isEmpty || name.isEmpty) return 0;
    if (heard == name) return 1;
    final h = heard.split(' ');
    final n = name.split(' ');
    if (h.length == 1 && n.contains(h.first)) return 0.95; // first or last name
    if (name.startsWith(heard)) return 0.92;

    // Each spoken word matching the start of a word in the name.
    final prefixHits = h.where((w) => n.any((t) => t.startsWith(w) || w.startsWith(t) && t.length >= 3)).length;
    final prefix = prefixHits / h.length * 0.85;

    // Spelling closeness, word by word, so "rahool" still finds "Rahul".
    var close = 0.0;
    for (final w in h) {
      var best = 0.0;
      for (final t in n) {
        best = max(best, max(_similar(w, t), _similar(_sound(w), _sound(t)) * 0.9));
      }
      close += best;
    }
    close = close / h.length * 0.8;
    return max(prefix, close);
  }

  static double _similar(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    return 1 - _distance(a, b) / max(a.length, b.length);
  }

  /// A rough "sounds like" spelling: similar sounds become the same letter.
  static String _sound(String w) {
    var s = w
        .replaceAll('ph', 'f')
        .replaceAll('ck', 'k')
        .replaceAll('sh', 's')
        .replaceAll('ch', 'j')
        .replaceAll('th', 't')
        .replaceAll(RegExp(r'[ck]'), 'k')
        .replaceAll(RegExp(r'[zs]'), 's')
        .replaceAll(RegExp(r'[dt]'), 't')
        .replaceAll(RegExp(r'[bp]'), 'p')
        .replaceAll(RegExp(r'[vw]'), 'v')
        .replaceAll(RegExp(r'[gj]'), 'j')
        .replaceAll(RegExp(r'[aeiouyh]+'), 'a');
    s = s.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
    return s;
  }

  static int _distance(String s, String t) {
    final v0 = List<int>.generate(t.length + 1, (i) => i);
    final v1 = List<int>.filled(t.length + 1, 0);
    for (var i = 0; i < s.length; i++) {
      v1[0] = i + 1;
      for (var j = 0; j < t.length; j++) {
        final cost = s.codeUnitAt(i) == t.codeUnitAt(j) ? 0 : 1;
        v1[j + 1] = min(min(v1[j] + 1, v0[j + 1] + 1), v0[j] + cost);
      }
      for (var j = 0; j <= t.length; j++) {
        v0[j] = v1[j];
      }
    }
    return v1[t.length];
  }
}
