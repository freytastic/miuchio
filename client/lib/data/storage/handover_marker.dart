import 'dart:convert';
import 'dart:io';

import 'package:miuchio/e2ee/admin_handover.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const kHandoverMarkerName = 'miuchio_handover_pending.json';

// Holds signed requests the server already sees in the clear, so it is
// stored plain, outside the album's own storage
class HandoverMarkerFile implements HandoverMarkerStore {
  final File file;
  HandoverMarkerFile(this.file);

  static Future<HandoverMarkerFile> open() async =>
      HandoverMarkerFile(File(p.join(
          (await getApplicationSupportDirectory()).path, kHandoverMarkerName)));

  @override
  Future<List<PendingHandover>> read() async {
    if (!await file.exists()) return const [];
    final raw = jsonDecode(await file.readAsString());
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (PendingHandover.tryParse(e) case final p?) p,
    ];
  }

  @override
  Future<void> write(PendingHandover pending) async {
    final all = [
      for (final e in await read())
        if (e.albumId != pending.albumId) e,
      pending,
    ];
    await _save(all);
  }

  @override
  Future<void> clear(String albumId) async {
    final all = await read();
    final rest = [
      for (final e in all)
        if (e.albumId != albumId) e
    ];
    if (rest.length == all.length) return;
    if (rest.isEmpty) {
      await file.delete();
    } else {
      await _save(rest);
    }
  }

  Future<void> _save(List<PendingHandover> all) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final e in all) e.toJson()]),
        flush: true);
    await tmp.rename(file.path);
  }
}
