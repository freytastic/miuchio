import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/app/album_setup.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/storage/identity_pin_store.dart';
import 'package:miuchio/data/storage/known_people_store.dart';
import 'package:miuchio/e2ee/handle.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/ui/album/member_avatars.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/member_face.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:miuchio/ui/widgets/warm_field.dart';

import 'create_copy.dart';
import 'id_dash_formatter.dart';

// Creates the album before finishing encryption and invites in background

// Someone who can be ticked: a person this phone invited before, or an ID
// typed in just now
class _Pick {
  final String handle;
  final String? name;
  final String? albumId;
  final String? token;
  final bool isNew;

  const _Pick({
    required this.handle,
    this.name,
    this.albumId,
    this.token,
    this.isNew = false,
  });
}

class CreateAlbumScreen extends StatefulWidget {
  const CreateAlbumScreen({super.key});

  // An album holds 10 people, so 9 besides you
  static const maxInvites = 9;

  @override
  State<CreateAlbumScreen> createState() => _CreateAlbumScreenState();
}

class _CreateAlbumScreenState extends State<CreateAlbumScreen> {
  final _nameCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _idFocus = FocusNode();
  final List<String> _typed = [];
  final Set<String> _chosen = {};
  bool _entering = false;
  bool _busy = false;
  String? _error;
  String? _idError;

  bool get _ready => _nameCtrl.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _idFocus.addListener(_collapseIfEmpty);
  }

  // Leaving an untouched ID field folds it back into the add row
  void _collapseIfEmpty() {
    if (_idFocus.hasFocus || !_entering) return;
    if (_idCtrl.text.trim().isNotEmpty) return;
    setState(() {
      _entering = false;
      _idError = null;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    _idFocus.removeListener(_collapseIfEmpty);
    _idFocus.dispose();
    super.dispose();
  }

  // People this phone invited before, named from whichever album they show
  // up in. Nothing here leaves the phone
  List<_Pick> _known() {
    final state = context.watch<AppState>();
    final store = context.watch<KnownPeopleStore?>();
    IdentityPinStore? pins;
    try {
      pins = context.read<IdentityPinStore>();
    } catch (_) {
      pins = null;
    }
    final mine = state.miuchioId;
    final out = <_Pick>[];
    for (final p in store?.people ?? const <KnownPerson>[]) {
      if (p.handle == mine || _typed.contains(p.handle)) continue;
      String? album = p.albumId;
      String? token = p.memberToken;
      var name = state.memberDisplayName(album, token);
      if (name == null && pins != null) {
        for (final a in state.albums) {
          final bytes = uuidToBytes(a.id);
          if (bytes == null) continue;
          for (final m in a.memberPreviews) {
            final ik = pins.pinnedIk(hexAlbumId(bytes), m.memberToken);
            if (ik == null || base64.encode(ik) != p.ikPub) continue;
            final found = state.memberDisplayName(a.id, m.memberToken);
            if (found != null) {
              name = found;
              album = a.id;
              token = m.memberToken;
              break;
            }
          }
          if (name != null) break;
        }
      }
      out.add(
          _Pick(handle: p.handle, name: name, albumId: album, token: token));
    }
    return out;
  }

  void _toggle(String handle) {
    HapticFeedback.selectionClick();
    setState(() {
      _idError = null;
      if (_chosen.remove(handle)) return;
      if (_chosen.length >= CreateAlbumScreen.maxInvites) {
        _idError = CreateCopy.albumFull;
        return;
      }
      _chosen.add(handle);
    });
  }

  void _openEntry() {
    HapticFeedback.selectionClick();
    setState(() {
      _entering = true;
      _idError = null;
    });
    _idFocus.requestFocus();
  }

  void _addTyped(List<_Pick> known) {
    final String handle;
    try {
      handle = normalizeHandle(_idCtrl.text);
    } on FormatException {
      setState(() => _idError = CreateCopy.idInvalid);
      return;
    }
    if (handle == context.read<AppState>().miuchioId) {
      setState(() => _idError = CreateCopy.idSelf);
      return;
    }
    if (_chosen.contains(handle)) {
      setState(() => _idError = CreateCopy.idDuplicate);
      return;
    }
    if (_chosen.length >= CreateAlbumScreen.maxInvites) {
      setState(() => _idError = CreateCopy.albumFull);
      return;
    }
    setState(() {
      // Someone already on the list is ticked rather than listed twice
      if (!known.any((p) => p.handle == handle)) _typed.add(handle);
      _chosen.add(handle);
      _idCtrl.clear();
      _entering = false;
      _idError = null;
    });
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
        inviteIds: _chosen.toList(),
      ));
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
    final known = _known();
    final picks = [
      for (final h in _typed) _Pick(handle: h, isNew: true),
      ...known,
    ];
    final bottom = MediaQuery.paddingOf(context).bottom;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics()),
                  padding: const EdgeInsets.fromLTRB(
                      Warm.pagePad - 8, 16, Warm.pagePad - 8, 24),
                  children: [
                    const Align(
                        alignment: Alignment.centerLeft, child: WarmBack()),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 22, 8, 0),
                      child: Text(CreateCopy.title, style: Warm.pageTitle),
                    ),
                    const SizedBox(height: 22),
                    WarmField(
                      controller: _nameCtrl,
                      label: CreateCopy.namePlaceholder,
                      autofocus: true,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.done,
                      maxLength: 60,
                      onChanged: (_) => setState(() => _error = null),
                      onSubmitted: (_) =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                        child: Text(_error!,
                            style: Warm.note.copyWith(color: Warm.warn)),
                      ),
                    const SizedBox(height: 30),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(CreateCopy.invitePeople.toUpperCase(),
                                style: Warm.sectionLabel),
                          ),
                          if (_chosen.isNotEmpty)
                            Text(CreateCopy.chosen(_chosen.length),
                                style: Warm.rowValue.copyWith(fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _Card(children: [
                      for (final p in picks)
                        _PersonRow(
                          key: ValueKey('pick-${p.handle}'),
                          pick: p,
                          chosen: _chosen.contains(p.handle),
                          enabled: !_busy,
                          onTap: () => _toggle(p.handle),
                        ),
                      _AddRow(
                        entering: _entering,
                        enabled: !_busy,
                        controller: _idCtrl,
                        focusNode: _idFocus,
                        onOpen: _openEntry,
                        onSubmit: () => _addTyped(known),
                      ),
                    ]),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                      child: Text(
                        _idError ??
                            (known.isEmpty
                                ? CreateCopy.knownEmpty
                                : CreateCopy.privacyWithInvites),
                        style: _idError == null
                            ? Warm.note
                            : Warm.note.copyWith(color: Warm.warn),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                    Warm.pagePad - 8, 8, Warm.pagePad - 8, 14 + bottom),
                child: WarmButton(
                  label: CreateCopy.createAndInvite(_chosen.length),
                  busy: _busy,
                  onTap: _ready && !_busy ? _create : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// One soft card, divided by hairlines that start after the faces
class _Card extends StatelessWidget {
  final List<Widget> children;

  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Warm.groundLift,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.only(left: 70),
                child: Divider(height: 1, thickness: 1, color: Warm.inkGhost),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  final _Pick pick;
  final bool chosen;
  final bool enabled;
  final VoidCallback onTap;

  const _PersonRow({
    super.key,
    required this.pick,
    required this.chosen,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = pick;
    final id = formatHandle(p.handle);
    final title = p.name ?? id;
    final detail = p.isNew
        ? CreateCopy.newPerson
        : p.name == null
            ? CreateCopy.notJoinedYet
            : id;
    return Semantics(
      button: true,
      selected: chosen,
      label: title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 40,
                child: p.name == null || p.albumId == null || p.token == null
                    ? const DashedCircle(size: 40)
                    : MemberFace(
                        albumId: p.albumId,
                        token: p.token!,
                        name: p.name,
                        size: 40,
                        style: Warm.acFace.copyWith(fontSize: 14),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Warm.rowTitle),
                    const SizedBox(height: 1),
                    Text(detail,
                        style: Warm.rowValue.copyWith(color: Warm.inkFaint)),
                  ],
                ),
              ),
              _Check(on: chosen),
            ],
          ),
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool on;

  const _Check({required this.on});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Warm.quick,
      curve: Warm.easeOut,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? Warm.cta : Colors.transparent,
        border: Border.all(
            color: on ? Warm.cta : Warm.inkGhost, width: on ? 0 : 1.5),
      ),
      child: on
          ? const Icon(Icons.check_rounded, size: 15, color: Warm.ctaInk)
          : null,
    );
  }
}

