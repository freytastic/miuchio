import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/manage_people_screen.dart';

void main() {
  late List<String> removed;
  late int adds;

  setUp(() {
    removed = [];
    adds = 0;
  });

  ManagedPerson person(String id,
          {bool owner = false, bool self = false, bool invited = false}) =>
      ManagedPerson(
        id: id,
        name: invited ? AlbumCopy.invitedShort : id,
        face: const SizedBox(),
        owner: owner,
        self: self,
        invited: invited,
      );

  Future<void> pump(
      WidgetTester tester, List<ManagedPerson> Function() load) async {
    await tester.pumpWidget(MaterialApp(
      home: ManagePeopleScreen(
        albumTitle: 'Lisbon',
        load: () async => load(),
        onAdd: () async => adds++,
        onRemove: (p) async => removed.add(p.id),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the owner and you cannot be removed; everyone else can',
      (tester) async {
    await pump(
        tester,
        () => [
              person('Alice', owner: true, self: true),
              person('Bob'),
              person('inv', invited: true),
            ]);

    expect(find.byKey(const Key('manage-remove-Alice')), findsNothing);
    expect(find.byKey(const Key('manage-remove-Bob')), findsOneWidget);
    expect(find.text(AlbumCopy.cancelShort), findsOneWidget,
        reason: 'an open invite is cancelled, not removed');
    expect(find.text('Lisbon · 3 of 10 people'), findsOneWidget);
  });

  testWidgets('remove and add hand off, then the list reloads', (tester) async {
    var loads = 0;
    await pump(tester, () {
      loads++;
      return [person('Alice', owner: true, self: true), person('Bob')];
    });

    await tester.tap(find.byKey(const Key('manage-remove-Bob')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-add')));
    await tester.pumpAndSettle();

    expect(removed, ['Bob']);
    expect(adds, 1);
    expect(loads, 3);
  });

  testWidgets('a full album says so and adds nobody', (tester) async {
    await pump(
        tester,
        () => [
              person('Alice', owner: true, self: true),
              for (var i = 0; i < 9; i++) person('p$i'),
            ]);

    await tester.tap(find.byKey(const Key('manage-add')));
    await tester.pumpAndSettle();

    expect(adds, 0);
    expect(find.text(AlbumCopy.addFull), findsOneWidget);
  });
}
