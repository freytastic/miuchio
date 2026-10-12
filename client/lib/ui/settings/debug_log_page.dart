import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'package:miuchio/diagnostics/debug_log.dart';
import 'package:miuchio/diagnostics/debug_log_export.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/settings/debug_log_copy.dart';
import 'package:miuchio/ui/settings/settings_page.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

const String _mono = 'monospace';

class DebugLogPage extends StatefulWidget {
  const DebugLogPage({super.key});

  @override
  State<DebugLogPage> createState() => _DebugLogPageState();
}

class _DebugLogPageState extends State<DebugLogPage> {
  bool _problemsOnly = false;
  final Set<DebugEntry> _open = Set.identity();

  @override
  void initState() {
    super.initState();
    DebugLog.changes.addListener(_changed);
  }

  @override
  void dispose() {
    DebugLog.changes.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _clear() async {
    final ok = await confirmSheet(
      context,
      key: 'debug-log-clear',
      title: DebugLogCopy.clearTitle,
      body: DebugLogCopy.clearBody,
      confirm: DebugLogCopy.clear,
      cancel: DebugLogCopy.clearCancel,
    );
    if (!ok) return;
    _open.clear();
    await DebugLog.clear();
  }

  void _review() => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DebugLogPreviewPage(entries: DebugLog.entries)));

  @override
  Widget build(BuildContext context) {
    final all = DebugLog.entries;
    final now = DateTime.now();
    // Day labels and entries in display order, newest first
    final items = <Object>[];
    String? day;
    for (final e in all.reversed) {
      if (_problemsOnly && e.level == DebugLevel.info) continue;
      final d = _dayLabel(context, e.last, now);
      if (d != day) items.add(day = d);
      items.add(e);
    }

    return SettingsPage(
      title: DebugLogCopy.title,
      glyph: Icons.receipt_long_outlined,
      slivers: [
        if (items.isEmpty)
          SliverToBoxAdapter(
            child: SettingsSoft(_problemsOnly && all.isNotEmpty
                ? DebugLogCopy.problemsEmpty
                : DebugLogCopy.empty),
          )
        else
          SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              if (item is String) {
                return Padding(
                  padding: const EdgeInsets.only(top: 22, bottom: 4),
                  child: Text(item.toUpperCase(), style: Warm.sectionLabel),
                );
              }
              final e = item as DebugEntry;
              return _EntryRow(
                entry: e,
                open: _open.contains(e),
                onTap: () => setState(
                    () => _open.contains(e) ? _open.remove(e) : _open.add(e)),
              );
            },
          ),
        const SliverToBoxAdapter(child: SettingsSoft(DebugLogCopy.limits)),
      ],
      children: [
        const SettingsLead(DebugLogCopy.lead),
        const SizedBox(height: 22),
        Row(
          children: [
            WarmButton(
              label: DebugLogCopy.shareLog,
              small: true,
              onTap: all.isEmpty ? null : _review,
            ),
            const SizedBox(width: 4),
            WarmTextButton(
              label: DebugLogCopy.clear,
              onTap: all.isEmpty ? null : _clear,
            ),
          ],
        ),
        const SizedBox(height: 6),
        const _SendSoon(),
        const SizedBox(height: 18),
        _Filter(
          problemsOnly: _problemsOnly,
          onChanged: (v) => setState(() => _problemsOnly = v),
        ),
      ],
    );
  }
}

