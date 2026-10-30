import 'package:flutter/material.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:miuchio/ui/widgets/warm_field.dart';

import 'album_copy.dart';
import 'album_stats.dart';
import 'leave_photos_choice.dart';

Future<T?> _paperSheet<T>(BuildContext context, WidgetBuilder builder) {
  // Keep sheets above the transparent peek route
  final navigator = Navigator.of(context, rootNavigator: true);
  final labels = MaterialLocalizations.of(context);
  return navigator.push(_PaperSheetRoute<T>(
    builder: builder,
    capturedThemes:
        InheritedTheme.capture(from: context, to: navigator.context),
    barrierLabel: labels.scrimLabel,
    barrierOnTapHint: labels.scrimOnTapHint(labels.bottomSheetLabel),
    backgroundColor: Warm.paper,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
  ));
}

class _PaperSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _PaperSheetRoute({
    required super.builder,
    required super.capturedThemes,
    required super.barrierLabel,
    required super.barrierOnTapHint,
    required super.backgroundColor,
    required super.isScrollControlled,
    required super.shape,
  });

  double _dragFrom = 0;

  void _close() {
    if (isCurrent) navigator?.pop();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      NotificationListener<OverscrollNotification>(
        onNotification: (n) {
          if (n.overscroll < 0 && n.dragDetails != null) _close();
          return false;
        },
        child: super.buildPage(context, animation, secondaryAnimation),
      );

  @override
  Widget buildModalBarrier() => GestureDetector(
        onVerticalDragStart: (d) => _dragFrom = d.globalPosition.dy,
        onVerticalDragEnd: (d) {
          if (d.globalPosition.dy - _dragFrom > 24 ||
              (d.primaryVelocity ?? 0) > 300) {
            _close();
          }
        },
        child: super.buildModalBarrier(),
      );
}

Future<bool> confirmPhotoDelete(BuildContext context) => confirmSheet(
      context,
      key: 'photo-delete',
      title: AlbumCopy.deleteTitle,
      body: AlbumCopy.deleteBody,
      confirm: AlbumCopy.deleteForEveryone,
      cancel: AlbumCopy.deleteCancel,
    );

Future<bool> confirmSheet(
  BuildContext context, {
  required String key,
  required String title,
  required String body,
  required String confirm,
  required String cancel,
}) async =>
    await _paperSheet<bool>(
      context,
      (_) => _ConfirmSheet(
        keyPrefix: key,
        title: title,
        body: body,
        confirm: confirm,
        cancel: cancel,
      ),
    ) ??
    false;

// Null when they stay, otherwise whether to delete the photos they added
Future<bool?> confirmLeave(BuildContext context, {required bool deletePhotos}) =>
    _paperSheet<bool>(
        context, (_) => _LeaveSheet(deletePhotos: deletePhotos));

enum PersonAction { photos, safetyNumber, remove }

// Null when dismissed. Remove is left out for anyone who can't use it, while
// a safety number not yet available stays visible but greyed
Future<PersonAction?> showPersonSheet(
  BuildContext context, {
  required Widget face,
  required String? name,
  required bool owner,
  required bool canVerify,
  required bool canRemove,
}) =>
    _paperSheet<PersonAction>(
      context,
      (_) => _PersonSheet(
        face: face,
        name: name,
        owner: owner,
        canVerify: canVerify,
        canRemove: canRemove,
      ),
    );

// Trimmed new name, or null when dismissed or unchanged
Future<String?> askAlbumName(BuildContext context, String current) =>
    _paperSheet<String>(context, (_) => _RenameSheet(current: current));

Future<void> showPhotoDetails(
  BuildContext context, {
  required MediaRecord record,
  required Widget face,
  required String? name,
  required bool mine,
  DateTime? now,
}) =>
    _paperSheet<void>(
      context,
      (_) => _DetailsSheet(
        record: record,
        face: face,
        name: name,
        mine: mine,
        now: now,
      ),
    );

