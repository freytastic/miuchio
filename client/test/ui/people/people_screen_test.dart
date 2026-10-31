import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/ui/people/people_screen.dart';

PersonEntry _p(String id, TrustState trust, {bool invited = false}) =>
    PersonEntry(
      id: id,
      name: id,
      face: const SizedBox(),
      trust: trust,
      invited: invited,
    );

void main() {
  late List<String> opened;
  late int loads;

  Future<void> pump(WidgetTester tester, List<PersonEntry> people) async {
    opened = [];
    loads = 0;
    await tester.pumpWidget(MaterialApp(
      home: PeopleScreen(
        title: 'People',
        subtitle: 'Cabin',
        load: () async {
          loads++;
          return [...people];
        },
        onOpen: (p) async => opened.add(p.id),
      ),
    ));
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, String id) =>
      tester.getTopLeft(find.byKey(ValueKey('person-$id'))).dy;

  testWidgets('a changed number sits first and verified people sink',
      (tester) async {
    await pump(tester, [
      _p('ana', TrustState.verified),
      _p('bea', TrustState.unverified),
      _p('cy', TrustState.changed),
      _p('dan', TrustState.unverified, invited: true),
    ]);

    expect(top(tester, 'cy'), lessThan(top(tester, 'bea')));
    expect(top(tester, 'bea'), lessThan(top(tester, 'ana')));
    expect(top(tester, 'ana'), lessThan(top(tester, 'dan')));
    expect(find.text('Security code changed'), findsOneWidget);
    // The alarm outranks the count, which would otherwise reassure
    expect(find.text("Cabin · cy's security code changed"), findsOneWidget);
    expect(find.textContaining('of 3 verified'), findsNothing);
  });

  testWidgets('every joined person states whether they are verified',
      (tester) async {
    await pump(tester, [
      _p('ana', TrustState.verified),
      _p('bea', TrustState.unverified),
      _p('dan', TrustState.unverified, invited: true),
    ]);

    expect(find.text('Cabin · 1 of 2 verified'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
    expect(find.byKey(const Key('verified-badge')), findsOneWidget,
        reason: 'the badge is only for the verified person');
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('opening someone reloads, an invite has nothing to open',
      (tester) async {
    await pump(tester, [
      _p('bea', TrustState.unverified),
      _p('dan', TrustState.unverified, invited: true),
    ]);

    await tester.tap(find.byKey(const ValueKey('person-dan')));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);

    await tester.tap(find.byKey(const ValueKey('person-bea')));
    await tester.pumpAndSettle();
    expect(opened, ['bea']);
    expect(loads, 2);
  });
}
