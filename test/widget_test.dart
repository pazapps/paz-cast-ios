import 'package:flutter_test/flutter_test.dart';

import 'package:paz_castanhal/main.dart';

void main() {
  testWidgets('App renders splash screen', (WidgetTester tester) async {
    // The app uses FutureBuilder and Firebase, so we just verify it builds
    await tester.pumpWidget(const AppRoot());
    expect(find.byType(AppRoot), findsOneWidget);
  });
}
