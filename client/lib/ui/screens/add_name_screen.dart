import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/e2ee/display_name.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:miuchio/ui/widgets/warm_field.dart';

// Onboarding's name step. Albums created or joined later carry the name on
// their own; albums this account already had are told here
class AddNameScreen extends StatefulWidget {
  final VoidCallback onDone;

  const AddNameScreen({super.key, required this.onDone});

  @override
  State<AddNameScreen> createState() => _AddNameScreenState();
}

class _AddNameScreenState extends State<AddNameScreen> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _clean => _name.text.trim();

  void _save() {
    final name = _clean;
    if (name.isEmpty) return;
    final state = context.read<AppState>();
    state.setProfileName(name);
    final targets = <NameTarget>[];
    for (final a in state.albums) {
      final tok = a.memberToken;
      if (tok == null) continue;
      try {
        targets.add((
          albumId: a.id,
          memberToken: base64.decode(base64.normalize(tok)),
        ));
      } catch (_) {}
    }
    final publisher = context.read<DisplayNamePublisher?>();
    if (targets.isNotEmpty) {
      unawaited(publisher?.publishToAll(targets, name));
    }
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    // Inside the safe area the keyboard only needs to clear what is left
    // of it. While it slides away it can be shorter than the inset, so the
    // gap is clamped rather than ever going negative
    final keyboard = math.max(
        0.0,
        MediaQuery.viewInsetsOf(context).bottom -
            MediaQuery.paddingOf(context).bottom);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Warm.pagePad),
            child: Column(
              children: [
                const Spacer(flex: 2),
                Text('What should people call you?',
                    textAlign: TextAlign.center, style: Warm.h1),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: Warm.leadMaxWidth),
                  child: const Text(
                    'Only the people in your albums can see it.',
                    textAlign: TextAlign.center,
                    style: Warm.lead,
                  ),
                ),
                const SizedBox(height: 36),
                WarmField(
                  controller: _name,
                  label: 'Your name',
                  maxLength: 28,
                  autofocus: true,
                  autofillHints: const [AutofillHints.name],
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _save(),
                ),
                const Spacer(flex: 3),
                WarmButton(
                  label: 'Continue',
                  onTap: _clean.isEmpty ? null : _save,
                ),
                SizedBox(
                    height: keyboard > 0
                        ? keyboard + 12
                        : MediaQuery.sizeOf(context).height *
                            Warm.ctaBottomInset),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
