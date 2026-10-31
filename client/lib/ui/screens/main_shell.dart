import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/people/everyone.dart';
import 'package:miuchio/ui/screens/album_detail_screen.dart';
import 'package:miuchio/ui/create/create_album_screen.dart';
import 'package:miuchio/ui/screens/notifications_screen.dart';
import 'package:miuchio/ui/shelf/album_chooser.dart';
import 'package:miuchio/ui/shelf/profile_screen.dart';
import 'package:miuchio/ui/shelf/shelf_screen.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  // The glass sheet rises over the shelf, which stays visible behind it
  // Every other screen opens as a MaterialPageRoute for the platform's back
  static Route<void> _rise(Widget page) => PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Warm.easeSoft)),
          child: child,
        ),
        transitionDuration: Warm.springSnappy,
      );

  Future<void> _create(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final appState = context.read<AppState>();
    await Navigator.of(context).push(_rise(const CreateAlbumScreen()));
    await _refresh(appState);
  }

  // With no albums yet there is nowhere to add photos, so + starts one
  Future<void> _make(BuildContext context) async {
    final state = context.read<AppState>();
    final albums =
        state.albums.where((a) => !state.isDeleting(a.id)).toList();
    if (albums.isEmpty) return _create(context);
    HapticFeedback.selectionClick();
    final choice = await askChoice<_Make>(context, choices: const [
      SheetChoice(
          _Make.photos, Icons.add_photo_alternate_outlined, 'Add photos',
          detail: 'To one of your albums'),
      SheetChoice(_Make.album, Icons.photo_album_outlined, 'New album',
          detail: 'Start one and invite people'),
    ]);
    if (!context.mounted) return;
    switch (choice) {
      case _Make.photos:
        final album = await AlbumChooser.show(context, albums);
        if (album != null && context.mounted) {
          await _openAlbum(context, album, add: true);
        }
      case _Make.album:
        await _create(context);
      case null:
        break;
    }
  }

  Future<void> _openAlbum(BuildContext context, AlbumModel album,
      {bool add = false}) async {
    final appState = context.read<AppState>();
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(
            builder: (_) => AlbumDetailScreen(album: album, addOnOpen: add)));
    // Refresh without delaying shelf development
    unawaited(_refresh(appState));
  }

  // Keep stale albums when refresh fails
  static Future<void> _refresh(AppState appState) async {
    final fresh = await AlbumService().getMyAlbums();
    if (fresh != null) appState.applyListing(fresh);
  }

  // Activity rows reuse the shelf's album navigation
  Future<void> _openActivity(BuildContext context) async {
    final appState = context.read<AppState>();
    final albumId = await Navigator.of(context)
        .push(MaterialPageRoute<String>(
            builder: (_) => const NotificationsScreen()));
    if (albumId == null || !context.mounted) return;
    final album = appState.albums.where((a) => a.id == albumId).firstOrNull;
    if (album != null) await _openAlbum(context, album);
  }

  @override
  Widget build(BuildContext context) {
    return ShelfScreen(
      onOpenProfile: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              ProfileScreen(onSafetyNumbers: () => openEveryone(context)))),
      onOpenAlbum: (album) => _openAlbum(context, album),
      onCreateAlbum: () => _create(context),
      onMake: () => _make(context),
      onOpenActivity: () => _openActivity(context),
      onOpenPeople: (album) => openAlbumPeople(context, album),
    );
  }
}

enum _Make { photos, album }
