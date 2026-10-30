import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/storage/known_people_store.dart';
import 'package:miuchio/ui/create/create_album_screen.dart';
import 'package:miuchio/ui/create/create_copy.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

import '../../_sodium_setup.dart';

void main() {
  late Directory dir;

  setUpAll(() async => ensureSodium());

  Future<KnownPeopleStore> store(WidgetTester tester,
      {List<String> handles = const []}) async {
    return (await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('miuchio_known');
      addTearDown(() => dir.delete(recursive: true));
      final s = await KnownPeopleStore.open(
          file: File('${dir.path}/known.kec'),
          cacheRootKey: Uint8List.fromList(List.filled(32, 3)));
      for (var i = 0; i < handles.length; i++) {
        await s.remember(
          handle: handles[i],
          ikPub: Uint8List.fromList(List.filled(32, i + 1)),
          albumId: 'album-$i',
          memberToken: 'token-$i',
          at: DateTime(2026, 1, 1 + i),
        );
      }
      return s;
    }))!;
  }

  Future<void> pump(WidgetTester tester, {KnownPeopleStore? known}) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        if (known != null)
          ChangeNotifierProvider<KnownPeopleStore>.value(value: known),
      ],
      child: const MaterialApp(home: CreateAlbumScreen()),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> nameIt(WidgetTester tester, String name) async {
    await tester.enterText(
        find.widgetWithText(TextField, CreateCopy.namePlaceholder), name);
    await tester.pump();
  }

  Future<void> addId(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(const Key('create-add-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('create-id-field')), id);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  WarmButton cta(WidgetTester tester) =>
      tester.widget<WarmButton>(find.byType(WarmButton));

  testWidgets('the album cannot be created without a name', (tester) async {
    await pump(tester);

    expect(cta(tester).onTap, isNull);

    await nameIt(tester, 'Lisbon');

    expect(cta(tester).onTap, isNotNull);
  });

  testWidgets('whitespace alone is not a name', (tester) async {
    await pump(tester);
    await nameIt(tester, '   ');

    expect(cta(tester).onTap, isNull);
  });

  testWidgets('people invited before are offered and ticked with a tap',
      (tester) async {
    await pump(tester,
        known: await store(tester, handles: ['ABCD2345', 'WXYZ6789']));
    await nameIt(tester, 'Lisbon');

    expect(find.byKey(const ValueKey('pick-ABCD2345')), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-WXYZ6789')), findsOneWidget);
    expect(find.text(CreateCopy.createOnly), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pick-ABCD2345')));
    await tester.pump();
    expect(find.text(CreateCopy.createAndInvite(1)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pick-ABCD2345')));
    await tester.pump();
    expect(find.text(CreateCopy.createOnly), findsOneWidget);
  });

  testWidgets('someone new is added by ID and chosen at once', (tester) async {
    await pump(tester);
    await nameIt(tester, 'Lisbon');

    await addId(tester, 'ABCD2345');

    expect(find.byKey(const ValueKey('pick-ABCD2345')), findsOneWidget);
    expect(find.text(CreateCopy.newPerson), findsOneWidget);
    expect(find.text(CreateCopy.createAndInvite(1)), findsOneWidget);
  });

  testWidgets('typing the ID of someone already listed ticks them instead',
      (tester) async {
    await pump(tester, known: await store(tester, handles: ['ABCD2345']));

    await addId(tester, 'abcd-2345');

    expect(find.byKey(const ValueKey('pick-ABCD2345')), findsOneWidget);
    expect(find.text(CreateCopy.newPerson), findsNothing);
    expect(find.text(CreateCopy.createAndInvite(1)), findsOneWidget);
  });

  testWidgets('a malformed ID is refused', (tester) async {
    await pump(tester);

    await addId(tester, 'AB');

    expect(find.text(CreateCopy.idInvalid), findsOneWidget);
    expect(find.text(CreateCopy.newPerson), findsNothing);
  });

  testWidgets('nine invites fill the album', (tester) async {
    final handles = [for (var i = 0; i < 10; i++) 'ABCD234$i'];
    await pump(tester, known: await store(tester, handles: handles));

    for (final h in handles) {
      final row = find.byKey(ValueKey('pick-$h'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pump();
    }

    expect(find.text(CreateCopy.createAndInvite(9)), findsOneWidget);
    expect(find.text(CreateCopy.albumFull), findsOneWidget);
  });

  testWidgets('an empty ID field folds away when focus moves on',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('create-add-new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create-id-field')), findsOneWidget);

    await tester
        .tap(find.widgetWithText(TextField, CreateCopy.namePlaceholder));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('create-id-field')), findsNothing);
    expect(find.byKey(const Key('create-add-new')), findsOneWidget);
  });

  testWidgets('a half typed ID stays open when focus moves on', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('create-add-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('create-id-field')), 'AB');
    await tester
        .tap(find.widgetWithText(TextField, CreateCopy.namePlaceholder));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('create-id-field')), findsOneWidget);
  });
}
