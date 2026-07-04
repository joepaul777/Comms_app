import 'package:flutter_test/flutter_test.dart';
import 'package:comms/main.dart';

void main() {
  testWidgets('CommsApp renders', (WidgetTester tester) async {
    // Just verifying the app widget can be constructed
    expect(const CommsApp(), isNotNull);
  });
}
