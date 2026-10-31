import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/storage/own_avatar_store.dart';
import 'package:miuchio/domain/avatar/avatar_publisher.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/member_face.dart';

enum HomeTab { home, albums, notifications, you }

// The home screen's bottom bar: two tabs either side of the make button, so
// the most used action sits where both thumbs reach and the tabs balance
class TabDock extends StatelessWidget {
  final HomeTab current;
  final ValueChanged<HomeTab> onSelect;
  final VoidCallback onMake;

  const TabDock({
    super.key,
    required this.current,
    required this.onSelect,
    required this.onMake,
  });

  // Centers MakeSpot on the bar: 8 + (64 - 52) / 2 == MakeSpot.lift
  static const double _bar = 64;
  // Room left between the tabs for MakeSpot
  static const double _makeSlot = 76;
  // Room above the bar for content to fade before it meets the icons
  static const double _fade = 32;

  // Height above the bottom inset, which pages keep clear of their content
  static const double height = _fade + _bar + 8;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final unread = context.select((AppState s) => s.hasUnreadNotifications);

    Widget tab(HomeTab t, String label, Widget Function(bool on) icon) =>
        Expanded(
          child: _Tab(
            label: label,
            on: current == t,
            icon: icon(current == t),
            onTap: () => onSelect(t),
          ),
        );

    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        const Positioned.fill(child: FootScrim(height: double.infinity)),
        Padding(
          padding: EdgeInsets.fromLTRB(8, _fade, 8, 8 + bottom),
          child: SizedBox(
            height: _bar,
            child: Row(
              children: [
                tab(
                    HomeTab.home,
                    'Home',
                    (on) =>
                        _glyph(on, Icons.home_rounded, Icons.home_outlined)),
                tab(
                    HomeTab.albums,
                    'Albums',
                    (on) => _glyph(on, Icons.photo_library_rounded,
                        Icons.photo_library_outlined)),
                const SizedBox(width: _makeSlot),
                tab(
                    HomeTab.notifications,
                    unread ? 'Notifications, new' : 'Notifications',
                    (on) => _Dot(
                          show: unread,
                          child: _glyph(on, Icons.notifications_rounded,
                              Icons.notifications_none_rounded),
                        )),
                tab(HomeTab.you, 'You', (on) => _Me(on: on)),
              ],
            ),
          ),
        ),
        MakeSpot(
            onTap: onMake,
            tooltip: 'Add',
            hint: 'Add photos or start an album'),
      ],
    );
  }

  static Widget _glyph(bool on, IconData filled, IconData outline) => Icon(
        on ? filled : outline,
        size: 26,
        color: on ? Warm.ink : Warm.inkSoft,
      );
}

class _Tab extends StatelessWidget {
  final String label;
  final bool on;
  final Widget icon;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.on,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: on,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!on) HapticFeedback.selectionClick();
          onTap();
        },
        // Icons only, so the make button stays the bar's one label-free
        // focal point. The name is still read out by screen readers. The
        // selected tab is marked twice, filled and with a dot beneath, so it
        // never relies on color alone
        child: SizedBox(
          height: TabDock._bar,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 9),
              SizedBox(height: 28, child: Center(child: icon)),
              const SizedBox(height: 5),
              AnimatedOpacity(
                opacity: on ? 1 : 0,
                duration: Warm.quick,
                child: const SizedBox.square(
                  dimension: 4,
                  child: DecoratedBox(
                    decoration:
                        BoxDecoration(color: Warm.ink, shape: BoxShape.circle),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Something new waits on the notifications tab
class _Dot extends StatelessWidget {
  final bool show;
  final Widget child;

  const _Dot({required this.show, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (show)
          const Positioned(
            key: ValueKey('unread-notifications'),
            top: 1,
            right: 1,
            child: SizedBox.square(
              dimension: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Warm.warn,
                  shape: BoxShape.circle,
                  border: Border.fromBorderSide(
                      BorderSide(color: Warm.ground, width: 1.5)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// Your own face is the tab for your profile and settings
class _Me extends StatelessWidget {
  final bool on;

  const _Me({required this.on});

  @override
  Widget build(BuildContext context) {
    final name = context.select((AppState s) => s.profileName).trim();
    final photo = context.select<OwnAvatarStore?, Uint8List?>(
        (o) => o?.state == OwnAvatarState.set ? o?.jpeg : null);
    return FaceCircle(
      size: 28,
      color: photo == null ? faceHue('', name) : Colors.transparent,
      photo: photo,
      border: Border.all(
        color: on ? Warm.ink : Colors.transparent,
        width: 1.6,
      ),
      child: Text(
        name.isEmpty ? '' : name[0].toUpperCase(),
        style: Warm.avatarInitial.copyWith(fontSize: 11),
      ),
    );
  }
}
