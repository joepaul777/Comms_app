import 'dart:io';
import 'dart:math';
import 'package:comms/services/e2e_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Each "phone" is the same E2E object loaded with a different key, the way a real
/// phone only ever has its own.
Future<String> asPhone(String uid, int seed) async {
  await E2E.instance.useSeedForTest(uid, List<int>.generate(32, (i) => (i * 7 + seed) & 255));
  return E2E.instance.publicKey!;
}

void main() {
  late String alice, bob, eve;

  setUpAll(() async {
    eve = await asPhone('eve', 3);
    bob = await asPhone('bob', 2);
    alice = await asPhone('alice', 1);
  });

  test('the person it was sent to can read it, and so can the sender', () async {
    await asPhone('alice', 1);
    final enc = await E2E.instance.seal({'t': 'meet at 6'}, {'alice': alice, 'bob': bob}, aad: E2E.messageAad('r1', 'm1'));
    expect(enc.toString(), isNot(contains('meet at 6')));

    await asPhone('bob', 2);
    final opened = await E2E.instance.open(enc, aad: E2E.messageAad('r1', 'm1'));
    expect(opened?.payload['t'], 'meet at 6');

    await asPhone('alice', 1);
    expect((await E2E.instance.open(enc, aad: E2E.messageAad('r1', 'm1')))?.payload['t'], 'meet at 6');
  });

  test('someone it was not sent to cannot read it', () async {
    await asPhone('alice', 1);
    final enc = await E2E.instance.seal({'t': 'secret'}, {'alice': alice, 'bob': bob}, aad: 'msg:r1:m2');
    await asPhone('eve', 3);
    expect(await E2E.instance.open(enc, aad: 'msg:r1:m2'), isNull);
    // Even pretending to be Bob (copying his slot) does not help without his key.
    final stolen = {...enc, 'k': {'eve': (enc['k'] as Map)['bob']}};
    expect(await E2E.instance.open(stolen, aad: 'msg:r1:m2'), isNull);
  });

  test('a message copied into another chat or message does not open', () async {
    await asPhone('alice', 1);
    final enc = await E2E.instance.seal({'t': 'hi'}, {'alice': alice, 'bob': bob}, aad: 'msg:r1:m3');
    await asPhone('bob', 2);
    expect(await E2E.instance.open(enc, aad: 'msg:r2:m3'), isNull);
    expect(await E2E.instance.open(enc, aad: 'msg:r1:other'), isNull);
  });

  test('a changed message is rejected', () async {
    await asPhone('alice', 1);
    final enc = await E2E.instance.seal({'t': 'pay 10'}, {'alice': alice, 'bob': bob}, aad: 'msg:r1:m4');
    final c = enc['c'] as String;
    final tampered = {...enc, 'c': '${c.substring(0, 4)}${c[4] == 'A' ? 'B' : 'A'}${c.substring(5)}'};
    await asPhone('bob', 2);
    expect(await E2E.instance.open(tampered, aad: 'msg:r1:m4'), isNull);
  });

  test('the same words never look the same twice', () async {
    await asPhone('alice', 1);
    final a = await E2E.instance.seal({'t': 'ok'}, {'bob': bob}, aad: 'x');
    final b = await E2E.instance.seal({'t': 'ok'}, {'bob': bob}, aad: 'x');
    expect(a['c'], isNot(b['c']));
  });

  test('files round-trip in pieces, and a cut-short or changed file is refused', () async {
    final dir = await Directory.systemTemp.createTemp('e2e');
    try {
      final random = Random(1);
      // A bit over two pieces, so the last-piece marker matters.
      final bytes = List<int>.generate(512 * 1024 * 2 + 1234, (_) => random.nextInt(256));
      final original = await File('${dir.path}/photo.jpg').writeAsBytes(bytes);
      final key = E2E.newContentKey();
      final locked = await E2E.encryptFile(original, File('${dir.path}/locked'), key);
      final lockedBytes = await locked.readAsBytes();
      expect(lockedBytes.length, bytes.length + 3 * 16);

      final back = await E2E.decryptFile(locked, File('${dir.path}/back.jpg'), key);
      expect(await back.readAsBytes(), bytes);

      // Wrong key
      await expectLater(E2E.decryptFile(locked, File('${dir.path}/x1'), E2E.newContentKey()), throwsA(anything));
      // Last piece removed: the end marker is missing
      final cut = await File('${dir.path}/cut').writeAsBytes(lockedBytes.sublist(0, (512 * 1024 + 16) * 2));
      await expectLater(E2E.decryptFile(cut, File('${dir.path}/x2'), key), throwsA(anything));
      expect(await File('${dir.path}/x2').exists(), isFalse, reason: 'a half-unlocked file is not left behind');
      // One byte changed
      final changed = [...lockedBytes]..[100] ^= 1;
      final bad = await File('${dir.path}/bad').writeAsBytes(changed);
      await expectLater(E2E.decryptFile(bad, File('${dir.path}/x3'), key), throwsA(anything));

      // An empty file still works
      final empty = await File('${dir.path}/empty').writeAsBytes([]);
      final emptyLocked = await E2E.encryptFile(empty, File('${dir.path}/empty.locked'), key);
      expect(await (await E2E.decryptFile(emptyLocked, File('${dir.path}/empty.back'), key)).readAsBytes(), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('both people see the same security code, and it changes with a new key', () async {
    final ab = await E2E.securityCode(alice, bob);
    expect(await E2E.securityCode(bob, alice), ab);
    expect(ab.split(' ').length, 12);
    expect(ab.replaceAll(' ', ''), matches(RegExp(r'^\d{60}$')));
    expect(await E2E.securityCode(alice, eve), isNot(ab));
  });
}
