import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

const double kRowPad = 16;
const double kRowLead = 24;
const double kRowGap = 14;

class GroupCard extends StatelessWidget {
  final List<Widget> children;

  const GroupCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Warm.groundLift,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.only(left: kRowPad + kRowLead + kRowGap),
                child: Divider(height: 1, thickness: 0.5, color: Warm.inkGhost),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class SettingsRow extends StatelessWidget {
  final Widget? lead;
  final String title;
  final String? value;
  final bool warn;
  // Leaves the app, so it points out instead of on
  final bool external;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SettingsRow({
    super.key,
    required this.title,
    this.lead,
    this.value,
    this.warn = false,
    this.external = false,
    this.trailing,
    this.onTap,
  });

  static Widget icon(IconData icon, {bool warn = false}) =>
      Icon(icon, size: 20, color: warn ? Warm.warn : Warm.inkSoft);

  @override
  Widget build(BuildContext context) {
    final end = trailing ??
        (external
            ? const Icon(Icons.north_east_rounded,
                size: 14, color: Warm.inkGhost)
            : onTap != null
                ? const Icon(Icons.chevron_right_rounded,
                    size: 17, color: Warm.inkGhost)
                : null);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kRowPad, 0, 12, 0),
          child: Row(
            children: [
              if (lead != null) ...[
                SizedBox(width: kRowLead, child: Center(child: lead)),
                const SizedBox(width: kRowGap),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: warn
                      ? Warm.rowTitle.copyWith(color: Warm.warn)
                      : Warm.rowTitle,
                ),
              ),
              if (value != null) ...[
                Text(value!,
                    style: Warm.rowValue.copyWith(color: Warm.inkFaint)),
                const SizedBox(width: 10),
              ],
              if (end != null) end,
            ],
          ),
        ),
      ),
    );
  }
}
