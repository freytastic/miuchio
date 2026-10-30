import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/ui/navigation/screen_route.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

void main() {
  Future<void> openSecond(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: Warm.theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context)
                  .push(screenRoute(const Scaffold(body: Text('second')))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
  }

  testWidgets('a swipe from the left edge goes back on iOS', (tester) async {
    await openSecond(tester);

    await tester.dragFrom(const Offset(5, 300), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(find.text('second'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the system back goes back on Android', (tester) async {
    await openSecond(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('second'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
