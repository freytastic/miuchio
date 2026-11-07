import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/api/safety_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/storage/safety_store.dart';
import 'package:miuchio/e2ee/member_removal.dart';
import 'package:miuchio/ui/providers/app_state.dart';

import 'photo_sheets.dart';
import 'safety_copy.dart';
import 'safety_flows.dart';

// True when the album may open. An album someone else made asks once before
// any of its photos show, and asks again after leaving and being re-added
Future<bool> passAlbumGate(BuildContext context, AlbumModel album,
    {AlbumService? albumService}) async {
  final store = context.read<SafetyStore?>();
  if (store == null || store.accepted(album.id)) return true;
  final state = context.read<AppState>();
  final api = context.read<SafetyApi>();
  final removal = context.read<MemberRemovalCoordinator>();
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

  final owner = await _ownerToken(albumService ?? AlbumService(), album.id);
  final ownerName =
      owner == null ? null : state.memberDisplayName(album.id, owner);
  if (!context.mounted) return false;
  final choice = await askAlbumGate(context,
      title: state.albumDisplayName(album.id),
      addedBy: ownerName,
      canBlock: owner != null);

  Future<void> leave() async {
    final albumId = uuidToBytes(album.id);
    final self = album.memberToken;
    if (albumId == null || self == null) return;
    try {
      await removal.leave(albumId, base64.decode(base64.normalize(self)),
          deleteMedia: state.deleteMediaOnLeave);
    } on MemberRemovalException {
      say(SafetyCopy.gateLeaveFailed);
    } catch (_) {
      // The server already let us go, cleanup retries the local wipe
    }
  }

  switch (choice) {
    case AlbumGateChoice.open:
      await store.accept(album);
      return true;
    case AlbumGateChoice.block:
      if (await block(api, store,
          albumId: album.id, memberToken: owner!, name: ownerName, say: say)) {
        await leave();
      }
    case AlbumGateChoice.leave:
      await leave();
    case null:
      break;
  }
  return false;
}

// Bounded so a slow listing never holds the album shut, it only drops Block
Future<String?> _ownerToken(AlbumService service, String albumId) async {
  try {
    final members =
        await service.listMembers(albumId).timeout(const Duration(seconds: 3));
    return members
        .where((m) => m.role == 'admin' && !m.revoked)
        .firstOrNull
        ?.memberToken;
  } on TimeoutException {
    return null;
  }
}
