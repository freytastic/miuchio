import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'package:miuchio/data/storage/own_avatar_store.dart';
import 'package:miuchio/domain/avatar/avatar_publisher.dart';
import 'package:miuchio/ui/screens/add_photo_screen.dart';

Uint8List _jpeg(int shade) => Uint8List.fromList(img.encodeJpg(
    img.Image(width: 8, height: 8)..clear(img.ColorRgb8(shade, shade, shade))));

void main() {
  late Directory dir;
  late OwnAvatarStore store;
  late int done;
  final generic = _jpeg(200);
  final chosen = _jpeg(40);

  setUp(() => dir = Directory.systemTemp.createTempSync('addphoto'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    store = (await tester.runAsync(() => OwnAvatarStore.open(
        file: File('${dir.path}/avatar.kec'), cacheRootKey: Uint8List(32))))!;
    done = 0;
    await tester.pumpWidget(ChangeNotifierProvider<OwnAvatarStore>.value(
      value: store,
      child: MaterialApp(
        home: AddPhotoScreen(
          onDone: () => done++,
          generic: (_) async => generic,
          pick: (_) async => chosen,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // The store seals and writes in several steps, each needing real time
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20 && done == 0; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  testWidgets('skipping keeps a generic picture rather than a letter',
      (tester) async {
    await pump(tester);
    expect(find.text('Add a profile photo'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await settle(tester);

    expect(store.state, OwnAvatarState.set);
    expect(store.jpeg, generic);
    expect(done, 1);
  });

  testWidgets('a chosen photo is what gets saved', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Choose a photo'));
    await tester.pumpAndSettle();
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Choose another'), findsWidgets);

    await tester.tap(find.text('Continue'));
    await settle(tester);

    expect(store.jpeg, chosen);
    expect(done, 1);
  });
}
