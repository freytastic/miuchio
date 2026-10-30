import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/album_info_screen.dart';
import 'package:miuchio/ui/album/album_stats.dart';

MediaRecord _shot(String id, String by, int blob) => MediaRecord(
      id: id,
      albumId: 'album-1',
      uploaderToken: by,
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: blob,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime(2026),
    );

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<MediaRecord> records,
    Map<String, String> names = const {},
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: AlbumInfoScreen(
        albumName: 'Lisbon',
        createdAt: DateTime(2026, 3, 14),
        stats: AlbumStats.of(records, peopleCount: 2),
        nameOf: (token) => names[token],
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('an uploader whose name has not decrypted is not named by token',
      (tester) async {
    await pump(tester, records: [_shot('a', 'secret-token', 1000)]);

    expect(find.textContaining('secret'), findsNothing);
    expect(find.text(AlbumCopy.unknownMember), findsOneWidget);
  });

  testWidgets('leaving closes the screen and hands the choice back',
      (tester) async {
    AlbumInfoExit? chosen;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            chosen = await Navigator.of(context)
                .push(MaterialPageRoute<AlbumInfoExit>(
              builder: (_) => AlbumInfoScreen(
                albumName: 'Lisbon',
                createdAt: DateTime(2026, 3, 14),
                stats: AlbumStats.of(const [], peopleCount: 2),
                nameOf: (_) => null,
                exit: AlbumInfoExit.leave,
              ),
            ));
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(AlbumCopy.deleteAlbum), findsNothing);
    await tester.tap(find.byKey(const Key('album-info-leave')));
    await tester.pumpAndSettle();

    expect(chosen, AlbumInfoExit.leave);
    expect(find.byType(AlbumInfoScreen), findsNothing);
  });

  testWidgets('without an exit there is no way out offered', (tester) async {
    await pump(tester, records: const []);

    expect(find.text(AlbumCopy.leaveAlbum), findsNothing);
    expect(find.text(AlbumCopy.deleteAlbum), findsNothing);
  });
}