String _dayLabel(BuildContext context, DateTime t, DateTime now) {
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return MaterialLocalizations.of(context).formatShortMonthDay(t);
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _EntryRow extends StatelessWidget {
  final DebugEntry entry;
  final bool open;
  final VoidCallback onTap;

  const _EntryRow({
    required this.entry,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final cause = DebugLogCopy.cause(e);
    final when = e.count > 1
        ? '${_clock(e.first)} to ${_clock(e.last)} · '
            '${DebugLogCopy.times(e.count)}'
        : _clock(e.first);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: _LevelMark(e.level),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(DebugLogCopy.headline(e),
                      style: Warm.pageFact.copyWith(
                          color: e.level == DebugLevel.info
                              ? Warm.inkSoft
                              : Warm.ink)),
                  if (cause != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(cause, style: Warm.meta),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(when,
                        style: Warm.meta.copyWith(color: Warm.inkFaint)),
                  ),
                  if (open)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Warm.paper,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Warm.inkGhost),
                      ),
                      child: SelectableText(
                        debugLine(e),
                        style: const TextStyle(
                            fontFamily: _mono,
                            fontSize: 11.5,
                            height: 1.4,
                            color: Warm.inkSoft),
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

class _LevelMark extends StatelessWidget {
  final DebugLevel level;

  const _LevelMark(this.level);

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (level) {
      DebugLevel.info => (
          Icons.radio_button_unchecked_rounded,
          Warm.inkFaint,
          'Info'
        ),
      DebugLevel.warn => (Icons.error_outline_rounded, Warm.cocoa, 'Warning'),
      DebugLevel.error => (Icons.error_rounded, Warm.warn, 'Error'),
    };
    return Semantics(
      label: label,
      child: Icon(icon, size: 18, color: color),
    );
  }
}

class _Filter extends StatelessWidget {
  final bool problemsOnly;
  final ValueChanged<bool> onChanged;

  const _Filter({required this.problemsOnly, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, bool selected, bool value) => Semantics(
          button: true,
          selected: selected,
          child: GestureDetector(
            onTap: () {
              if (selected) return;
              HapticFeedback.selectionClick();
              onChanged(value);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: selected ? Warm.ink : const Color(0x00000000),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: selected ? Warm.ink : Warm.inkGhost, width: 1),
              ),
              child: Text(label,
                  style: Warm.meta
                      .copyWith(color: selected ? Warm.ctaInk : Warm.inkSoft)),
            ),
          ),
        );
    return Row(
      children: [
        pill(DebugLogCopy.all, !problemsOnly, false),
        const SizedBox(width: 8),
        pill(DebugLogCopy.problems, problemsOnly, true),
      ],
    );
  }
}

class _SendSoon extends StatelessWidget {
  const _SendSoon();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          Text(DebugLogCopy.send,
              style: Warm.textAction.copyWith(color: Warm.inkFaint)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Warm.inkGhost),
            ),
            child: Text(DebugLogCopy.soon,
                style: Warm.meta.copyWith(color: Warm.inkFaint, fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

// Shows the exact export text before Copy or Share hands it to anything else
class DebugLogPreviewPage extends StatefulWidget {
  final List<DebugEntry> entries;

  const DebugLogPreviewPage({super.key, required this.entries});

  @override
  State<DebugLogPreviewPage> createState() => _DebugLogPreviewPageState();
}

class _DebugLogPreviewPageState extends State<DebugLogPreviewPage> {
  String? _text;

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    final device = await DeviceSummary.load();
    if (!mounted) return;
    setState(() => _text =
        buildDebugLogExport(widget.entries, device, now: DateTime.now()));
  }

  Future<void> _copy() async {
    final text = _text;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
      content: Text(DebugLogCopy.copied),
      duration: Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _share(BuildContext anchor) async {
    final text = _text;
    if (text == null) return;
    // iPad anchors the share popover to the button
    final box = anchor.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(ShareParams(
        text: text,
        subject: DebugLogCopy.shareSubject,
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return SettingsPage(
      title: DebugLogCopy.previewTitle,
      children: [
        const SettingsLead(DebugLogCopy.previewLead),
        const SettingsFacts([
          (Icons.lock_outline_rounded, DebugLogCopy.previewNoContent),
          (Icons.schedule_rounded, DebugLogCopy.previewIncludes),
        ]),
        Row(
          children: [
            Builder(
              builder: (anchor) => WarmButton(
                label: DebugLogCopy.share,
                small: true,
                onTap: text == null ? null : () => _share(anchor),
              ),
            ),
            const SizedBox(width: 4),
            WarmTextButton(
              label: DebugLogCopy.copy,
              color: Warm.ink,
              onTap: text == null ? null : _copy,
            ),
          ],
        ),
        Container(
          margin: const EdgeInsets.only(top: 18),
          padding: const EdgeInsets.all(12),
          width: double.infinity,
          decoration: BoxDecoration(
            color: Warm.paper,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Warm.inkGhost),
          ),
          child: text == null
              ? const SizedBox(height: 40)
              : SelectableText(
                  text,
                  style: const TextStyle(
                      fontFamily: _mono,
                      fontSize: 11,
                      height: 1.45,
                      color: Warm.ink),
                ),
        ),
      ],
    );
  }
}
