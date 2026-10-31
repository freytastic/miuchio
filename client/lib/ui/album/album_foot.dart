import 'package:flutter/material.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

import 'album_copy.dart';

// The add button takes the shared MakeSpot, so it is where Home keeps its
// own. Everything else lives in the album's action row
class AlbumFoot extends StatelessWidget {
  final VoidCallback? onAdd;

  final Widget? pill;

  // Keeps content above the add button
  static const clearance = 104.0;

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
      child: SizedBox(
        height: clearance + bottom,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            MakeSpot(onTap: onAdd, tooltip: AlbumCopy.addPhotos),
            if (pill != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: bottom + MakeSpot.top + 12,
                child: Center(child: pill!),
              ),
          ],
        ),
      ),
    );
  }
}

// Replaces the add button while photos are being picked
class SelectFoot extends StatelessWidget {
  final int count;
  final int mine;
  final VoidCallback onDelete;

  const SelectFoot({
    super.key,
    required this.count,
    required this.mine,
    required this.onDelete,
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
            child: WarmButton(
              key: const Key('select-delete'),
              label: AlbumCopy.deleteSelected(count, mine),
              small: true,
              onTap: mine == 0 ? null : onDelete,
            ),
          ),
        ],
      ),
    );
  }
}
