import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/album_settings_screen.dart';

MediaRecord _shot(String id) => MediaRecord(
      id: id,
      albumId: 'album-1',
      uploaderToken: 'alice',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: 1000,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime(2026, 3, 14),
      thumbWrapNonce: Uint8List(12),
      thumbWrapTagCT: Uint8List(48),
      thumbSize: 100,
      thumbSha256: Uint8List(32),
    );

void main() {
  late List<String> removed;
  late List<String> opened;
  late List<String?> covers;
  late int adds;
  late int renames;
  late int infos;
  late int deletes;

  setUp(() {
    removed = [];
    opened = [];
    covers = [];
    adds = 0;
    renames = 0;
    infos = 0;
    deletes = 0;
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
    WidgetTester tester,
    List<ManagedPerson> Function() load, {
    List<MediaRecord> photos = const [],
    String? cover,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: AlbumSettingsScreen(
        name: () => 'Lisbon',
        photos: photos,
        coverId: cover,
        thumb: (r) => ColoredBox(key: Key('thumb-${r.id}'), color: Colors.grey),
        onChangeCover: (was) async {
          covers.add(was);
          return 'm2';
        },
        onRename: () async => renames++,
        load: () async => load(),
        onAdd: () async => adds++,
        onRemove: (p) async => removed.add(p.id),
        onOpen: (p) async => opened.add(p.id),
        onInfo: () => infos++,
        onDelete: () => deletes++,
      ),
    ));
    await tester.pumpAndSettle();
  }

  List<ManagedPerson> trio() => [
        person('Alice', owner: true, self: true),
        person('Bob'),
        person('inv', invited: true),
      ];

  testWidgets('the owner and you cannot be removed; everyone else can',
      (tester) async {
    await pump(tester, trio);

    expect(find.byKey(const Key('manage-remove-Alice')), findsNothing);
    expect(find.byKey(const Key('manage-remove-Bob')), findsOneWidget);
    expect(find.text(AlbumCopy.cancelShort), findsOneWidget,
        reason: 'an open invite is cancelled, not removed');
    expect(find.text('3 of 10 people'), findsOneWidget);
  });

  testWidgets('remove, add and open hand off, then the list reloads',
      (tester) async {
    var loads = 0;
    await pump(tester, () {
      loads++;
      return trio();
    });

    await tester.tap(find.byKey(const Key('manage-remove-Bob')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-open-Bob')));
    await tester.pumpAndSettle();

    expect(removed, ['Bob']);
    expect(adds, 1);
    expect(opened, ['Bob']);
    expect(loads, 4);
    expect(find.byKey(const Key('manage-open-Alice')), findsNothing);
    expect(find.byKey(const Key('manage-open-inv')), findsNothing);
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

  testWidgets('the newest photo is the cover until one is chosen',
      (tester) async {
    await pump(tester, trio, photos: [_shot('m1'), _shot('m2')]);

    expect(find.byKey(const Key('thumb-m1')), findsOneWidget);
    expect(find.text(AlbumCopy.coverNewest), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-cover')));
    await tester.pumpAndSettle();

    expect(covers, [null]);
    expect(find.byKey(const Key('thumb-m2')), findsOneWidget);
    expect(find.text(AlbumCopy.coverChosen), findsOneWidget);
  });

  testWidgets('an album without photos has no cover to change', (tester) async {
    await pump(tester, trio);

    expect(find.byKey(const Key('settings-cover')), findsNothing);
  });

  testWidgets('rename, info and delete are each one row', (tester) async {
    await pump(tester, trio);

    await tester.tap(find.byKey(const Key('settings-rename')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-info')));
    await tester.tap(find.byKey(const Key('album-info-delete')));

    expect(renames, 1);
    expect(infos, 1);
    expect(deletes, 1);
    expect(find.text('Lisbon'), findsOneWidget);
  });

  testWidgets('the picker offers the newest photo and every photo',
      (tester) async {
    ({String? id})? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            picked = await CoverPickerScreen.show(context,
                photos: [_shot('m1'), _shot('m2')],
                current: 'm1',
                thumb: (r) =>
                    ColoredBox(key: Key('thumb-${r.id}'), color: Colors.grey));
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cover-newest')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cover-m2')));
    await tester.pumpAndSettle();

    expect(picked?.id, 'm2');
  });
}
