import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:comms/models/call_model.dart';
import 'package:comms/models/message_model.dart';
import 'package:comms/services/assistant_service.dart';
import 'package:comms/services/media_service.dart';
import 'package:comms/services/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Message spam limits', () {
    late DateTime now;
    late SendGate gate;
    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      gate = SendGate(
        minGap: const Duration(milliseconds: 800),
        maxPerWindow: 30,
        window: const Duration(minutes: 1),
        noun: 'messages',
        clock: () => now,
      );
    });

    void sendAt(Duration after) {
      now = now.add(after);
      gate.check();
      gate.record();
    }

    test('normal chatting is fine', () {
      for (var i = 0; i < 10; i++) {
        sendAt(const Duration(seconds: 2));
      }
    });

    test('two messages in quick succession are stopped', () {
      sendAt(Duration.zero);
      now = now.add(const Duration(milliseconds: 300));
      expect(() => gate.check(), throwsA(isA<RateLimitException>()));
    });

    test('a 31st message within a minute is stopped and says how long to wait', () {
      for (var i = 0; i < 30; i++) {
        sendAt(const Duration(milliseconds: 900));
      }
      now = now.add(const Duration(milliseconds: 900));
      try {
        gate.check();
        fail('should have been stopped');
      } on RateLimitException catch (e) {
        expect(e.message, contains('Try again in'));
        expect(e.wait.inSeconds, greaterThan(20));
      }
    });

    test('the limit lifts once the minute has passed', () {
      for (var i = 0; i < 30; i++) {
        sendAt(const Duration(milliseconds: 900));
      }
      now = now.add(const Duration(seconds: 60));
      gate.check();
    });
  });

  group('Call spam limits', () {
    test('calling again within 10 seconds is stopped', () {
      var now = DateTime(2026);
      final gate = SendGate(minGap: const Duration(seconds: 10), maxPerWindow: 6, window: const Duration(minutes: 5), noun: 'calls', clock: () => now);
      gate.check();
      gate.record();
      now = now.add(const Duration(seconds: 4));
      expect(() => gate.check(), throwsA(isA<RateLimitException>()));
      now = now.add(const Duration(seconds: 7));
      gate.check();
    });
  });

  group('Database window guess', () {
    final start = Timestamp.fromDate(DateTime(2026, 1, 1, 12));
    test('no window yet starts one', () => expect(SendGate.startsNewWindow(null, const Duration(minutes: 1), DateTime(2026)), isTrue));
    test('inside the window continues it', () {
      expect(SendGate.startsNewWindow(start, const Duration(minutes: 1), DateTime(2026, 1, 1, 12, 0, 40)), isFalse);
    });
    test('after the window starts a new one', () {
      expect(SendGate.startsNewWindow(start, const Duration(minutes: 1), DateTime(2026, 1, 1, 12, 1, 5)), isTrue);
    });
    test('fields written for a new window', () {
      final f = SendGate.fields(lastField: 'lastMessageAt', startField: 'msgWindowStart', countField: 'msgWindowCount', newWindow: true);
      expect(f.keys, containsAll(['lastMessageAt', 'msgWindowStart', 'msgWindowCount']));
      expect(f['msgWindowCount'], 1);
    });
    test('fields written inside a window leave the start alone', () {
      final f = SendGate.fields(lastField: 'lastMessageAt', startField: 'msgWindowStart', countField: 'msgWindowCount', newWindow: false);
      expect(f.containsKey('msgWindowStart'), isFalse);
    });
  });

  group('tmpfiles links', () {
    const signed = 'https://tmpfiles.org/dl/1794595772.2f95534620e118f7/wwAf7lVXXAi8/voice.m4a';
    test('signed file links are recognised', () {
      expect(MediaService.isSignedLink(signed), isTrue);
      expect(MediaService.isSignedLink('https://tmpfiles.org/dl/12345/photo.jpg'), isFalse);
      expect(MediaService.isSignedLink('https://tmpfiles.org/wwAf7lVXXAi8/voice.m4a'), isFalse);
      expect(MediaService.isSignedLink('https://evil.com/dl/1.ab/x/y'), isFalse);
    });
    test('old links lead back to the file page', () {
      expect(MediaService.pageLinkFor('http://tmpfiles.org/dl/12345/photo.jpg'), 'https://tmpfiles.org/12345/photo.jpg');
      expect(MediaService.pageLinkFor('https://tmpfiles.org/wwAf7lVXXAi8/voice.m4a'), 'https://tmpfiles.org/wwAf7lVXXAi8/voice.m4a');
    });
    test('the download link is found on the file page', () {
      const html = '<p><a class="download" href="$signed">Download (2.93 KB)</a></p>';
      expect(MediaService.signedLinkIn(html), signed);
      expect(MediaService.signedLinkIn('<a href="https://tmpfiles.org/dl/1/x.jpg">'), isNull);
    });
    test('file types are worked out safely', () {
      expect(MediaService.extensionOf('abc.JPG', MessageType.image), 'jpg');
      expect(MediaService.extensionOf('', MessageType.video), 'mp4');
      expect(MediaService.extensionOf('voice', MessageType.audio), 'm4a');
      expect(MediaService.extensionOf('../../evil.sh;rm', MessageType.image), 'jpg');
    });
  });

  group('Messages', () {
    test('media links expire an hour after sending', () {
      final m = MessageModel(id: '1', senderId: 'a', senderName: 'A', text: '', timestamp: DateTime(2026, 1, 1, 10), type: MessageType.image);
      expect(m.mediaExpiresAt, DateTime(2026, 1, 1, 11));
    });
    test('round trip keeps voice length and file name', () {
      final m = MessageModel(
        id: '1',
        senderId: 'a',
        senderName: 'A',
        text: '',
        timestamp: DateTime(2026),
        type: MessageType.audio,
        mediaUrl: 'u',
        mediaName: 'v.m4a',
        durationMs: 4200,
      );
      final back = MessageModel.fromMap(m.toMap());
      expect(back.type, MessageType.audio);
      expect(back.durationMs, 4200);
      expect(back.mediaName, 'v.m4a');
    });
  });

  group('Calls stay readable by version 1', () {
    test('statuses are the same five words as before', () {
      expect(CallStatus.values.map((s) => s.name), ['ringing', 'connected', 'ended', 'missed', 'rejected']);
    });
    test('the reason a call ended survives a round trip', () {
      final c = CallModel(id: 'c', callerId: 'a', callerName: 'A', receiverId: 'b', receiverName: 'B', type: CallType.video);
      final ended = CallModel.fromMap({...c.toMap(), 'status': 'rejected', 'endReason': EndReason.declined, 'endedBy': 'b'});
      expect(ended.isOver, isTrue);
      expect(ended.endReason, 'declined');
      expect(ended.otherName('a'), 'B');
      expect(ended.otherName('b'), 'A');
    });
  });

  group('Messages from JACE', () {
    double score(String heard, String name) => AssistantService.nameScore(AssistantService.normalize(heard), AssistantService.normalize(name));
    test('first names and full names match', () {
      expect(score('suji', 'Suji S'), greaterThanOrEqualTo(0.9));
      expect(score('prathik', 'Prathik Joe Paul'), greaterThanOrEqualTo(0.9));
      expect(score('suji', 'Prathik Joe Paul'), lessThan(0.5));
    });
    test('near spellings still score', () {
      expect(score('sujee', 'Suji S'), greaterThan(0.6));
    });
  });
}
