import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/storage/own_avatar_store.dart';
import 'package:miuchio/domain/avatar/avatar_publisher.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/member_face.dart';

enum HomeTab { albums, people, notifications, you }

// The home screen's bottom bar: four destinations either side of the make
// button, all within reach of a thumb
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

  // Height above the bottom inset, which pages keep clear of their content
  static const double height = 96;

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
        const FootScrim(height: 150),
        Padding(
          padding: EdgeInsets.fromLTRB(10, 0, 10, 12 + bottom),
          child: SizedBox(
            height: height - 12,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                tab(
                    HomeTab.albums,
                    'Albums',
                    (on) => _glyph(on, Icons.photo_library_rounded,
                        Icons.photo_library_outlined)),
                tab(
                    HomeTab.people,
                    'People',
                    (on) => _glyph(on, Icons.people_alt_rounded,
                        Icons.people_alt_outlined)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 14),
                  child: MakeButton(onTap: onMake, tooltip: 'Add'),
                ),
                tab(
                    HomeTab.notifications,
                    'Notifications',
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
      ],
    );
  }

  static Widget _glyph(bool on, IconData filled, IconData outline) => Icon(
        on ? filled : outline,
        size: 25,
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
        child: SizedBox(
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(height: 28, child: Center(child: icon)),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                style: Warm.tab.copyWith(
                  fontSize: 11,
                  color: on ? Warm.ink : Warm.inkSoft,
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
      size: 26,
      color: photo == null ? Warm.orbPeach : Colors.transparent,
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