String formatPhotoDay(DateTime at, {DateTime? now}) {
  // Server times parse as UTC, so a late night upload read in UTC days
  // lands on the previous calendar day
  final local = at.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(local.year, local.month, local.day))
      .inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  if (days < 365 && local.year == today.year) {
    return '${local.day} ${months[local.month - 1]}';
  }
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

class _Grab extends StatelessWidget {
  const _Grab();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Warm.inkGhost,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _ConfirmSheet extends StatelessWidget {
  final String keyPrefix;
  final String title;
  final String body;
  final String confirm;
  final String cancel;

  const _ConfirmSheet({
    required this.keyPrefix,
    required this.title,
    required this.body,
    required this.confirm,
    required this.cancel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grab(),
            const SizedBox(height: 20),
            Text(title, style: Warm.cardTitle),
            const SizedBox(height: 6),
            Text(body, style: Warm.note),
            const SizedBox(height: 22),
            WarmButton(
              key: Key('$keyPrefix-confirm'),
              label: confirm,
              onTap: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 6),
            PressableScale(
              key: Key('$keyPrefix-keep'),
              onTap: () => Navigator.of(context).pop(false),
              child: SizedBox(
                height: 46,
                child: Center(
                  child: Text(cancel,
                      style: Warm.acBtnQuiet.copyWith(fontSize: 15)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeaveSheet extends StatefulWidget {
  final bool deletePhotos;

  const _LeaveSheet({required this.deletePhotos});

  @override
  State<_LeaveSheet> createState() => _LeaveSheetState();
}

class _LeaveSheetState extends State<_LeaveSheet> {
  late bool _delete = widget.deletePhotos;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grab(),
            const SizedBox(height: 20),
            Text(AlbumCopy.leaveTitle, style: Warm.cardTitle),
            const SizedBox(height: 6),
            Text(AlbumCopy.leaveBody, style: Warm.note),
            const SizedBox(height: 18),
            Text(AlbumCopy.leavePhotos, style: Warm.pageSubhead),
            const SizedBox(height: 4),
            LeavePhotosChoice(
              delete: _delete,
              onChanged: (v) => setState(() => _delete = v),
            ),
            const SizedBox(height: 18),
            WarmButton(
              key: const Key('album-leave-confirm'),
              label: AlbumCopy.leaveAlbum,
              onTap: () => Navigator.of(context).pop(_delete),
            ),
            const SizedBox(height: 6),
            PressableScale(
              key: const Key('album-leave-keep'),
              onTap: () => Navigator.of(context).pop(),
              child: SizedBox(
                height: 46,
                child: Center(
                  child: Text(AlbumCopy.leaveCancel,
                      style: Warm.acBtnQuiet.copyWith(fontSize: 15)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonSheet extends StatelessWidget {
  final Widget face;
  final String? name;
  final bool owner;
  final bool canVerify;
  final bool canRemove;

  const _PersonSheet({
    required this.face,
    required this.name,
    required this.owner,
    required this.canVerify,
    required this.canRemove,
  });

  @override
  Widget build(BuildContext context) {
    void pick(PersonAction a) => Navigator.of(context).pop(a);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grab(),
            const SizedBox(height: 20),
            Row(
              children: [
                face,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name ?? AlbumCopy.unknownMember,
                          style: Warm.cardTitle,
                          overflow: TextOverflow.ellipsis),
                      if (owner) ...[
                        const SizedBox(height: 2),
                        Text(AlbumCopy.madeThisAlbum, style: Warm.meta),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const _Rule(),
            _PersonRow(
              key: const Key('person-photos'),
              label: AlbumCopy.onlyTheirPhotos(name),
              onTap: () => pick(PersonAction.photos),
            ),
            _PersonRow(
              key: const Key('person-safety'),
              label: AlbumCopy.safetyNumber,
              onTap: canVerify ? () => pick(PersonAction.safetyNumber) : null,
            ),
            if (canRemove) ...[
              const _Rule(),
              _PersonRow(
                key: const Key('person-remove'),
                label: AlbumCopy.removeFromAlbum,
                danger: true,
                onTap: () => pick(PersonAction.remove),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: Warm.inkGhost);
}

class _PersonRow extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  const _PersonRow({
    super.key,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? Warm.inkFaint
        : danger
            ? Warm.warn
            : Warm.ink;
    return PressableScale(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: Warm.rowTitle.copyWith(color: color),
                  overflow: TextOverflow.ellipsis),
            ),
            if (!danger)
              Icon(Icons.chevron_right_rounded, size: 20, color: color),
          ],
        ),
      ),
    );
  }
}

class _RenameSheet extends StatefulWidget {
  final String current;

  const _RenameSheet({required this.current});

  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final TextEditingController _name = TextEditingController(
      text: widget.current)
    ..selection =
        TextSelection(baseOffset: 0, extentOffset: widget.current.length);

  String get _next => _name.text.trim();
  bool get _changed => _next.isNotEmpty && _next != widget.current.trim();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (_changed) Navigator.of(context).pop(_next);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Grab(),
              const SizedBox(height: 20),
              Text(AlbumCopy.renameAlbum, style: Warm.cardTitle),
              const SizedBox(height: 16),
              WarmField(
                key: const Key('rename-field'),
                controller: _name,
                label: AlbumCopy.renameHint,
                maxLength: AlbumCopy.nameMax,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 18),
              WarmButton(
                key: const Key('rename-save'),
                label: AlbumCopy.renameSave,
                onTap: _changed ? _save : null,
              ),
              const SizedBox(height: 6),
              PressableScale(
                onTap: () => Navigator.of(context).pop(),
                child: SizedBox(
                  height: 46,
                  child: Center(
                    child: Text(AlbumCopy.renameCancel,
                        style: Warm.acBtnQuiet.copyWith(fontSize: 15)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailsSheet extends StatelessWidget {
  final MediaRecord record;
  final Widget face;
  final String? name;
  final bool mine;
  final DateTime? now;

  const _DetailsSheet({
    required this.record,
    required this.face,
    required this.name,
    required this.mine,
    this.now,
  });

  static String formatOf(MediaRecord record) {
    final mime = record.mimeType;
    if (mime == null || !mime.contains('/')) {
      return record.mediaType == 'video' ? 'Video' : 'Photo';
    }
    final sub = mime.split('/').last.toUpperCase();
    return sub == 'JPG' ? 'JPEG' : sub;
  }

  @override
  Widget build(BuildContext context) {
    final day = formatPhotoDay(record.createdAt, now: now);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: ListView(
          key: const Key('photo-details'),
          primary: false,
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
          children: [
            const _Grab(),
            const SizedBox(height: 18),
            Row(
              children: [
                face,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AlbumCopy.sharedBy(name, mine: mine),
                          style: Warm.factTitle),
                      Text(day, style: Warm.meta),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              decoration: BoxDecoration(
                color: Warm.wellEmpty.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
              ),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(
                      child: _Fact(
                        label: AlbumCopy.factSize,
                        value: AlbumStats.formatBytes(
                            AlbumStats.storedBytes(record)),
                      ),
                    ),
                    const VerticalDivider(width: 1, color: Warm.inkGhost),
                    Expanded(
                      child: _Fact(
                          label: AlbumCopy.factFormat, value: formatOf(record)),
                    ),
                    const VerticalDivider(width: 1, color: Warm.inkGhost),
                    Expanded(
                      child: _Fact(label: AlbumCopy.factAdded, value: day),
                    ),
                  ],
                ),
              ),
            ),
            if (record.mediaType == 'photo') ...[
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(Icons.lock_outline_rounded,
                        size: 14, color: Warm.inkFaint),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(AlbumCopy.privateNote,
                        style: Warm.note),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: Warm.sectionLabel),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Warm.rowTitle.copyWith(
                fontSize: 13.5,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}
