import 'package:comms/widgets/message_bubble.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only-emoji messages are counted', () {
    expect(emojiOnlyCount('😂'), 1);
    expect(emojiOnlyCount('😂😂😂'), 3);
    expect(emojiOnlyCount(' ❤️ 👍 '), 2);
    expect(emojiOnlyCount('👍🏽'), 1, reason: 'skin tone belongs to the thumb');
    expect(emojiOnlyCount('🇮🇳'), 1, reason: 'a flag is one emoji');
    expect(emojiOnlyCount('👨‍👩‍👧'), 1, reason: 'a family is one emoji');
  });

  test('anything with words or numbers is normal text', () {
    expect(emojiOnlyCount('ok 👍'), 0);
    expect(emojiOnlyCount('123'), 0);
    expect(emojiOnlyCount('#'), 0);
    expect(emojiOnlyCount('hello'), 0);
    expect(emojiOnlyCount(''), 0);
    expect(emojiOnlyCount('?!'), 0);
  });
}
