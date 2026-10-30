import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/domain/albums/known_invitees.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/grouped_list.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:miuchio/ui/navigation/screen_route.dart';

import 'album_copy.dart';
import 'member_avatars.dart';

class ManagedPerson {
  final String id;
  final String name;
  final Widget face;
  final bool owner;
  final bool self;
  // Invited but not joined, so no name has been published yet
  final bool invited;

  const ManagedPerson({
    required this.id,
    required this.name,
    required this.face,
    this.owner = false,
    this.self = false,
    this.invited = false,
  });
}

// What an album's owner can change: the cover, the name and who is in it,
// with its facts a tap away and deleting it last
class AlbumSettingsScreen extends StatefulWidget {
  final String Function() name;
  final List<MediaRecord> photos;
  // The chosen cover, or null when the newest photo leads
  final String? coverId;
  final Widget Function(MediaRecord record) thumb;
  // Returns the cover now in use once the owner has chosen
  final Future<String?> Function(String? current) onChangeCover;
  final Future<void> Function() onRename;
  final Future<List<ManagedPerson>> Function() load;
  final Future<void> Function() onAdd;
  // Confirms first; the list reloads after it returns either way
  final Future<void> Function(ManagedPerson person) onRemove;
  // Opens someone who has joined: their security code and their photos
  final Future<void> Function(ManagedPerson person)? onOpen;
  final VoidCallback onInfo;
  final VoidCallback onDelete;

  const AlbumSettingsScreen({
    super.key,
    required this.name,
    required this.photos,
    required this.coverId,
    required this.thumb,
    required this.onChangeCover,
    required this.onRename,
    required this.load,
    required this.onAdd,
    required this.onRemove,
    required this.onInfo,
    required this.onDelete,
    this.onOpen,
  });

  @override
  State<AlbumSettingsScreen> createState() => _AlbumSettingsScreenState();
}

