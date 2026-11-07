import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/api/safety_api.dart';
import 'package:miuchio/data/storage/safety_store.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/album/safety_copy.dart';
import 'package:miuchio/ui/settings/settings_page.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/grouped_list.dart';

// The server knows only that a block exists, so names come from this phone
// and a reinstall shows each one as someone
class BlockedPage extends StatefulWidget {
  const BlockedPage({super.key});

  @override
  State<BlockedPage> createState() => _BlockedPageState();
}

class _BlockedPageState extends State<BlockedPage> {
  List<BlockRecord>? _blocks;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final blocks = await context.read<SafetyApi>().blocks();
      if (mounted) setState(() => _blocks = blocks);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _unblock(BlockRecord b, String? name) async {
    final api = context.read<SafetyApi>();
    final store = context.read<SafetyStore>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await confirmSheet(
      context,
      key: 'unblock',
      title: SafetyCopy.unblockTitle(name),
      body: SafetyCopy.unblockBody,
      confirm: SafetyCopy.unblock,
      cancel: SafetyCopy.cancel,
    )) {
      return;
    }
    try {
      await api.unblock(b.id);
      await store.forgetBlock(b.id);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text(SafetyCopy.unblockFailed),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    if (mounted) setState(() => _blocks?.remove(b));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SafetyStore>();
    final blocks = _blocks;
    return SettingsPage(
      title: SafetyCopy.blockedTitle,
      glyph: Icons.block_rounded,
      children: [
        const SettingsLead(SafetyCopy.blockedSubtitle),
        if (_failed)
          const SettingsSoft(SafetyCopy.blockedLoadFailed)
        else if (blocks != null && blocks.isEmpty)
          const SettingsSoft(SafetyCopy.blockedEmpty)
        else if (blocks != null)
          Padding(
            padding: const EdgeInsets.only(top: 28),
            child: GroupCard(children: [
              for (final b in blocks)
                SettingsRow(
                  key: ValueKey(b.id),
                  title: store.blockedName(b.id) ?? SafetyCopy.blockedSomeone,
                  value: formatPhotoDay(b.createdAt),
                  trailing: Text(SafetyCopy.unblock,
                      style: Warm.rowValue.copyWith(color: Warm.warn)),
                  onTap: () => _unblock(b, store.blockedName(b.id)),
                ),
            ]),
          ),
      ],
    );
  }
}
