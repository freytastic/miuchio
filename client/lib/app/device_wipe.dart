import 'dart:io';

import 'package:miuchio/data/storage/deletion_marker.dart';
import 'package:miuchio/data/storage/install_guard.dart';
import 'package:miuchio/data/storage/secure_storage.dart';
import 'package:miuchio/secure_store/key_store_exceptions.dart';
import 'package:miuchio/secure_store/secure_key_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Retain the deletion receipt until verification and the install marker to
// prevent a later launch from wiping a new sign in
bool _survivesWipe(String name) =>
    name == kDeletionMarkerName ||
    name == kInstallMarkerName ||
    name.startsWith('com.apple.');

Future<void> emptyDir(Directory dir) async {
  if (!await dir.exists()) return;
  final failed = <String>[];
  await for (final entry in dir.list(followLinks: false)) {
    final name = p.basename(entry.path);
    if (_survivesWipe(name)) continue;
    try {
      await entry.delete(recursive: true);
    } catch (_) {
      failed.add(name);
    }
  }
  if (failed.isNotEmpty) {
    throw FileSystemException('not deleted', failed.join(', '));
  }
}

// Verify deletion because some stores swallow their own failures
Future<List<String>> wipeLeftovers(SecureKeyStore keys) async {
  final left = <String>[];
  for (final dir in [
    await getApplicationSupportDirectory(),
    await getApplicationCacheDirectory(),
    await getTemporaryDirectory(),
  ]) {
    if (!await dir.exists()) continue;
    await for (final entry in dir.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (!_survivesWipe(name)) left.add('file $name');
    }
  }
  if ((await appSecureStorage.readAll()).isNotEmpty) {
    left.add('secure storage');
  }
  if ((await SharedPreferences.getInstance()).getKeys().isNotEmpty) {
    left.add('preferences');
  }
  try {
    if ((await keys.list()).isNotEmpty) left.add('keystore');
  } on KeyStoreUninitializedException {
    // A missing wrapper key confirms the store is wiped
  }
  return left;
}
