import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const kInstallIdName = 'miuchio_install_id';

final _installIdPattern = RegExp(r'^[0-9a-f]{32}$');

// Only the review login sends this. Its in the support dir and is not
// kept by the in app wipe, so uninstalling or deleting the account gives the
// next review sign in a fresh account
Future<String> installId({Directory? supportDir}) async {
  final dir = supportDir ?? await getApplicationSupportDirectory();
  final file = File(p.join(dir.path, kInstallIdName));
  if (await file.exists()) {
    final saved = (await file.readAsString()).trim();
    if (_installIdPattern.hasMatch(saved)) return saved;
  }
  final rng = Random.secure();
  final id = List.generate(
      16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  await dir.create(recursive: true);
  await file.writeAsString(id, flush: true);
  return id;
}