// Adding someone the phone has not invited before, by their Miuchio ID
class _AddRow extends StatelessWidget {
  final bool entering;
  final bool enabled;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onOpen;
  final VoidCallback onSubmit;

  const _AddRow({
    required this.entering,
    required this.enabled,
    required this.controller,
    required this.focusNode,
    required this.onOpen,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    if (!entering) {
      return Semantics(
        button: true,
        label: CreateCopy.addSomeoneNew,
        excludeSemantics: true,
        child: GestureDetector(
          key: const Key('create-add-new'),
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onOpen : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                MakeButton(size: 40, onTap: enabled ? onOpen : null),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(CreateCopy.addSomeoneNew, style: Warm.rowTitle),
                      const SizedBox(height: 1),
                      Text(CreateCopy.withTheirId,
                          style: Warm.rowValue.copyWith(color: Warm.inkFaint)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('create-id-field'),
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              inputFormatters: [IdDashFormatter()],
              textInputAction: TextInputAction.done,
              style: Warm.fieldText.copyWith(letterSpacing: 1.2),
              cursorColor: Warm.ink,
              decoration: InputDecoration(
                isDense: true,
                hintText: CreateCopy.idHint,
                hintStyle: Warm.fieldText
                    .copyWith(letterSpacing: 1.2, color: Warm.inkGhost),
                labelText: CreateCopy.idPlaceholder,
                labelStyle: Warm.fieldLabel,
                floatingLabelBehavior: FloatingLabelBehavior.always,
                filled: true,
                fillColor: Warm.fieldFill,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          const SizedBox(width: 4),
          PressableScale(
            onTap: enabled ? onSubmit : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(CreateCopy.add,
                  style: Warm.rowTitle.copyWith(color: Warm.cta)),
            ),
          ),
        ],
      ),
    );
  }
}
