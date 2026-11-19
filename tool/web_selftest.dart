// A self-check of the browser's file storage and media encryption, run in a real
// browser: `flutter build web -t tool/web_selftest.dart -o build/web_selftest`, then
// open it. The page title ends up as "PASS ..." or "FAIL ...".
import 'dart:math';
import 'package:comms/platform/platform.dart';
import 'package:comms/services/e2e_service.dart';
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final results = <String>[];
  Future<void> check(String name, Future<void> Function() body) async {
    try {
      await body();
      results.add('ok $name');
    } catch (e) {
      results.add('FAIL $name: $e');
    }
  }

  void expect(bool ok, String what) {
    if (!ok) throw StateError(what);
  }

  await check('write, read, copy, rename, delete', () async {
    final docs = await documentsDirectory();
    final file = File('${docs.path}/media/a.txt');
    await file.writeAsString('hello');
    expect(await file.exists() && file.existsSync(), 'exists');
    expect(await file.readAsString() == 'hello', 'read back');
    final moved = await (await file.copy('${docs.path}/media/b.txt')).rename('${docs.path}/media/c.txt');
    expect(!await File('${docs.path}/media/b.txt').exists(), 'renamed away');
    expect(await moved.readAsString() == 'hello', 'moved');
    await file.delete();
    await moved.delete();
    expect(!await file.exists(), 'deleted');
  });

  await check('media lock and unlock', () async {
    final random = Random(7);
    final bytes = List<int>.generate(512 * 1024 * 2 + 999, (_) => random.nextInt(256));
    final tmp = await temporaryDirectory();
    final original = await File('${tmp.path}/photo.jpg').writeAsBytes(bytes);
    final key = E2E.newContentKey();
    final locked = await E2E.encryptFile(original, File('${tmp.path}/photo.jpg.locked'), key);
    expect((await locked.readAsBytes()).length == bytes.length + 3 * 16, 'locked size');
    final back = await (await E2E.decryptFile(locked, File('${tmp.path}/back.jpg'), key)).readAsBytes();
    expect(back.length == bytes.length && List.generate(bytes.length, (i) => back[i] == bytes[i]).every((x) => x), 'round trip');
    final changed = [...await locked.readAsBytes()]..[10] ^= 1;
    final bad = await File('${tmp.path}/bad.locked').writeAsBytes(changed);
    var refused = false;
    try {
      await E2E.decryptFile(bad, File('${tmp.path}/bad.jpg'), key);
    } catch (_) {
      refused = true;
    }
    expect(refused && !await File('${tmp.path}/bad.jpg').exists(), 'tampered refused');
  });

  await check('messages and key handover', () async {
    await E2E.instance.useSeedForTest('alice', List<int>.generate(32, (i) => i + 1));
    final alice = E2E.instance.publicKey!;
    final enc = await E2E.instance.seal({'t': 'hi'}, {'alice': alice}, aad: 'msg:r:m');
    final (pair, oneOff) = await E2E.oneOffKeyPair();
    final box = await E2E.instance.lockKeyFor(oneOff, aad: 'link:alice:$oneOff');
    final seed = await E2E.unlockHandedKey(pair, oneOff, alice, box, aad: 'link:alice:$oneOff');
    await E2E.instance.useSeedForTest('alice', seed);
    expect((await E2E.instance.open(enc, aad: 'msg:r:m'))?.payload['t'] == 'hi', 'linked device reads');
  });

  await check('settings survive in browser storage', () async {
    final support = await supportDirectory();
    await File('${support.path}/selftest.json').writeAsString('{"on":true}');
    expect(await File('${support.path}/selftest.json').readAsString() == '{"on":true}', 'kept');
    await File('${support.path}/selftest.json').delete();
  });

  final failed = results.where((r) => r.startsWith('FAIL')).length;
  web.document.title = '${failed == 0 ? 'PASS' : 'FAIL'} ${results.join(' | ')}';
}
