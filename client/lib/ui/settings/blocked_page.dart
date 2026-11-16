import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/api/safety_api.dart';
import 'package:miuchio/data/storage/safety_store.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/album/safety_copy.dart';
import 'package:miuchio/ui/settings/settings_page.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

// The server knows only that a block exists, so names come from this phone
// and a reinstall shows each one as someone
class BlockedPage extends StatefulWidget {
  const BlockedPage({super.key});

  @override
  State<BlockedPage> createState() => _BlockedPageState();
}

class _BlockedPageState extends State<BlockedPage> {
  // Unblock asks once in place: the first tap arms it, the second does it
  static const _armedFor = Duration(seconds: 3);

  List<BlockRecord>? _blocks;
  bool _failed = false;
  String? _armed;
  final Set<String> _leaving = {};
  Timer? _disarm;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disarm?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final blocks = await context.read<SafetyApi>().blocks();
      if (mounted) setState(() => _blocks = blocks);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _tap(BlockRecord b) {
    _disarm?.cancel();
    if (_armed == b.id) {
      setState(() => _armed = null);
      _unblock(b);
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _armed = b.id);
    _disarm = Timer(_armedFor, () {
      if (mounted) setState(() => _armed = null);
    });
  }

  Future<void> _unblock(BlockRecord b) async {
    final api = context.read<SafetyApi>();
    final store = context.read<SafetyStore>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _leaving.add(b.id));
    try {
      await api.unblock(b.id);
      await store.forgetBlock(b.id);
    } catch (_) {
      if (mounted) setState(() => _leaving.remove(b.id));
      messenger.showSnackBar(const SnackBar(
        content: Text(SafetyCopy.unblockFailed),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SafetyStore>();
    final blocks = _blocks;
    final left = blocks?.where((b) => !_leaving.contains(b.id)).length;
    return SettingsPage(
      title: SafetyCopy.blockedTitle,
      glyph: Icons.block_rounded,
      children: [
        const SettingsLead(SafetyCopy.blockedSubtitle),
        if (_failed)
          const SettingsSoft(SafetyCopy.blockedLoadFailed)
        else if (left == 0)
          const SettingsSoft(SafetyCopy.blockedEmpty),
        if (blocks != null && blocks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: Column(children: [
              for (final b in blocks)
                _BlockRow(
                  key: ValueKey(b.id),
                  name: store.blockedName(b.id) ?? SafetyCopy.blockedSomeone,
                  since: formatPhotoDay(b.createdAt),
                  armed: _armed == b.id,
                  gone: _leaving.contains(b.id),
                  onTap: () => _tap(b),
                ),
            ]),
          ),
      ],
    );
  }
}

class _BlockRow extends StatelessWidget {
  final String name;
  final String since;
  final bool armed;
  final bool gone;
  final VoidCallback onTap;

  const _BlockRow({
    super.key,
    required this.name,
    required this.since,
    required this.armed,
    required this.gone,
    required this.onTap,
  });

  static const _fold = Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
                color: Color(0x0F1C1917), shape: BoxShape.circle),
            child:
                const Icon(Icons.block_rounded, size: 18, color: Warm.inkFaint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Warm.rowTitle),
                const SizedBox(height: 1),
                Text(
                    armed
                        ? SafetyCopy.unblockBody
                        : SafetyCopy.blockedSince(since),
                    style: Warm.pageSoft.copyWith(fontSize: 12.5, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          PressableScale(
            onTap: gone ? null : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              constraints: const BoxConstraints(minWidth: 84),
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: armed ? Warm.cocoa : const Color(0x00000000),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: armed ? Warm.cocoa : Warm.inkGhost),
              ),
              child: Text(
                armed ? SafetyCopy.unblockArmed : SafetyCopy.unblock,
                style: Warm.rowValue.copyWith(
                    fontWeight: FontWeight.w500,
                    fontVariations: const [FontVariation('wght', 560)],
                    color: armed ? Warm.ctaInk : Warm.ink),
              ),
            ),
          ),
        ],
      ),
    );
    return AnimatedSize(
      duration: _fold,
      curve: Curves.fastOutSlowIn,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: _fold,
        opacity: gone ? 0 : 1,
        child: gone ? const SizedBox(width: double.infinity) : row,
      ),
    );
  }
}
