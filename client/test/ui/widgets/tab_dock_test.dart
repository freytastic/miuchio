import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
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
    await pump(tester, HomeTab.home);

    for (final label in ['Albums', 'Notifications', 'You', 'Home']) {
      await tester.tap(find.bySemanticsLabel(label));
    }
    await tester.tap(find.byTooltip('Add'));
    await tester.pump();

    expect(selected, [
      HomeTab.albums,
      HomeTab.notifications,
      HomeTab.you,
      HomeTab.home,
    ]);
    expect(made, 1);
  });

  // Verification lives inside each album now
  testWidgets('there is no People tab', (tester) async {
    await pump(tester, HomeTab.home);

    expect(HomeTab.values.map((t) => t.name),
        ['home', 'albums', 'notifications', 'you']);
    expect(find.bySemanticsLabel('People'), findsNothing);
  });

  testWidgets('the current tab is announced as selected', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, HomeTab.you);

    expect(
      tester.getSemantics(find.bySemanticsLabel('You')),
      matchesSemantics(
          isButton: true, isSelected: true, hasSelectedState: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Albums')),
      matchesSemantics(isButton: true, hasSelectedState: true),
    );
    semantics.dispose();
  });

  testWidgets('unread notifications show a dot on the bell and are read out',
      (tester) async {
    await pump(tester, HomeTab.albums);
    final dot = find.byKey(const ValueKey('unread-notifications'));
    expect(dot, findsNothing);

    state.setUnreadNotifications(true);
    await tester.pump();
    expect(dot, findsOneWidget);
    expect(find.bySemanticsLabel('Notifications, new'), findsOneWidget);
  });

  testWidgets('two tabs either side of the make button, evenly spaced',
      (tester) async {
    await pump(tester, HomeTab.home);

    expect(find.text('Albums'), findsNothing, reason: 'icons only');
    final rects = [
      for (final label in ['Home', 'Albums', 'Notifications', 'You'])
        tester.getRect(find.bySemanticsLabel(label))
    ];
    final make = tester.getRect(find.byTooltip('Add'));
    final width = tester.getSize(find.byType(TabDock)).width;

    // Centered, in line with the tabs rather than floating above them
    expect(make.center.dx, moreOrLessEquals(width / 2, epsilon: 0.5));
    expect(make.center.dy, moreOrLessEquals(rects[0].center.dy, epsilon: 4));
    // The dock uses the shared spot, so albums put theirs in the same place
    expect(find.byType(MakeSpot), findsOneWidget);
    expect(rects[1].right, lessThanOrEqualTo(make.left));
    expect(rects[2].left, greaterThanOrEqualTo(make.right));

    // Mirrored either side, and every tab a comfortable target
    expect(make.center.dx - rects[1].center.dx,
        moreOrLessEquals(rects[2].center.dx - make.center.dx));
    expect(rects[1].center.dx - rects[0].center.dx,
        moreOrLessEquals(rects[3].center.dx - rects[2].center.dx));
    for (final r in rects) {
      expect(r.width, greaterThanOrEqualTo(48));
      expect(r.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('the selected tab carries a dot beneath it', (tester) async {
    await pump(tester, HomeTab.albums);
    await tester.pumpAndSettle();

    double opacityIn(String label) => tester
        .widget<AnimatedOpacity>(find.descendant(
            of: find.bySemanticsLabel(label),
            matching: find.byType(AnimatedOpacity)))
        .opacity;
    expect(opacityIn('Albums'), 1);
    expect(opacityIn('Home'), 0);
  });
}
