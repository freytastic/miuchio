import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

import 'album_copy.dart';

// Keep or delete the photos someone added, picked when leaving and in settings
class LeavePhotosChoice extends StatelessWidget {
  final bool delete;
  final ValueChanged<bool>? onChanged;

  const LeavePhotosChoice({
    super.key,
    required this.delete,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Option(
          key: const Key('leave-photos-keep'),
          title: AlbumCopy.keepPhotos,
          note: AlbumCopy.keepPhotosNote,
          on: !delete,
          onTap: onChanged == null ? null : () => onChanged!(false),
        ),
        _Option(
          key: const Key('leave-photos-delete'),
          title: AlbumCopy.deletePhotos,
          note: AlbumCopy.deletePhotosNote,
          on: delete,
          onTap: onChanged == null ? null : () => onChanged!(true),
        ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  final String title;
  final String note;
  final bool on;
  final VoidCallback? onTap;

  const _Option({
    super.key,
    required this.title,
    required this.note,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: on,
      enabled: onTap != null,
      label: title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null || on
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Warm.rowTitle),
                    const SizedBox(height: 3),
                    Text(note, style: Warm.pageSoft),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              AnimatedContainer(
                duration: Warm.quick,
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? Warm.cocoa : Colors.transparent,
                  border:
                      on ? null : Border.all(color: Warm.inkGhost, width: 1.6),
                ),
                child: on
                    ? const Icon(Icons.check_rounded,
                        size: 15, color: Warm.ground)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
