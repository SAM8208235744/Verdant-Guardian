import 'package:flutter_test/flutter_test.dart';

import 'package:verdant/main.dart';

void main() {
  testWidgets('WaterApp renders', (tester) async {
    await tester.pumpWidget(const WaterApp());

    expect(find.text('No Device Selected'), findsOneWidget);
  });
}
