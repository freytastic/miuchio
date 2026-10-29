import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:miuchio/ui/theme/warm_tokens.dart';

// Albums you were added to, laid out as prints from the shelf. Tapping one
// opens it; a single dismiss clears the lot, since they arrive together.
// No card around it: the prints running off the screen's edge are what say
// the row scrolls
class SharedAlbums extends StatelessWidget {
  final List<({String albumId, String title})> albums;
  final String when;
  // The album's latest photo, or null while it is still decrypting
  final Widget? Function(String albumId)? cover;
  final void Function(String albumId) onOpen;
  final VoidCallback onDismiss;

  const SharedAlbums({
    super.key,
    required this.albums,
    required this.when,
    this.cover,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final n = albums.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Shared with you', style: Warm.acCardTitle),
                  const SizedBox(height: 2),
                  Text('$n album${n == 1 ? '' : 's'} · $when',
                      style: Warm.acWhere),
                ],
              ),
            ),
            // Line the glyph up with the page margin, not its tap target
            Transform.translate(
              offset: const Offset(12, 0),
              child: IconButton(
                tooltip: 'Dismiss',
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded,
                    size: 19, color: Warm.inkFaint),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _Bleed(
          child: SizedBox(
            height: _Print.size + 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              // The first print starts on the text margin
              padding:
                  const EdgeInsets.fromLTRB(Warm.pagePad, 4, Warm.pagePad, 0),
              itemCount: n,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (_, i) => _Print(
                title: albums[i].title,
                image: cover?.call(albums[i].albumId),
                // A loose hand-laid tilt, alternating like the shelf
                tilt: i.isEven ? -0.03 : 0.022,
                onTap: () => onOpen(albums[i].albumId),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Undoes the page margin so the row runs edge to edge
class _Bleed extends StatelessWidget {
  final Widget child;
  const _Bleed({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => OverflowBox(
        minWidth: c.maxWidth + 2 * Warm.pagePad,
        maxWidth: c.maxWidth + 2 * Warm.pagePad,
        fit: OverflowBoxFit.deferToChild,
        child: child,
      ),
    );
  }
}

class _Print extends StatelessWidget {
  final String title;
  final Widget? image;
  final double tilt;
  final VoidCallback onTap;

  const _Print({
    required this.title,
    required this.image,
    required this.tilt,
    required this.onTap,
  });

  static const double size = 126;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open $title',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Transform.rotate(
                angle: tilt,
                child: Container(
                  width: size,
                  height: size,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Warm.paper,
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: [
                      BoxShadow(
                          color: Warm.shadow(0.12),
                          blurRadius: 3,
                          offset: const Offset(0, 1)),
                      BoxShadow(
                          color: Warm.shadow(0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 5)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(1.5),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(
                          color: Warm.wellEmpty,
                          child: Center(
                            child: Icon(Icons.photo_outlined,
                                size: 22, color: Warm.inkGhost),
                          ),
                        ),
                        if (image != null) image!,
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 11),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Warm.acLine.copyWith(color: Warm.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