class _AlbumSettingsScreenState extends State<AlbumSettingsScreen> {
  List<ManagedPerson>? _people;
  bool _failed = false;
  late String? _cover = widget.coverId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final people = await widget.load();
      // The owner leads, then everyone who joined, then open invites
      int rank(ManagedPerson p) => p.owner ? 0 : (p.invited ? 2 : 1);
      people.sort((a, b) => rank(a).compareTo(rank(b)));
      if (mounted) {
        setState(() {
          _people = people;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _add() async {
    HapticFeedback.selectionClick();
    await widget.onAdd();
    await _reload();
  }

  Future<void> _open(ManagedPerson p) async {
    HapticFeedback.selectionClick();
    await widget.onOpen?.call(p);
    await _reload();
  }

  Future<void> _remove(ManagedPerson p) async {
    HapticFeedback.selectionClick();
    await widget.onRemove(p);
    await _reload();
  }

  Future<void> _changeCover() async {
    HapticFeedback.selectionClick();
    final next = await widget.onChangeCover(_cover);
    if (mounted) setState(() => _cover = next);
  }

  Future<void> _rename() async {
    await widget.onRename();
    if (mounted) setState(() {});
  }

  // The chosen photo if it is still here, otherwise the newest
  MediaRecord? get _coverRecord {
    final photos = widget.photos.where((r) => r.hasThumb).toList();
    return photos.where((r) => r.id == _cover).firstOrNull ??
        photos.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final count = people?.length ?? 0;
    final full = count >= albumMemberCap;
    final cover = _coverRecord;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: ListView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            padding: const EdgeInsets.fromLTRB(
                Warm.pagePad - 8, 16, Warm.pagePad - 8, 56),
            children: [
              const Align(alignment: Alignment.centerLeft, child: WarmBack()),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 22, 8, 0),
                child: Text(AlbumCopy.albumSettings, style: Warm.pageTitle),
              ),
              const SizedBox(height: 22),
              _CoverHero(
                cover: cover == null ? null : widget.thumb(cover),
                chosen: _cover != null,
                onChange:
                    widget.photos.any((r) => r.hasThumb) ? _changeCover : null,
              ),
              const SizedBox(height: 12),
              GroupCard(children: [
                _LinkRow(
                  key: const Key('settings-rename'),
                  icon: Icons.edit_outlined,
                  title: widget.name(),
                  detail: AlbumCopy.renameAlbum,
                  onTap: _rename,
                ),
              ]),
              const SizedBox(height: 28),
              SectionLabel(
                AlbumCopy.people,
                trailing: people == null
                    ? null
                    : AlbumCopy.peopleOf(count, albumMemberCap),
              ),
              const SizedBox(height: 10),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child:
                            Text("Couldn't load people.", style: Warm.pageSoft),
                      ),
                      WarmTextButton(label: 'Try again', onTap: _reload),
                    ],
                  ),
                )
              else if (people == null)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Warm.ink),
                    ),
                  ),
                )
              else
                GroupCard(children: [
                  _AddRow(full: full, onTap: full ? null : _add),
                  for (final p in people)
                    _PersonRow(
                      key: ValueKey('manage-${p.id}'),
                      person: p,
                      onRemove: p.owner || p.self ? null : () => _remove(p),
                      onOpen: p.invited || p.self || widget.onOpen == null
                          ? null
                          : () => _open(p),
                    ),
                ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
                child: Text(AlbumCopy.manageNote, style: Warm.note),
              ),
              const SizedBox(height: 28),
              GroupCard(children: [
                _LinkRow(
                  key: const Key('settings-info'),
                  icon: Icons.info_outline_rounded,
                  title: AlbumCopy.albumInfo,
                  detail: AlbumCopy.infoDetail,
                  onTap: widget.onInfo,
                ),
              ]),
              const SizedBox(height: 12),
              GroupCard(children: [
                _LinkRow(
                  key: const Key('album-info-delete'),
                  icon: Icons.delete_outline_rounded,
                  title: AlbumCopy.deleteAlbum,
                  warn: true,
                  onTap: widget.onDelete,
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// The album's cover, large, with the way to change it on the photo itself
class _CoverHero extends StatelessWidget {
  final Widget? cover;
  final bool chosen;
  final VoidCallback? onChange;

  const _CoverHero(
      {required this.cover, required this.chosen, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Warm.wellEmpty),
            if (cover != null)
              cover!
            else
              const Center(
                child:
                    Icon(Icons.photo_outlined, size: 32, color: Warm.inkGhost),
              ),
            if (onChange != null)
              Positioned(
                right: 12,
                bottom: 12,
                child: Semantics(
                  button: true,
                  label: AlbumCopy.changeCover,
                  excludeSemantics: true,
                  child: PressableScale(
                    key: const Key('settings-cover'),
                    onTap: onChange!,
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.only(left: 12, right: 14),
                      decoration: BoxDecoration(
                        color: Warm.paper.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(17),
                        boxShadow: [
                          BoxShadow(
                              color: Warm.shadow(0.16),
                              blurRadius: 8,
                              offset: const Offset(0, 2)),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.photo_library_outlined,
                              size: 16, color: Warm.ink),
                          SizedBox(width: 6),
                          Text(
                            AlbumCopy.changeCover,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: Warm.ink),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 14,
              bottom: 14,
              child: Text(
                chosen ? AlbumCopy.coverChosen : AlbumCopy.coverNewest,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  shadows: [Shadow(color: Color(0x66000000), blurRadius: 6)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? detail;
  final bool warn;
  final VoidCallback onTap;

  const _LinkRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.detail,
    this.warn = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListRow(
      lead: ListRow.icon(icon, color: warn ? Warm.warn : Warm.inkSoft),
      title: title,
      detail: detail,
      titleColor: warn ? Warm.warn : Warm.ink,
      trailing: warn
          ? null
          : const Icon(Icons.chevron_right_rounded,
              size: 18, color: Warm.inkGhost),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }
}

// Every photo with a thumbnail, plus the newest photo as the default
class CoverPickerScreen extends StatelessWidget {
  final List<MediaRecord> photos;
  final String? current;
  final Widget Function(MediaRecord record) thumb;

  const CoverPickerScreen({
    super.key,
    required this.photos,
    required this.current,
    required this.thumb,
  });

  // Pops (id: chosen) or (id: null) for the newest; a plain back pops nothing
  static Future<({String? id})?> show(
    BuildContext context, {
    required List<MediaRecord> photos,
    required String? current,
    required Widget Function(MediaRecord record) thumb,
  }) =>
      Navigator.of(context).push(screenRoute<({String? id})>(
        CoverPickerScreen(photos: photos, current: current, thumb: thumb),
      ));

  @override
  Widget build(BuildContext context) {
    final withThumbs = photos.where((r) => r.hasThumb).toList();
    return Scaffold(
      backgroundColor: Warm.ground,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                  Warm.pagePad - 8, 16, Warm.pagePad - 8, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const WarmBack(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 22, 8, 6),
                      child: Text(AlbumCopy.chooseCover, style: Warm.pageTitle),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
                      child:
                          Text(AlbumCopy.chooseCoverLead, style: Warm.rowValue),
                    ),
                    GroupCard(children: [
                      _LinkRow(
                        key: const Key('cover-newest'),
                        icon: current == null
                            ? Icons.check_circle_rounded
                            : Icons.auto_awesome_outlined,
                        title: AlbumCopy.coverNewest,
                        detail: AlbumCopy.coverNewestDetail,
                        onTap: () => Navigator.of(context).pop((id: null)),
                      ),
                    ]),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 40),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                delegate: SliverChildBuilderDelegate(
                  childCount: withThumbs.length,
                  (context, i) {
                    final r = withThumbs[i];
                    final on = r.id == current;
                    return GestureDetector(
                      key: Key('cover-${r.id}'),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(context).pop((id: r.id));
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const ColoredBox(color: Warm.wellEmpty),
                          thumb(r),
                          if (on) ...[
                            DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: Warm.paper, width: 3),
                              ),
                            ),
                            const Positioned(
                              right: 8,
                              bottom: 8,
                              child: Icon(Icons.check_circle_rounded,
                                  size: 22, color: Warm.paper),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddRow extends StatelessWidget {
  final bool full;
  final VoidCallback? onTap;

  const _AddRow({required this.full, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListRow(
      key: const Key('manage-add'),
      lead: MakeButton(size: 40, onTap: onTap),
      title: AlbumCopy.addSomeone,
      detail: full ? AlbumCopy.addFull : AlbumCopy.addByIdShort,
      titleColor: full ? Warm.inkFaint : Warm.ink,
      semanticsLabel: full ? AlbumCopy.addFull : AlbumCopy.addSomeone,
      onTap: onTap,
    );
  }
}

class _PersonRow extends StatelessWidget {
  final ManagedPerson person;
  // Null for the owner and for yourself, who are never removed from here
  final VoidCallback? onRemove;
  final VoidCallback? onOpen;

  const _PersonRow(
      {super.key, required this.person, this.onRemove, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final p = person;
    final remove = onRemove;
    return ListRow(
      key: onOpen == null ? null : Key('manage-open-${p.id}'),
      lead: p.invited ? const DashedCircle(size: 40) : p.face,
      title: p.name,
      detail: p.invited
          ? AlbumCopy.invitedPending
          : p.owner
              ? (p.self ? AlbumCopy.ownerYou : AlbumCopy.madeThisAlbum)
              : (p.self ? AlbumCopy.you : null),
      trailing: remove == null
          ? null
          : _RemovePill(
              key: Key('manage-remove-${p.id}'),
              label: p.invited ? AlbumCopy.cancelShort : AlbumCopy.remove,
              semantics: p.invited
                  ? AlbumCopy.cancelInvite
                  : AlbumCopy.removeTitle(p.name),
              onTap: remove,
            ),
      onTap: onOpen,
    );
  }
}

class _RemovePill extends StatelessWidget {
  final String label;
  final String semantics;
  final VoidCallback onTap;

  const _RemovePill({
    super.key,
    required this.label,
    required this.semantics,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Warm.warn.withValues(alpha: 0.35)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Warm.warn,
            ),
          ),
        ),
      ),
    );
  }
}
