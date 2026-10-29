// Seeds a local dev stack with real accounts, an album and photos. Run it
// through tools/dev_seed/seed.sh, which resets the stack and the devices first.
//
// Sign-in and album setup go through SignInFlow and AlbumSetup, the same code
// the screens run, so the keys end up in this device's key store and the
// photos open like any other upload.
//
//   SEED_EMAIL, SEED_NAME   the account to sign in as, and its display name
//   SEED_URL                when set, base URL serving tools/dev_seed: this
//                           device creates every album in albums.json
//   SEED_INVITE             Miuchio IDs invited to the albums marked shared,
//                           comma separated
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/app/album_setup.dart';
import 'package:miuchio/app/app.dart';
import 'package:miuchio/app/sign_in_flow.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/api/auth_api.dart';
import 'package:miuchio/data/api/media_api.dart';
import 'package:miuchio/domain/account/account_gate.dart';
import 'package:miuchio/domain/upload/upload_item.dart';
import 'package:miuchio/domain/upload/upload_ports.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/main.dart' as app;
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';

const _email = String.fromEnvironment('SEED_EMAIL');
const _name = String.fromEnvironment('SEED_NAME');
// Any code signs in while the server runs with APP_ENV=dev
const _code = '000000';
const _seedUrl = String.fromEnvironment('SEED_URL');
const _invite = String.fromEnvironment('SEED_INVITE');

List<String> _list(String csv) =>
    [for (final s in csv.split(',')) if (s.trim().isNotEmpty) s.trim()];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('seed', (tester) async {
    if (_email.isEmpty || _name.isEmpty) {
      fail('SEED_EMAIL and SEED_NAME are required');
    }
    // The app installs its own error handlers, which would hide test failures
    final onError = FlutterError.onError;
    app.main();
    await _pumpUntil(
        tester, () async => find.byType(MiuchioApp).evaluate().isNotEmpty,
        what: 'the app to start');
    FlutterError.onError = onError;
    final ctx = tester.element(find.byType(MiuchioApp));

    final miuchioId = await _signIn(ctx);
    // seed.sh reads this line to pass the ID to the next device
    debugPrint('SEED_MIUCHIO_ID=$miuchioId');

    if (_seedUrl.isNotEmpty) {
      final res = await http.get(Uri.parse('$_seedUrl/albums.json'));
      if (res.statusCode != 200) fail('could not read albums.json');
      final albums = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
      // Each album fetches the same prekey bundles, so this relies on the
      // server running with APP_ENV=dev, which turns off the rate limits.
      // In reverse, so the first album in the file is the most recent
      for (final album in albums.reversed) {
        final name = album['name'] as String;
        final shared = album['shared'] as bool? ?? false;
        final photos = (album['photos'] as List).cast<String>();
        final albumId =
            await _createAlbum(ctx, name, shared ? _list(_invite) : const []);
        await _upload(tester, ctx, albumId, photos);
        debugPrint('SEED_ALBUM=$name photos=${photos.length} shared=$shared');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<String> _signIn(BuildContext ctx) async {
  if (!await AuthService().requestOtp(_email)) {
    fail('the server refused to send a code');
  }
  final result = await SignInFlow.of(ctx).verify(_email, _code);
  switch (result) {
    case SignInWrongCode():
      fail('code $_code was refused: is APP_ENV=dev set?');
    case SignInRefused(:final outcome):
      fail('sign-in refused with $outcome: reset the stack and device first');
    case SignInDone(:final outcome):
      if (outcome != AccountGateOutcome.newAccount) {
        fail('expected a new account, got $outcome: reset the stack first');
      }
  }
  // Set before the album exists, so it is the name published to it
  final appState = ctx.read<AppState>()..setProfileName(_name);
  await bootstrapIdentity(ctx.read<IdentityService>());
  return appState.miuchioId!;
}

Future<String> _createAlbum(
    BuildContext ctx, String name, List<String> inviteIds) async {
  final setup = AlbumSetup.of(ctx);
  final started = await setup.start();
  final failed = await setup.finish(started, name: name, inviteIds: inviteIds);
  if (failed > 0) fail('$failed of ${inviteIds.length} invites failed');
  final listing = await AlbumService().getMyAlbums();
  if (listing != null) ctx.read<AppState>().applyListing(listing);
  return started.id;
}

// Mirrors AlbumDetailScreen._enqueuePicked, with downloads in place of the picker
Future<void> _upload(WidgetTester tester, BuildContext ctx, String albumId,
    List<String> paths) async {
  if (paths.isEmpty) return;
  final queue = ctx.read<UploadQueueModel>();
  final dir = await Directory(
          '${(await getTemporaryDirectory()).path}/dev_seed')
      .create(recursive: true);
  final sources = <PickedSource>[];
  for (final path in paths) {
    final res = await http.get(Uri.parse('$_seedUrl/photos/$path'));
    if (res.statusCode != 200) fail('could not download $path: ${res.statusCode}');
    final file = File('${dir.path}/${path.split('/').last}');
    await file.writeAsBytes(res.bodyBytes);
    sources.add(PickedSource(path: file.path, mimeType: 'image/jpeg'));
  }

  final staged = await queue.stage(sources);
  final batchId = queue.startBatch(albumId: albumId, sources: staged);
  // The queue shows a batch late and drops it once done, so the server's
  // listing is what says the photos landed
  final media = ctx.read<MediaApi>();
  await _pumpUntil(tester, () async {
    final failed = queue.state
            .batch(batchId)
            ?.items
            .where((i) => i.phase == UploadPhase.failed) ??
        const [];
    if (failed.isNotEmpty) fail('upload failed: ${failed.first.failure}');
    return (await media.listMedia(albumId)).length >= paths.length;
  },
      what: 'the photos to upload',
      every: const Duration(seconds: 1),
      limit: const Duration(minutes: 3));
}

Future<void> _pumpUntil(WidgetTester tester, Future<bool> Function() done,
    {required String what,
    Duration every = const Duration(milliseconds: 250),
    Duration limit = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(limit);
  while (!await done()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await tester.pump(every);
  }
}
