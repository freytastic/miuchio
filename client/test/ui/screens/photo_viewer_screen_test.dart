import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/screens/photo_viewer_screen.dart';

MediaRecord _shot(String id) => MediaRecord(
      id: id,
      albumId: 'album-1',
      uploaderToken: 'alice',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: 1400000,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime(2026, 3, 14),
    );

class _NoCache implements MediaCacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late List<String> deleted;
  late bool deleteWorks;

  setUp(() {
    deleted = [];
    deleteWorks = true;
  });

  final three = [_shot('m1'), _shot('m2'), _shot('m3')];

  Future<void> open(WidgetTester tester,
      {bool owner = false,
      int at = 0,
      List<MediaRecord>? records,
      Future<bool> Function(MediaRecord)? onDelete}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => PhotoViewerScreen(
                records: records ?? three,
                initialIndex: at,
                cache: _NoCache(),
                nameOf: (_) => 'Ana',
                faceOf: (_, size) => SizedBox(width: size, height: size),
                isOwner: (_) => owner,
                onDelete: onDelete ??
                    (r) async {
                      if (!deleteWorks) return false;
                      deleted.add(r.id);
                      return true;
                    },
                imageBuilder: (r, _) =>
                    ColoredBox(key: Key('photo-${r.id}'), color: Colors.grey),
                thumbBuilder: (r) =>
                    ColoredBox(key: Key('thumb-${r.id}'), color: Colors.grey),
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  double chrome(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.byKey(const Key('photo-viewer-chrome')))
      .opacity;

  Future<void> tapPhoto(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('photo-viewer-pages')));
    // Wait out the double tap window so the single tap lands
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  Finder pages() => find.byKey(const Key('photo-viewer-pages'));

  testWidgets('opens with the controls, a tap hides and shows them',
      (tester) async {
    await open(tester);
    expect(chrome(tester), 1);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    await tapPhoto(tester);
    expect(chrome(tester), 0);

    await tapPhoto(tester);
    expect(chrome(tester), 1);
  });

  testWidgets('swipes sideways through the album', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('photo-m1')), findsOneWidget);

    await tester.fling(pages(), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-m2')), findsOneWidget);

    await tester.fling(pages(), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-m1')), findsOneWidget);
  });

  testWidgets('swiping up shows the details on the paper sheet',
      (tester) async {
    await open(tester);

    await tester.fling(pages(), const Offset(0, -300), 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-details')), findsOneWidget);
    expect(find.text(AlbumCopy.sharedBy('Ana', mine: false)), findsOneWidget);
    expect(find.text('1.4 MB'), findsOneWidget);
    expect(find.text('JPEG'), findsOneWidget);
    expect(find.text(AlbumCopy.betaV2), findsWidgets);
  });

  testWidgets('swiping down closes the viewer', (tester) async {
    await open(tester);

    await tester.fling(pages(), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsNothing);
  });

  testWidgets('a double tap zooms in and stops the page turning',
      (tester) async {
    await open(tester);

    await tester.tap(pages());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(pages());
    await tester.pumpAndSettle();

    final zoom = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer).first)
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    expect(zoom, greaterThan(1.5));
    expect(chrome(tester), 0, reason: 'zooming in is for the photo alone');

    await tester.fling(pages(), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-m1')), findsOneWidget);
  });

  testWidgets('only the uploader sees delete', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('photo-peek-delete')), findsNothing);
  });

  testWidgets('delete asks first, then moves on to the next photo',
      (tester) async {
    await open(tester, owner: true);

    await tester.tap(find.byKey(const Key('photo-peek-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-delete-keep')));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);

    await tester.tap(find.byKey(const Key('photo-peek-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-delete-confirm')));
    await tester.pumpAndSettle();
    expect(deleted, ['m1']);
    expect(find.byKey(const Key('photo-m2')), findsOneWidget);
  });

  testWidgets('deleting the last photo closes the viewer', (tester) async {
    await open(tester, owner: true, records: [_shot('m1')]);

    await tester.tap(find.byKey(const Key('photo-peek-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewerScreen), findsNothing);
  });

  testWidgets('a failed delete keeps the photo', (tester) async {
    deleteWorks = false;
    await open(tester, owner: true);

    await tester.tap(find.byKey(const Key('photo-peek-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-m1')), findsOneWidget);
  });

  testWidgets('a refused delete comes back in album order', (tester) async {
    final first = Completer<bool>();
    await open(tester,
        owner: true,
        onDelete: (r) => r.id == 'm1' ? first.future : Future.value(true));

    Future<void> delete() async {
      await tester.tap(find.byKey(const Key('photo-peek-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-delete-confirm')));
      await tester.pumpAndSettle();
    }

    await delete();
    expect(find.byKey(const Key('photo-m2')), findsOneWidget,
        reason: 'the page goes before the server answers');
    await delete();
    expect(find.byKey(const Key('photo-m3')), findsOneWidget);

    first.complete(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-m3')), findsOneWidget,
        reason: 'a restore does not move the photo on screen');
    await tester.fling(pages(), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo-m1')), findsOneWidget);
  });

  testWidgets('confirming deletes the photo the sheet opened for',
      (tester) async {
    final first = Completer<bool>();
    final asked = <String>[];
    await open(tester, owner: true, onDelete: (r) {
      asked.add(r.id);
      return r.id == 'm1' ? first.future : Future.value(true);
    });

    await tester.tap(find.byKey(const Key('photo-peek-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-delete-confirm')));
    await tester.pumpAndSettle();

    // m1 comes back underneath while the sheet for m2 is open
    await tester.tap(find.byKey(const Key('photo-peek-delete')));
    await tester.pumpAndSettle();
    first.complete(false);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-delete-confirm')));
    await tester.pumpAndSettle();

    expect(asked, ['m1', 'm2']);
  });

  testWidgets('heart says it is not here yet, and there is no save',
      (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const Key('photo-peek-heart')));
    await tester.pump();
    expect(find.text(AlbumCopy.heartSoon), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('the strip shows where you are and jumps to a photo',
      (tester) async {
    await open(tester);

    expect(find.text(AlbumCopy.photoOf(1, 3)), findsOneWidget);
    await tester.tap(find.byKey(const Key('thumb-m3')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('photo-m3')), findsOneWidget);
    expect(find.text(AlbumCopy.photoOf(3, 3)), findsOneWidget);
  });

  testWidgets('details open from the bottom actions', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const Key('photo-peek-details')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('photo-details')), findsOneWidget);
  });
}
