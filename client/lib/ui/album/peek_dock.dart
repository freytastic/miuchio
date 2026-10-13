import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

// Bottom actions shared by the photo peek and the full screen viewer

class PeekDock extends StatelessWidget {
  final bool owner;
  final VoidCallback onHeart;
  final VoidCallback onSave;
  final VoidCallback onDelete;

  const PeekDock({
    super.key,
    required this.owner,
    required this.onHeart,
    required this.onSave,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Row(
        children: [
          PeekRoundButton(
            key: const Key('photo-peek-heart'),
            label: AlbumCopy.heart,
            icon: Icons.favorite_border_rounded,
            onTap: onHeart,
          ),
          const SizedBox(width: 10),
          Expanded(child: _SaveStone(onTap: onSave)),
          if (owner) ...[
            const SizedBox(width: 10),
            PeekRoundButton(
              key: const Key('photo-peek-delete'),
              label: AlbumCopy.delete,
              icon: Icons.delete_outline_rounded,
              quiet: true,
              onTap: onDelete,
            ),
          ],
        ],
      ),
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

class _SaveStone extends StatelessWidget {
  final VoidCallback onTap;

  const _SaveStone({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          gradient: Warm.stoneFill,
          borderRadius: BorderRadius.circular(25),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              offset: Offset(0, 6),
              blurRadius: 18,
            ),
          ],
        ),
        child: const FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_rounded, size: 18, color: Warm.ink),
              SizedBox(width: 8),
              Text(
                AlbumCopy.saveToPhone,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: Warm.ink,
                ),
              ),
              SizedBox(width: 8),
              _StoneChip(),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoneChip extends StatelessWidget {
  const _StoneChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Warm.inkGhost,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        AlbumCopy.laterBadge,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: Warm.inkSoft,
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
