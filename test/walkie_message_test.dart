import 'package:comms/models/message_model.dart';
import 'package:comms/services/e2e_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the walkie-talkie mark travels inside the encrypted contents and comes back out', () async {
    await E2E.instance.useSeedForTest('alice', List<int>.generate(32, (i) => i + 9));
    final alice = E2E.instance.publicKey!;
    final contents = MessageModel.contentsOf(text: '', mediaUrl: 'https://tmpfiles.org/x', mediaName: 'a.m4a', walkie: true);
    expect(contents['w'], 1);
    final enc = await E2E.instance.seal(contents, {'alice': alice}, aad: E2E.messageAad('r', 'm'));
    expect(enc.toString(), isNot(contains('"w"')), reason: 'the server never sees the mark');
    final opened = await E2E.instance.open(enc, aad: E2E.messageAad('r', 'm'));
    final shell = MessageModel(id: 'm', senderId: 'alice', senderName: 'Alice', text: '', timestamp: DateTime.now(), type: MessageType.audio);
    final message = shell.withContents(opened!.payload, opened.contentKey);
    expect(message.walkie, isTrue);
    expect(message.mediaUrl, 'https://tmpfiles.org/x');
  });

  test('ordinary voice notes are not walkie-talkie', () {
    expect(MessageModel.contentsOf(text: '', mediaUrl: 'u').containsKey('w'), isFalse);
    final shell = MessageModel(id: 'm', senderId: 'a', senderName: 'A', text: '', timestamp: DateTime.now(), type: MessageType.audio);
    expect(shell.withContents({'u': 'x'}, null).walkie, isFalse);
  });
}
