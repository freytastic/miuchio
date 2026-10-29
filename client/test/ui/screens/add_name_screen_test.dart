import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/screens/add_name_screen.dart';

void main() {
  late AppState state;
  late int done;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state = AppState();
    done = 0;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(home: AddNameScreen(onDone: () => done++)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('cannot continue without a name', (tester) async {
    await pump(tester);
    expect(find.text('What should people call you?'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(done, 0);
    expect(state.profileName, 'User');
  });

  testWidgets('the name is saved, trimmed, and the step moves on',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '  Dana ');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(state.profileName, 'Dana');
    expect(done, 1);
  });

  // Mid dismissal the keyboard is shorter than the home indicator inset
  testWidgets('a keyboard shorter than the safe area lays out cleanly',
      (tester) async {
    tester.view.padding = const FakeViewPadding(bottom: 76);
    tester.view.viewInsets = const FakeViewPadding(bottom: 26);
    addTearDown(tester.view.reset);
    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Continue'), findsOneWidget);
  });
}
