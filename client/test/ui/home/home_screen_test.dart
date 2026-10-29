import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/home/home_screen.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';

class _Seen extends ChangeNotifier implements SeenStore {
  final Map<String, int> at;
  final List<(String, int)> marked = [];
  _Seen(this.at);

  @override
  int lastSeen(String albumId) => at[albumId] ?? 0;
  @override
  bool knows(String albumId) => at.containsKey(albumId);
  @override
  Future<void> markSeen(String albumId, int generation) async =>
      marked.add((albumId, generation));
  @override
  Future<void> markOwn(String albumId, int generation) async {}
  @override
  int ownThrough(String albumId, int generation) => 0;
  @override
  Future<void> forget(String albumId) async {}
}

void main() {
  final now = DateTime.now().toUtc();

  MediaRecord shot(String id, String album, String who, int seq) => MediaRecord(
        id: id,
        albumId: album,
        uploaderToken: who,
        wrapNonce: Uint8List(12),
        wrapTagCT: Uint8List(48),
        epochTag: 1,
        blobSize: 10,
        blobSha256: Uint8List(32),
        mediaType: 'photo',
        mimeType: 'image/jpeg',
        createdAt: now.subtract(Duration(minutes: 10 - seq)),
        albumSeq: seq,
      );

  AlbumModel album(String id, int generation) => AlbumModel(
        id: id,
        nameCt: null,
        createdAt: now,
        updatedAt: now,
        memberToken: 'me',
        mediaCount: generation,
        mediaGeneration: generation,
        hasSummary: true,
      );

  late AppState state;

  Future<_Seen> pump(
    WidgetTester tester, {
    required List<AlbumModel> albums,
    required Map<String, List<MediaRecord>> media,
    Map<String, int> seenAt = const {},
  }) async {
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    state = AppState()..setAlbums(albums);
    final seen = _Seen({...seenAt});
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        ListenableProvider<SeenStore>.value(value: seen),
      ],
      child: MaterialApp(
        home: HomeScreen(
          listMedia: (id) async => media[id] ?? const [],
          thumb: (r) => Text('photo ${r.id}'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return seen;
  }

  testWidgets('shows only what others added since you last looked',
      (tester) async {
    await pump(
      tester,
      albums: [album('lake', 3), album('road', 1)],
      seenAt: {'lake': 1, 'road': 1},
      media: {
        'lake': [
          shot('l1', 'lake', 'ana', 1),
          shot('l2', 'lake', 'ana', 2),
          shot('l3', 'lake', 'me', 3),
        ],
        'road': [shot('r1', 'road', 'ana', 1)],
      },
    );

    expect(find.text('photo l2'), findsOneWidget);
    expect(find.text('photo l1'), findsNothing, reason: 'already seen');
    expect(find.text('photo l3'), findsNothing, reason: 'your own');
    expect(find.text('photo r1'), findsNothing);
    expect(find.text("You're all caught up."), findsOneWidget);
  });

  testWidgets('every new photo in an album shows, stacked, under one header',
      (tester) async {
    await pump(
      tester,
      albums: [album('lake', 3)],
      media: {
        'lake': [
          shot('l1', 'lake', 'ana', 1),
          shot('l2', 'lake', 'bo', 2),
          shot('l3', 'lake', 'ana', 3),
        ],
      },
    );

    for (final id in ['l1', 'l2', 'l3']) {
      expect(find.text('photo $id'), findsOneWidget);
    }
    expect(find.byType(PageView), findsNothing);
    expect(find.text('An album'), findsOneWidget);
    expect(find.textContaining('Someone and Someone added 3 photos'),
        findsOneWidget);
    // Newest first, one under the next
    expect(tester.getTopLeft(find.text('photo l3')).dy,
        lessThan(tester.getTopLeft(find.text('photo l1')).dy));
  });

  testWidgets('nothing new says you are caught up, and nothing else',
      (tester) async {
    await pump(tester,
        albums: [album('lake', 2)], seenAt: {'lake': 2}, media: {});

    expect(find.text("You're all caught up."), findsOneWidget);
    expect(find.textContaining('photo'), findsNothing);
  });

  testWidgets('scrolling past an album marks it seen', (tester) async {
    final seen = await pump(
      tester,
      albums: [album('lake', 2)],
      media: {
        'lake': [shot('l1', 'lake', 'ana', 1), shot('l2', 'lake', 'ana', 2)],
      },
    );

    expect(seen.marked, [('lake', 2)]);
    // It stays for this visit even though it is now seen
    expect(find.text('photo l2'), findsOneWidget);
  });

  testWidgets('photos arriving one by one keep moving the marker',
      (tester) async {
    final media = {
      'lake': [shot('l1', 'lake', 'ana', 1)],
    };
    final seen = await pump(tester, albums: [album('lake', 1)], media: media);
    expect(seen.marked, [('lake', 1)]);

    media['lake'] = [...media['lake']!, shot('l2', 'lake', 'ana', 2)];
    state.setAlbums([album('lake', 2)]);
    await tester.pumpAndSettle();

    expect(seen.marked, [('lake', 1), ('lake', 2)]);
    expect(find.text('photo l1'), findsOneWidget);
    expect(find.text('photo l2'), findsOneWidget);
  });

  testWidgets('a long album is seen only once its last photo is reached',
      (tester) async {
    final seen = await pump(
      tester,
      albums: [album('lake', 5)],
      media: {
        'lake': [for (var i = 1; i <= 5; i++) shot('l$i', 'lake', 'ana', i)],
      },
    );
    expect(seen.marked, isEmpty);

    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(seen.marked, [('lake', 5)]);
  });
}
