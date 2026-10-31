import 'package:flutter/material.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/create/glass_sheet.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:miuchio/ui/widgets/warm_field.dart';

import 'album_copy.dart';
import 'album_stats.dart';
import 'leave_photos_choice.dart';

Future<T?> _paperSheet<T>(BuildContext context, WidgetBuilder builder,
    {Color background = Warm.paper}) {
  // Keep sheets above the transparent peek route
  final navigator = Navigator.of(context, rootNavigator: true);
  final labels = MaterialLocalizations.of(context);
  return navigator.push(_PaperSheetRoute<T>(
    builder: builder,
    capturedThemes:
        InheritedTheme.capture(from: context, to: navigator.context),
    barrierLabel: labels.scrimLabel,
    barrierOnTapHint: labels.scrimOnTapHint(labels.bottomSheetLabel),
    backgroundColor: background,
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

class SheetChoice<T> {
  final T value;
  final IconData icon;
  final String title;
  final String? detail;

  const SheetChoice(this.value, this.icon, this.title, {this.detail});
}

// Null when dismissed
Future<T?> askChoice<T>(
  BuildContext context, {
  String? title,
  required List<SheetChoice<T>> choices,
}) =>
    _paperSheet<T>(
        context, (_) => _ChoiceSheet<T>(title: title, choices: choices));

// Trimmed new name, or null when dismissed or unchanged
Future<String?> askAlbumName(BuildContext context, String current) =>
    _paperSheet<String>(context, (_) => _RenameSheet(current: current));

// Glass over the photo, which stays in view behind it
Future<void> showPhotoDetails(
  BuildContext context, {
  required MediaRecord record,
  required Widget face,
  required String? name,
  required bool mine,
  required String position,
  DateTime? now,
}) =>
    _paperSheet<void>(
      context,
      (_) => _DetailsSheet(
        record: record,
        face: face,
        name: name,
        mine: mine,
        position: position,
        now: now,
      ),
      background: Colors.transparent,
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

class _ChoiceSheet<T> extends StatelessWidget {
  final String? title;
  final List<SheetChoice<T>> choices;

  const _ChoiceSheet({required this.title, required this.choices});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grab(),
            if (title != null) ...[
              const SizedBox(height: 18),
              Text(title!, style: Warm.cardTitle),
            ],
            const SizedBox(height: 10),
            for (var i = 0; i < choices.length; i++) ...[
              if (i > 0) const _Rule(),
              _ChoiceRow(
                choice: choices[i],
                onTap: () => Navigator.of(context).pop(choices[i].value),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  final SheetChoice<Object?> choice;
  final VoidCallback onTap;

  const _ChoiceRow({required this.choice, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final detail = choice.detail;
    return Semantics(
      button: true,
      label: choice.title,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: Warm.wellEmpty,
                  shape: BoxShape.circle,
                ),
                child: Icon(choice.icon, size: 20, color: Warm.ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(choice.title, style: Warm.rowTitle),
                    if (detail != null) ...[
                      const SizedBox(height: 2),
                      Text(detail, style: Warm.meta),
                    ],
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
  final String position;
  final DateTime? now;

  const _DetailsSheet({
    required this.record,
    required this.face,
    required this.name,
    required this.mine,
    required this.position,
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
    final who = mine ? AlbumCopy.you : name ?? AlbumCopy.unknownMember;
    return GlassPanel(
      key: const Key('photo-details'),
      radius: const BorderRadius.vertical(top: Radius.circular(22)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Warm.glassHairlineStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  face,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          who,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Warm.glassInk,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          formatPhotoDay(record.createdAt, now: now),
                          style: const TextStyle(
                              fontSize: 13, color: Warm.glassInkSoft),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Row(
                children: [
                  _Fact(value: formatOf(record), label: AlbumCopy.factFormat),
                  _Fact(
                    value: AlbumStats.formatBytes(
                        AlbumStats.storedBytes(record)),
                    label: AlbumCopy.factSize,
                  ),
                  _Fact(value: position, label: AlbumCopy.factPlace),
                ],
              ),
              if (record.mediaType == 'photo') ...[
                const SizedBox(height: 24),
                const Text(
                  AlbumCopy.privateNote,
                  style: TextStyle(
                      fontSize: 13, height: 1.4, color: Warm.glassInkSoft),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String value;
  final String label;

  const _Fact({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              color: Warm.glassInk,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 12, color: Warm.glassInkFaint)),
        ],
      ),
    );
  }
}
