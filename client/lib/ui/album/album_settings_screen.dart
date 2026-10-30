import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

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

// The owner's view of who is in an album: everyone with the action that
// applies to them in plain sight, rather than behind each person's sheet
class ManagePeopleScreen extends StatefulWidget {
  final String albumTitle;
  final Future<List<ManagedPerson>> Function() load;
  final Future<void> Function() onAdd;
  // Confirms first; the list reloads after it returns either way
  final Future<void> Function(ManagedPerson person) onRemove;

  // Matches the server's cap on members per album
  static const capacity = 10;

  const ManagePeopleScreen({
    super.key,
    required this.albumTitle,
    required this.load,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<ManagePeopleScreen> createState() => _ManagePeopleScreenState();
}

class _ManagePeopleScreenState extends State<ManagePeopleScreen> {
  List<ManagedPerson>? _people;
  bool _failed = false;

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

  Future<void> _remove(ManagedPerson p) async {
    HapticFeedback.selectionClick();
    await widget.onRemove(p);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final count = people?.length ?? 0;
    final full = count >= ManagePeopleScreen.capacity;
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AlbumCopy.editPeople, style: Warm.pageTitle),
                    const SizedBox(height: 6),
                    Text(
                      people == null
                          ? widget.albumTitle
                          : '${widget.albumTitle} · '
                              '${AlbumCopy.peopleOf(count, ManagePeopleScreen.capacity)}',
                      style: Warm.rowValue,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
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
                _Card(children: [
                  _AddRow(full: full, onTap: full ? null : _add),
                  for (final p in people)
                    _PersonRow(
                      key: ValueKey('manage-${p.id}'),
                      person: p,
                      onRemove: p.owner || p.self ? null : () => _remove(p),
                    ),
                ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
                child: Text(AlbumCopy.manageNote, style: Warm.note),
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

class _AddRow extends StatelessWidget {
  final bool full;
  final VoidCallback? onTap;

  const _AddRow({required this.full, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: full ? AlbumCopy.addFull : AlbumCopy.addSomeone,
      excludeSemantics: true,
      child: GestureDetector(
        key: const Key('manage-add'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              MakeButton(size: 40, onTap: onTap),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AlbumCopy.addSomeone,
                        style: Warm.rowTitle
                            .copyWith(color: full ? Warm.inkFaint : Warm.ink)),
                    const SizedBox(height: 1),
                    Text(
                      full ? AlbumCopy.addFull : AlbumCopy.addByIdShort,
                      style: Warm.rowValue.copyWith(color: Warm.inkFaint),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  final ManagedPerson person;
  // Null for the owner and for yourself, who are never removed from here
  final VoidCallback? onRemove;

  const _PersonRow({super.key, required this.person, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final p = person;
    final status = p.invited
        ? AlbumCopy.invitedPending
        : p.owner
            ? (p.self ? AlbumCopy.ownerYou : AlbumCopy.madeThisAlbum)
            : (p.self ? AlbumCopy.you : null);
    final remove = onRemove;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 40,
            child: p.invited ? const DashedCircle(size: 40) : p.face,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Warm.rowTitle),
                if (status != null) ...[
                  const SizedBox(height: 1),
                  Text(status,
                      style: Warm.rowValue.copyWith(color: Warm.inkFaint)),
                ],
              ],
            ),
          ),
          if (remove != null)
            _RemovePill(
              key: Key('manage-remove-${p.id}'),
              label: p.invited ? AlbumCopy.cancelShort : AlbumCopy.remove,
              semantics: p.invited
                  ? AlbumCopy.cancelInvite
                  : AlbumCopy.removeTitle(p.name),
              onTap: remove,
            ),
        ],
      ),
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
