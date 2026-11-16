import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/domain/upload/upload_coordinator.dart';
import 'package:miuchio/domain/upload/upload_item.dart';
import 'package:miuchio/domain/upload/upload_ports.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'package:miuchio/ui/widgets/upload_pill.dart';
import 'package:miuchio/ui/widgets/upload_sheet.dart';
import 'package:provider/provider.dart';

import '../domain/upload/fakes.dart';

const _album = 'album-1';

void main() {
  late FakeSources sources;
  late FakeUploader uploader;
  late UploadCoordinator co;
  late UploadQueueModel model;

  setUp(() {
    sources = FakeSources();
    uploader = FakeUploader();
    co = UploadCoordinator(
      sources: sources,
      preparer: FakePreparer(),
      uploader: uploader,
      sink: FakeSink(),
      sleep: (_) async {},
      throttle: Duration.zero,
    );
    model = UploadQueueModel(co);
  });

  tearDown(() async {
    model.dispose();
    await co.dispose();
  });

  List<PickedSource> pick(int n) => [
        for (var i = 0; i < n; i++)
          () {
            sources.add('/cache/pick/$i.jpg');
            return PickedSource(path: '/cache/pick/$i.jpg');
          }(),
      ];

  Future<void> pump(WidgetTester tester,
          {UploadPill pill = const UploadPill()}) =>
      tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<UploadQueueModel>.value(value: model),
            ChangeNotifierProvider<AppState>(create: (_) => AppState()),
          ],
          child: MaterialApp(home: Scaffold(body: pill)),
        ),
      );

  testWidgets('a clean batch is cleaned up rather than left unreachable',
      (tester) async {
    final batchId = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pump(tester);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(model.state.batch(batchId), isNull,
        reason: 'a finished batch with no screen watching must be released');
  });

  testWidgets('a clean batch waits for the open album before it is released',
      (tester) async {
    model.observeAlbum(_album);
    final batchId = model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);
    await pump(tester);

    expect(model.state.batch(batchId), isNotNull);

    final mediaId = model.state.batch(batchId)!.items.single.mediaId.value;
    model.recordsLanded(_album, {mediaId});
    await tester.pump();

    expect(model.state.batch(batchId), isNull);
  });

  testWidgets('counts a failed photo as a position already passed',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 3);
    var reserves = 0;
    uploader.onReserve = () {
      if (++reserves == 2) uploader.holdReserve = Completer<void>();
    };
    model.startBatch(albumId: _album, sources: pick(3));
    await pump(tester);
    await tester.pump(Duration.zero);
    await tester.pump();

    expect(find.text('2/3'), findsOneWidget);
    uploader.holdReserve!.complete();
  });

  testWidgets('stays reachable after a batch settles with losses',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 99);
    model.startBatch(albumId: _album, sources: pick(2));
    await tester.pump(Duration.zero);
    await pump(tester);

    expect(find.text('2 didn’t send'), findsOneWidget);
  });

  // Replacements picked from another album's screen would reach other people
  testWidgets('only the album a batch belongs to can pick replacements',
      (tester) async {
    uploader.failStage('putFile',
        const UploadStageException(UploadFailureKind.transport, 'reset'),
        times: 99);
    model.startBatch(albumId: _album, sources: pick(1));
    await tester.pump(Duration.zero);

    for (final (open, offered) in [('album-2', false), (_album, true)]) {
      await pump(tester,
          pill: UploadPill(
              albumId: open, onPickMore: () {}, onDismiss: (_) async {}));
      await tester.pump();
      await tester.tap(find.byType(UploadPill));
      await tester.pumpAndSettle();

      final sheet = tester.widget<UploadSheet>(find.byType(UploadSheet));
      expect(sheet.onPickMore != null, offered, reason: open);
      expect(sheet.onDismiss != null, offered, reason: open);
      Navigator.of(tester.element(find.byType(UploadSheet))).pop();
      await tester.pumpAndSettle();
    }
  });
}
