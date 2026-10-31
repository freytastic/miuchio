import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

import 'album_copy.dart';

class AlbumFoot extends StatelessWidget {
  final VoidCallback? onAdd;

  final Widget? pill;

  // Keeps content above the actions
  static const clearance = 136.0;

  const AlbumFoot({
    super.key,
    required this.onAdd,
    this.pill,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          FootScrim(height: clearance + bottom),
          Padding(
            padding: EdgeInsets.only(left: 44, right: 44, bottom: 18 + bottom),
            child: Center(
              child: MakeButton(onTap: onAdd, tooltip: AlbumCopy.addPhotos),
            ),
          ),
          if (pill != null)
            Positioned(
              right: 16,
              bottom: 96 + bottom,
              child: pill!,
            ),
        ],
      ),
    );
  }
}

// Replaces the foot while photos are being picked
class SelectFoot extends StatelessWidget {
  final int count;
  final int mine;
  final VoidCallback onDelete;
  final VoidCallback onDownload;

  const SelectFoot({
    super.key,
    required this.count,
    required this.mine,
    required this.onDelete,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          FootScrim(height: AlbumFoot.clearance + bottom),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 18 + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: WarmButton(
                        key: const Key('select-delete'),
                        label: AlbumCopy.deleteSelected(count, mine),
                        small: true,
                        onTap: mine == 0 ? null : onDelete,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: _SoonPill(onTap: onDownload)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SoonPill extends StatelessWidget {
  final VoidCallback onTap;

  const _SoonPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      key: const Key('select-download'),
      onTap: onTap,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Warm.wellEmpty,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(AlbumCopy.download,
                style: Warm.acBtnQuiet.copyWith(color: Warm.inkFaint)),
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Warm.ground,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                AlbumCopy.laterBadge,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: Warm.inkFaint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
