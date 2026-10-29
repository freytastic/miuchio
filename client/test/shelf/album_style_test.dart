import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:miuchio/ui/shelf/album_stack.dart';
import 'package:miuchio/ui/shelf/album_style.dart';

void main() {
  test('tape is the default, and a choice survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pref = await AlbumStylePreference.load(prefs);
    expect(pref.style, AlbumStyle.tape);

    await pref.set(AlbumStyle.plain);
    expect((await AlbumStylePreference.load(prefs)).style, AlbumStyle.plain);
  });

  // Pin was offered once and removed
  test('a style that no longer exists falls back to tape', () async {
    SharedPreferences.setMockInitialValues({'miuchio.album_style': 'pin'});
    final pref =
        await AlbumStylePreference.load(await SharedPreferences.getInstance());
    expect(pref.style, AlbumStyle.tape);
  });

  test('each style decorates the print its own way', () {
    List<Widget> on(AlbumStyle s) =>
        decorate(s, 'a', left: 0, top: 0, side: 200);
    expect(on(AlbumStyle.tape), hasLength(1));
    expect(on(AlbumStyle.plain), isEmpty);
  });

  testWidgets('every style has a preview that lays out', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Row(children: [
        for (final s in AlbumStyle.values) AlbumStylePreview(style: s),
      ]),
    ));
    expect(find.byType(AlbumStylePreview), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
