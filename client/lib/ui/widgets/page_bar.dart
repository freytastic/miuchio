import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

// The back button pinned at the top of a page, which gains a ground and a
// title once the heading has scrolled `after` pixels away
class PageBar extends StatefulWidget {
  final ScrollController scroll;
  final double after;
  final Widget title;
  final double pad;
  final Key? backKey;

  const PageBar({
    super.key,
    required this.scroll,
    required this.after,
    required this.title,
    this.pad = Warm.pagePad - 8,
    this.backKey,
  });

  @override
  State<PageBar> createState() => _PageBarState();
}

class _PageBarState extends State<PageBar> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(PageBar old) {
    super.didUpdateWidget(old);
    if (old.scroll == widget.scroll) return;
    old.scroll.removeListener(_scrolled);
    widget.scroll.addListener(_scrolled);
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_scrolled);
    super.dispose();
  }

  // Rebuilds only when the bar flips, not on every scrolled pixel
  void _scrolled() {
    final on = widget.scroll.offset > widget.after;
    if (on != _on) setState(() => _on = on);
  }

  @override
  Widget build(BuildContext context) {
    return PinnedHeaderSliver(
      child: AnimatedContainer(
        duration: Warm.quick,
        height: Warm.pageBarHeight,
        color: _on ? Warm.barGround : Warm.ground.withValues(alpha: 0),
        padding: EdgeInsets.only(left: widget.pad, top: 12, right: widget.pad),
        child: Row(
          children: [
            // A full size tap target around the smaller chevron
            SizedBox(
              key: widget.backKey,
              width: 48,
              height: 48,
              child: const Align(
                  alignment: Alignment.centerLeft, child: WarmBack()),
            ),
            Expanded(
              child: AnimatedOpacity(
                duration: Warm.quick,
                opacity: _on ? 1 : 0,
                child: ExcludeSemantics(
                  excluding: !_on,
                  child: DefaultTextStyle(
                    style: Warm.pageBarTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: widget.title,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// A section label that sticks under the PageBar while its rows pass
class PinnedLabel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const PinnedLabel({super.key, required this.child, required this.padding});

  @override
  Widget build(BuildContext context) => PinnedHeaderSliver(
        child: ColoredBox(
          color: Warm.barGround,
          child: Padding(padding: padding, child: child),
        ),
      );
}
