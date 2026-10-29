import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/widgets/tab_dock.dart';

void main() {
  late AppState state;
  final selected = <HomeTab>[];
  var made = 0;

  Future<void> pump(WidgetTester tester, HomeTab current) =>
      tester.pumpWidget(ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: TabDock(
                current: current,
                onSelect: selected.add,
                onMake: () => made++,
              ),
            ),
          ),
        ),
      ));

  setUp(() {
    state = AppState();
    selected.clear();
    made = 0;
  });

  testWidgets('each tab selects itself and the middle button makes',
      (tester) async {
    await pump(tester, HomeTab.albums);

    for (final label in ['People', 'Notifications', 'You', 'Albums']) {
      await tester.tap(find.text(label));
    }
    await tester.tap(find.byTooltip('Add'));
    await tester.pump();

    expect(selected, [
      HomeTab.people,
      HomeTab.notifications,
      HomeTab.you,
      HomeTab.albums,
    ]);
    expect(made, 1);
  });

  testWidgets('the current tab is announced as selected', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, HomeTab.people);

    expect(
      tester.getSemantics(find.bySemanticsLabel('People')),
      matchesSemantics(
          isButton: true, isSelected: true, hasSelectedState: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Albums')),
      matchesSemantics(isButton: true, hasSelectedState: true),
    );
    semantics.dispose();
  });

  testWidgets('unread notifications show a dot on the bell', (tester) async {
    await pump(tester, HomeTab.albums);
    final dot = find.byKey(const ValueKey('unread-notifications'));
    expect(dot, findsNothing);

    state.setUnreadNotifications(true);
    await tester.pump();
    expect(dot, findsOneWidget);
  });
}
