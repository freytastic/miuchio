import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/data/api/user_api.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/ui/album/leave_photos_choice.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/upload_copy.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:provider/provider.dart';

// One page a settings row opens: bare back, optional glyph, title, then content
class SettingsPage extends StatelessWidget {
  final String title;
  final IconData? glyph;
  final List<Widget> children;
  // Long content built lazily below the children
  final List<Widget> slivers;

  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.glyph,
    this.slivers = const [],
  });

  static const _physics =
      BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget build(BuildContext context) {
    final head = [
      const Align(alignment: Alignment.centerLeft, child: WarmBack()),
      Padding(
        padding: const EdgeInsets.only(left: 8, top: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (glyph != null) ...[
              Icon(glyph, size: 30, color: Warm.inkSoft),
              const SizedBox(height: 18),
            ],
            Text(title, style: Warm.pageTitle),
            ...children,
          ],
        ),
      ),
    ];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: slivers.isEmpty
              ? ListView(
                  physics: _physics,
                  padding: const EdgeInsets.fromLTRB(
                      Warm.pagePad - 8, 16, Warm.pagePad, 56),
                  children: head,
                )
              : CustomScrollView(
                  physics: _physics,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                          Warm.pagePad - 8, 16, Warm.pagePad, 0),
                      sliver: SliverList.list(children: head),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                          Warm.pagePad, 0, Warm.pagePad, 56),
                      sliver: SliverMainAxisGroup(slivers: slivers),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class SettingsLead extends StatelessWidget {
  final String text;

  const SettingsLead(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(text, style: Warm.pageLead),
      );
}

class SettingsSoft extends StatelessWidget {
  final String text;

  const SettingsSoft(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 26),
        child: Text(text, style: Warm.pageSoft),
      );
}

class SettingsFacts extends StatelessWidget {
  final List<(IconData, String)> facts;

  const SettingsFacts(this.facts, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        children: [
          for (final (icon, text) in facts)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(icon, size: 18, color: Warm.inkSoft),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Text(text, style: Warm.pageFact)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) => const SettingsPage(
        title: 'Notifications',
        glyph: Icons.notifications_none_rounded,
        children: [
          SettingsLead('For now, everything new shows up in Activity when you '
              'open Miuchio.'),
          SettingsLead('Notifications on your lock screen are coming soon.'),
        ],
      );
}

class BackupPage extends StatelessWidget {
  const BackupPage({super.key});

  @override
  Widget build(BuildContext context) => const SettingsPage(
        title: 'Backup',
        glyph: Icons.cloud_outlined,
        children: [
          SettingsLead('Not available yet.'),
          SettingsFacts([
            (
              Icons.lock_outline_rounded,
              'What unlocks your photos is kept only on this phone. Not even '
                  'Miuchio has a copy.'
            ),
            (
              Icons.smartphone_outlined,
              "If you uninstall Miuchio or lose this phone, you can't open "
                  'your albums again and will need to delete this account.'
            ),
            (
              Icons.people_outline_rounded,
              'To start over, make a new account and ask people to add you '
                  'again.'
            ),
          ]),
          SettingsSoft('Backup is coming soon.'),
        ],
      );
}

class LeavingPage extends StatefulWidget {
  const LeavingPage({super.key});

  @override
  State<LeavingPage> createState() => _LeavingPageState();
}

class _LeavingPageState extends State<LeavingPage> {
  bool _saving = false;

  Future<void> _set(bool delete) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final was = state.deleteMediaOnLeave;
    setState(() => _saving = true);
    state.setDeleteMediaOnLeave(delete);
    final saved = await UserService().setDeleteMediaOnLeave(delete);
    if (!saved) {
      state.setDeleteMediaOnLeave(was);
      messenger.showSnackBar(const SnackBar(
        content: Text("Couldn't save that. Try again."),
        behavior: SnackBarBehavior.floating,
      ));
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final delete = context.select<AppState, bool>((s) => s.deleteMediaOnLeave);
    return SettingsPage(
      title: 'When you leave',
      glyph: Icons.logout_rounded,
      children: [
        const SettingsLead('What happens to the photos you added when you '
            'leave an album or someone removes you.'),
        const SizedBox(height: 18),
        LeavePhotosChoice(delete: delete, onChanged: _saving ? null : _set),
        const SettingsSoft('You can still choose each time you leave. Deleting '
            "your account deletes your photos in albums you're still in."),
      ],
    );
  }
}

class StoragePage extends StatefulWidget {
  const StoragePage({super.key});

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  ({int thumbs, int full})? _usage;
  bool _clearing = false;

  MediaCacheManager? get _cache {
    try {
      return context.read<MediaCacheManager>();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final usage = await _cache?.usage();
    if (mounted) setState(() => _usage = usage);
  }

  Future<void> _clear() async {
    final cache = _cache;
    if (cache == null || _clearing) return;
    setState(() => _clearing = true);
    try {
      await cache.clearFullPhotos();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final u = _usage;
    final thumbs = u?.thumbs ?? 0;
    final full = u?.full ?? 0;
    final total = thumbs + full;
    return SettingsPage(
      title: 'Storage',
      children: [
        const SettingsLead('Photos saved on this phone'),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(u == null ? '…' : formatBytes(total),
              style: Warm.storageTotal),
        ),
        const SizedBox(height: 16),
        _Meter(thumbs: thumbs, full: full),
        const SizedBox(height: 14),
        _Line(label: 'Small previews', bytes: thumbs, dark: true),
        _Line(label: 'Full photos', bytes: full, dark: false),
        const SettingsSoft('Previews stay so albums open without internet. '
            'Full photos download again when you open them. Photos in your '
            "gallery aren't touched."),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: Transform.translate(
            offset: const Offset(-12, 0),
            child: WarmTextButton(
              label: 'Clear full photos',
              color: Warm.ink,
              onTap: full == 0 || _clearing ? null : _clear,
            ),
          ),
        ),
      ],
    );
  }
}

class _Meter extends StatelessWidget {
  final int thumbs;
  final int full;

  const _Meter({required this.thumbs, required this.full});

  @override
  Widget build(BuildContext context) {
    final total = thumbs + full;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: ColoredBox(
          color: const Color(0x0F1C1917),
          child: total == 0
              ? const SizedBox.expand()
              : Row(
                  children: [
                    if (thumbs > 0)
                      Expanded(
                          flex: thumbs,
                          child: const ColoredBox(color: Warm.cocoa)),
                    if (full > 0)
                      Expanded(
                          flex: full,
                          child: const ColoredBox(color: Warm.cocoaSoft)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final String label;
  final int bytes;
  final bool dark;

  const _Line({required this.label, required this.bytes, required this.dark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dark ? Warm.cocoa : Warm.cocoaSoft,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(child: Text(label, style: Warm.pageFact)),
          Text(formatBytes(bytes), style: Warm.rowValue),
        ],
      ),
    );
  }
}
