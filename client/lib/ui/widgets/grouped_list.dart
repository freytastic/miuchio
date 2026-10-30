import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// The pieces of a settings style page: a small caps label over a soft card
// of rows, each row a 40 point lead, a title, an optional detail line and
// an optional control on the right

const double _leadBox = 40;
const double _leadGap = 14;
const double _rowPadLeft = 16;

class SectionLabel extends StatelessWidget {
  final String text;
  final String? trailing;

  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(child: Text(text.toUpperCase(), style: Warm.sectionLabel)),
          if (trailing != null)
            Text(trailing!, style: Warm.rowValue.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}

// One soft card, divided by hairlines that start after the leads
class GroupCard extends StatelessWidget {
  final List<Widget> children;

  const GroupCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Warm.groundLift,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.only(left: _rowPadLeft + _leadBox + _leadGap),
                child: Divider(height: 1, thickness: 1, color: Warm.inkGhost),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class ListRow extends StatelessWidget {
  final Widget lead;
  final String title;
  final String? detail;
  final Color titleColor;
  // A control of its own, such as a remove pill, keeps its own semantics
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? semanticsLabel;
  final bool? selected;

  const ListRow({
    super.key,
    required this.lead,
    required this.title,
    this.detail,
    this.titleColor = Warm.ink,
    this.trailing,
    this.onTap,
    this.semanticsLabel,
    this.selected,
  });

  // An icon lead, sized to line up with faces in the same card
  static Widget icon(IconData icon, {Color color = Warm.inkSoft}) =>
      Center(child: Icon(icon, size: 20, color: color));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_rowPadLeft, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: onTap != null,
                selected: selected,
                label: semanticsLabel ?? title,
                excludeSemantics: true,
                child: Row(
                  children: [
                    SizedBox.square(dimension: _leadBox, child: lead),
                    const SizedBox(width: _leadGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  Warm.rowTitle.copyWith(color: titleColor)),
                          if (detail != null) ...[
                            const SizedBox(height: 1),
                            Text(detail!,
                                style: Warm.rowValue
                                    .copyWith(color: Warm.inkFaint)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
