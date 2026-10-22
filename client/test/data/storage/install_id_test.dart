import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:miuchio/app/device_wipe.dart';
import 'package:miuchio/data/storage/install_id.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('install_id'));
  tearDown(() async => dir.delete(recursive: true));

  test('stays the same across reads', () async {
    final first = await installId(supportDir: dir);
    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(await installId(supportDir: dir), first);
  });

  // A deleted review account must not be reused by the next review sign in
  test('the in app wipe rotates it', () async {
    final first = await installId(supportDir: dir);
    await emptyDir(dir);
    expect(await installId(supportDir: dir), isNot(first));
  });

  test('replaces a corrupt file', () async {
    await File(p.join(dir.path, kInstallIdName)).writeAsString('junk');
    expect(
        await installId(supportDir: dir), matches(RegExp(r'^[0-9a-f]{32}$')));
  });
}
