import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/api/safety_api.dart';
import 'package:miuchio/data/storage/safety_store.dart';
import 'package:miuchio/domain/safety/reporter.dart';
import 'package:miuchio/e2ee/media_record.dart';

import 'photo_sheets.dart';
import 'safety_copy.dart';

typedef Say = void Function(String message);

Future<void> reportPhoto(BuildContext context, MediaRecord record,
    {required Say say}) async {
  final reporter = context.read<Reporter>();
  final draft = await askReport(context, photo: true);
  if (draft == null) return;
  await _send(() => reporter.photo(record, draft), say);
}

Future<void> reportPerson(
  BuildContext context, {
  required String albumId,
  required String memberToken,
  required String? name,
  required Say say,
}) async {
  final reporter = context.read<Reporter>();
  final draft = await askReport(context, photo: false, name: name);
  if (draft == null) return;
  await _send(() => reporter.person(albumId, memberToken, draft), say);
}

Future<void> _send(Future<void> Function() send, Say say) async {
  try {
    await send();
    say(SafetyCopy.reportSent);
  } catch (_) {
    say(SafetyCopy.reportFailed);
  }
}

// Null unless the block went through. The caller runs the leave or remove it
// asked for
Future<BlockChoice?> blockPerson(
  BuildContext context, {
  required String albumId,
  required String memberToken,
  required String? name,
  required bool canRemove,
  required Say say,
}) async {
  final api = context.read<SafetyApi>();
  final store = context.read<SafetyStore>();
  final choice = await askBlock(context, name: name, canRemove: canRemove);
  if (choice == null) return null;
  return await block(api, store,
          albumId: albumId, memberToken: memberToken, name: name, say: say)
      ? choice
      : null;
}

Future<bool> block(
  SafetyApi api,
  SafetyStore store, {
  required String albumId,
  required String memberToken,
  required String? name,
  required Say say,
}) async {
  try {
    final b = await api.block(albumId, memberToken);
    await store.rememberBlock(b.id, name);
  } catch (_) {
    say(SafetyCopy.blockFailed);
    return false;
  }
  say(SafetyCopy.blocked(name));
  return true;
}
