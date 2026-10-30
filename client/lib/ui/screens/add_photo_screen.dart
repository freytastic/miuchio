import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/data/storage/own_avatar_store.dart';
import 'package:miuchio/domain/avatar/avatar_publisher.dart';
import 'package:miuchio/e2ee/avatar_image.dart';
import 'package:miuchio/ui/shelf/avatar_pick.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/profile_face.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

// The last step of onboarding. Choosing a photo is optional: whoever skips
// still gets a quiet generic picture, never a bare letter
class AddPhotoScreen extends StatefulWidget {
  final VoidCallback onDone;
  // Test seams; the app picks from the gallery and draws a generic picture
  final Future<Uint8List?> Function(BuildContext context)? pick;
  final Future<Uint8List> Function(int seed)? generic;

  const AddPhotoScreen({
    super.key,
    required this.onDone,
    this.pick,
    this.generic,
  });

  @override
  State<AddPhotoScreen> createState() => _AddPhotoScreenState();
}

class _AddPhotoScreenState extends State<AddPhotoScreen> {
  // Drawn while the screen is up, so skipping never waits on it
  late final Future<Uint8List> _generic =
      (widget.generic ?? AvatarImage.generic)(math.Random().nextInt(1 << 16));
  Uint8List? _preview;
  Uint8List? _chosen;
  bool _preparing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _generic.then((g) {
      if (mounted) setState(() => _preview = g);
    }).catchError((_) {});
  }

  Future<void> _choose() async {
    if (_preparing || _saving) return;
    final jpeg = widget.pick != null
        ? await widget.pick!(context)
        : await pickAvatarPhoto(context, onPreparing: (busy) {
            if (mounted) setState(() => _preparing = busy);
          });
    if (jpeg == null || !mounted) return;
    HapticFeedback.lightImpact();
    setState(() => _chosen = jpeg);
  }

  Future<void> _finish({required bool skipped}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final own = context.read<OwnAvatarStore?>();
      final publisher = context.read<AvatarPublisher?>();
      final jpeg = skipped ? await _generic : _chosen;
      if (own != null && jpeg != null) {
        await own.set(jpeg);
        unawaited(publisher?.sync());
      }
    } catch (_) {
      // A missing picture never blocks getting into the app
    }
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final chosen = _chosen;
    final face = chosen ?? _preview;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Warm.pagePad),
            child: Column(
              children: [
                const Spacer(flex: 2),
                Text('Add a profile photo',
                    textAlign: TextAlign.center, style: Warm.h1),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: Warm.leadMaxWidth),
                  child: const Text(
                    'It’s how the people in your albums will see you.',
                    textAlign: TextAlign.center,
                    style: Warm.lead,
                  ),
                ),
                const SizedBox(height: 40),
                Semantics(
                  button: true,
                  label: chosen == null ? 'Choose a photo' : 'Choose another',
                  child: GestureDetector(
                    onTap: _choose,
                    child: ProfileFace(photo: face, busy: _preparing),
                  ),
                ),
                const Spacer(flex: 3),
                WarmButton(
                  label: chosen == null ? 'Choose a photo' : 'Continue',
                  busy: _saving && chosen != null,
                  onTap:
                      chosen == null ? _choose : () => _finish(skipped: false),
                ),
                const SizedBox(height: 6),
                WarmTextButton(
                  label: chosen == null ? 'Not now' : 'Choose another',
                  onTap: _saving
                      ? null
                      : chosen == null
                          ? () => _finish(skipped: true)
                          : _choose,
                ),
                SizedBox(
                    height: MediaQuery.sizeOf(context).height *
                        Warm.ctaBottomInset),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
