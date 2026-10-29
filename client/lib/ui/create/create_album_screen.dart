import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/app/album_setup.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

import 'album_name_print.dart';
import 'glass_sheet.dart';
import 'create_copy.dart';
import 'invite_id_field.dart';

// Creates the album before finishing encryption and invites in background

class CreateAlbumScreen extends StatefulWidget {
  const CreateAlbumScreen({super.key});

  @override
  State<CreateAlbumScreen> createState() => _CreateAlbumScreenState();
}

class _CreateAlbumScreenState extends State<CreateAlbumScreen> {
  final _nameCtrl = TextEditingController();
  final _printKey = GlobalKey<AlbumNamePrintState>();
  List<String> _inviteIds = const [];
  bool _busy = false;
  bool _leaving = false;
  String? _error;

  bool get _ready => _nameCtrl.text.trim().isNotEmpty;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = CreateCopy.nameRequired);
      return;
    }
    // Capture dependencies before the route closes
    final setup = AlbumSetup.of(context);
    final userId = context.read<AppState>().userId;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    if (userId == null) {
      setState(() => _error = 'You’re signed out. Sign in again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Let the busy state paint before starting network work
    await WidgetsBinding.instance.endOfFrame;

    try {
      final started = await setup.start();
      unawaited(_finishInBackground(
        setup: setup,
        started: started,
        messenger: messenger,
        albumName: name,
        inviteIds: _inviteIds,
      ));
      // Finish the exit motion before revealing the shelf
      setState(() => _leaving = true);
      await _printKey.currentState?.flyOut();
      navigator.pop(started.album);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _finishInBackground({
    required AlbumSetup setup,
    required StartedAlbum started,
    required ScaffoldMessengerState messenger,
    required String albumName,
    required List<String> inviteIds,
  }) async {
    try {
      final failed =
          await setup.finish(started, name: albumName, inviteIds: inviteIds);
      if (failed > 0) {
        messenger.showSnackBar(SnackBar(
          content: Text(CreateCopy.invitesFailed(failed)),
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text(CreateCopy.keySetupFailed),
        duration: Duration(seconds: 4),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Warm.glassInk),
        title: const Text(CreateCopy.title,
            style: TextStyle(
                color: Warm.glassInk,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
      ),
      body: GlassSheet(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: SizedBox(
                        width: 236,
                        child: AlbumNamePrint(
                          key: _printKey,
                          controller: _nameCtrl,
                          enabled: !_busy,
                          onChanged: (_) => setState(() => _error = null),
                          onSubmitted: () {
                            if (_ready && !_busy) _create();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    AnimatedOpacity(
                      opacity: _leaving ? 0 : 1,
                      duration: Warm.quick,
                      child: InviteIdField(
                        ids: _inviteIds,
                        enabled: !_busy,
                        onChanged: (ids) => setState(() => _inviteIds = ids),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(_error!,
                          style:
                              const TextStyle(color: Warm.warn, fontSize: 13)),
                    ],
                    const SizedBox(height: 28),
                    AnimatedOpacity(
                      opacity: _leaving ? 0 : 1,
                      duration: Warm.quick,
                      child: WarmButton(
                        label: CreateCopy.createAndInvite(_inviteIds.length),
                        busy: _busy,
                        onTap: _ready && !_busy ? _create : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
