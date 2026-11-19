import 'dart:async';
import 'package:comms/services/shared_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every screen shares one listener and late ones get the latest value at once', () async {
    var opened = 0;
    final source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() {
      opened++;
      return source.stream;
    });

    final a = <int>[];
    final subA = shared.stream.listen(a.add);
    await Future<void>.delayed(Duration.zero);
    source.add(1);
    await Future<void>.delayed(Duration.zero);

    final b = <int>[];
    final subB = shared.stream.listen(b.add);
    await Future<void>.delayed(Duration.zero);
    source.add(2);
    await Future<void>.delayed(Duration.zero);

    expect(opened, 1, reason: 'one database listener, not one per screen');
    expect(a, [1, 2]);
    expect(b, [1, 2], reason: 'the second screen sees the current value straight away');
    await subA.cancel();
    await subB.cancel();
  });

  test('the listener closes after nobody has used it for a while', () async {
    var closed = false;
    final source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() => source.stream, onClosed: () => closed = true, grace: const Duration(milliseconds: 50));
    final sub = shared.stream.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(closed, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(closed, isTrue);
  });

  test('coming back within the grace period keeps the same listener', () async {
    var opened = 0;
    final source = StreamController<int>.broadcast();
    final shared = SharedStream<int>(() {
      opened++;
      return source.stream;
    }, grace: const Duration(milliseconds: 100));
    final first = shared.stream.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await first.cancel();
    final second = shared.stream.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(opened, 1);
    await second.cancel();
  });
}
