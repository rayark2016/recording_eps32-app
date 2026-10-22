import 'package:flutter_test/flutter_test.dart';

import 'package:urination_recorder/main.dart';

void main() {
  testWidgets('launches the version 5 permission gate', (WidgetTester tester) async {
    await tester.pumpWidget(const UrinationRecorderApp());

    expect(find.text('排尿記錄系統'), findsOneWidget);
  });
}
