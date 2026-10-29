import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

import 'activity_copy.dart';

class ActivityCard extends StatelessWidget {
  final CardCopy copy;
  final bool alarm;
  final Widget? face;
  final VoidCallback onGo;
  final VoidCallback onQuiet;

  const ActivityCard({
    super.key,
    required this.copy,
    required this.alarm,
    this.face,
    required this.onGo,
    required this.onQuiet,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _face,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Stack(
          children: [
            const LitEdge(),
            if (alarm)
              const Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: ColoredBox(color: Warm.warn),
              ),
            Padding(
              // Button tap padding adds 5 px to the bottom gap
              padding: EdgeInsets.fromLTRB(alarm ? 20 : 17, 16, 17, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (face != null) ...[
                        face!,
                        const SizedBox(width: 11),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(copy.title, style: Warm.acCardTitle),
                            const SizedBox(height: 2),
                            Text(copy.where, style: Warm.acWhere),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(copy.body, style: Warm.acCardBody),
                  // Button tap padding adds 5 px to this gap
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      _Btn(label: copy.go, primary: true, onTap: onGo),
                      if (copy.quiet != null) ...[
                        const SizedBox(width: 8),
                        _Btn(
                            label: copy.quiet!, primary: false, onTap: onQuiet),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

BoxDecoration get _face => BoxDecoration(
      borderRadius: BorderRadius.circular(17),
      gradient: Warm.acStoneFill,
      boxShadow: [
        BoxShadow(
            color: Warm.shadow(0.06),
            blurRadius: 2,
            offset: const Offset(0, 1)),
        BoxShadow(
            color: Warm.shadow(0.06),
            blurRadius: 16,
            offset: const Offset(0, 6)),
        BoxShadow(
            color: Warm.shadow(0.05),
            blurRadius: 34,
            offset: const Offset(0, 14)),
      ],
    );

// Albums you were added to, laid out as prints from the shelf. Tapping one
// opens it; a single dismiss clears the lot, since they arrive together
class SharedAlbumsCard extends StatelessWidget {
  final List<({String albumId, String title})> albums;
  final String when;
  // The album's latest photo, or null while it is still decrypting
  final Widget? Function(String albumId)? cover;
  final void Function(String albumId) onOpen;
  final VoidCallback onDismiss;

  const SharedAlbumsCard({
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
    return DecoratedBox(
      decoration: _face,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Stack(
          children: [
            const LitEdge(),
            Padding(
              padding: const EdgeInsets.fromLTRB(17, 14, 4, 18),
              child: Column(
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
                      IconButton(
                        tooltip: 'Dismiss',
                        onPressed: onDismiss,
                        icon: const Icon(Icons.close_rounded,
                            size: 19, color: Warm.inkFaint),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 146,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      padding: const EdgeInsets.only(top: 4, right: 13),
                      itemCount: n,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (_, i) => _Print(
                        title: albums[i].title,
                        image: cover?.call(albums[i].albumId),
                        // A loose hand-laid tilt, alternating like the shelf
                        tilt: i.isEven ? -0.03 : 0.022,
                        onTap: () => onOpen(albums[i].albumId),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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

  static const double _size = 104;

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
          width: _size,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Transform.rotate(
                angle: tilt,
                child: Container(
                  width: _size,
                  height: _size,
                  padding: const EdgeInsets.all(5),
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

// Simulates the inset highlight Flutter's shadows cannot express
class LitEdge extends StatelessWidget {
  const LitEdge({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: 1,
      child: ColoredBox(color: Color(0xE6FFFFFF)),
    );
  }
}

class _Btn extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback onTap;
  const _Btn({required this.label, required this.primary, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Keep a 48 px touch target around the 40 px button
    return SizedBox(
      key: ValueKey('card-$label'),
      height: 48,
      child: Center(
        child: primary
            ? WarmButton(label: label, small: true, onTap: onTap)
            : WarmTextButton(label: label, onTap: onTap),
      ),
    );
  }
}
