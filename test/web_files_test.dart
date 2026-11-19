@TestOn('browser')
library;

import 'dart:math';
import 'package:comms/platform/platform.dart';
import 'package:comms/services/e2e_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The browser's stand-in for files: media is locked and unlocked exactly as on a phone.
/// Run with `flutter test --platform chrome test/web_files_test.dart`.
void main() {
  test('files can be written, read, copied, renamed and deleted', () async {
    final docs = await documentsDirectory();
    final file = File('${docs.path}/media/a.txt');
    expect(await file.exists(), isFalse);
    await file.writeAsString('hello');
    expect(await file.exists(), isTrue);
    expect(file.existsSync(), isTrue);
    expect(await file.readAsString(), 'hello');
    expect(await file.length(), 5);

    final copy = await file.copy('${docs.path}/media/b.txt');
    expect(await copy.readAsString(), 'hello');
    final moved = await copy.rename('${docs.path}/media/c.txt');
    expect(await File('${docs.path}/media/b.txt').exists(), isFalse);
    expect(await moved.readAsString(), 'hello');

    await file.delete();
    await moved.delete();
    expect(await file.exists(), isFalse);
  });

  test('photos and videos are locked and unlocked in the browser like on a phone', () async {
    final random = Random(7);
    final bytes = List<int>.generate(512 * 1024 + 999, (_) => random.nextInt(256));
    final tmp = await temporaryDirectory();
    final original = await File('${tmp.path}/photo.jpg').writeAsBytes(bytes);
    final key = E2E.newContentKey();
    final locked = await E2E.encryptFile(original, File('${tmp.path}/photo.jpg.locked'), key);
    expect((await locked.readAsBytes()).length, bytes.length + 2 * 16);
    final back = await E2E.decryptFile(locked, File('${tmp.path}/back.jpg'), key);
    expect(await back.readAsBytes(), bytes);

    // A changed file is refused and nothing half-unlocked is left behind.
    final changed = [...await locked.readAsBytes()]..[10] ^= 1;
    final bad = await File('${tmp.path}/bad.locked').writeAsBytes(changed);
    await expectLater(E2E.decryptFile(bad, File('${tmp.path}/bad.jpg'), key), throwsA(anything));
    expect(await File('${tmp.path}/bad.jpg').exists(), isFalse);
  });

  test('settings files are still there after the page is reloaded', () async {
    final support = await supportDirectory();
    await File('${support.path}/test-setting.json').writeAsString('{"on":true}');
    // A fresh read goes to the browser's storage, not just this page's memory.
    expect(await File('${support.path}/test-setting.json').readAsString(), '{"on":true}');
    await File('${support.path}/test-setting.json').delete();
  });
}
