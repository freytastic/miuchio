import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

// Bottom actions shared by the photo peek and the full screen viewer

class PeekDock extends StatelessWidget {
  final bool owner;
  final VoidCallback onDelete;
  // Null where the details already show, as in the peek
  final VoidCallback? onDetails;

  const PeekDock({
    super.key,
    required this.owner,
    required this.onDelete,
    this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    final details = onDetails;
    if (details == null && !owner) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (details != null)
          PeekRoundButton(
            key: const Key('photo-peek-details'),
            label: AlbumCopy.details,
            icon: Icons.info_outline_rounded,
            onTap: details,
          ),
        if (details != null && owner) const SizedBox(width: 56),
        if (owner)
          PeekRoundButton(
            key: const Key('photo-peek-delete'),
            label: AlbumCopy.delete,
            icon: Icons.delete_outline_rounded,
            quiet: true,
            onTap: onDelete,
          ),
      ],
    );
  }
}

class PeekRoundButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool quiet;
  final VoidCallback onTap;

  const PeekRoundButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.quiet = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: quiet ? const Color(0x14FFFFFF) : Warm.glassFill,
            shape: BoxShape.circle,
            border: Border.all(color: Warm.glassHairline),
          ),
          child: Icon(icon,
              size: 21,
              color: quiet ? const Color(0x9EFFFFFF) : const Color(0xD9FFFFFF)),
        ),
      ),
    );
  }
}
