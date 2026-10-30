import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

// Bottom actions shared by the photo peek and the full screen viewer

class PeekDock extends StatelessWidget {
  final bool owner;
  final VoidCallback onHeart;
  final VoidCallback onDelete;
  // Null where the details already show, as in the peek
  final VoidCallback? onDetails;

  const PeekDock({
    super.key,
    required this.owner,
    required this.onHeart,
    required this.onDelete,
    this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    final details = onDetails;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        PeekRoundButton(
          key: const Key('photo-peek-heart'),
          label: AlbumCopy.heart,
          icon: Icons.favorite_border_rounded,
          onTap: onHeart,
        ),
        if (details != null)
          PeekRoundButton(
            key: const Key('photo-peek-details'),
            label: AlbumCopy.details,
            icon: Icons.info_outline_rounded,
            onTap: details,
          ),
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

class PeekNote extends StatelessWidget {
  final String text;

  const PeekNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xE62A2622),
        borderRadius: BorderRadius.circular(18),
      ),
      // The note sits outside the peek's Material and needs its own text style
      child: Material(
        type: MaterialType.transparency,
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
