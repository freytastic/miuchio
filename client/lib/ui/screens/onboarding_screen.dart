import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/app/sign_in_flow.dart';
import 'package:miuchio/data/api/auth_api.dart';
import 'package:miuchio/data/storage/own_avatar_store.dart';
import 'package:miuchio/data/storage/storage_service.dart';
import 'package:miuchio/domain/avatar/avatar_publisher.dart'
    show OwnAvatarState;
import 'package:miuchio/domain/account/account_deletion.dart' show TerminalWipe;
import 'package:miuchio/domain/account/account_gate.dart';
import 'package:miuchio/ui/screens/account_conflict_screens.dart';
import 'package:miuchio/ui/screens/add_name_screen.dart';
import 'package:miuchio/ui/screens/add_photo_screen.dart';
import 'package:miuchio/ui/screens/erase_installation_flow.dart';
import 'package:miuchio/ui/screens/start_deletion_flow.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/ui/screens/main_shell.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/camera_stage.dart';
import 'package:miuchio/ui/widgets/caret_blink.dart';
import 'package:miuchio/ui/widgets/hello_wordmark.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:miuchio/ui/widgets/warm_field.dart';

part 'onboarding_parts.dart';

const int _kOtpLength = 6;
final RegExp _kEmailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

// Air above the headline that keeps the hero and copy in place
const double _kCopyLead = 34;
const double _kCompactCopyLead = 26;
const double _kCompactEmailCopyBox = 64;
const double _kCompactOtpCopyBox = 88;
const double _kCompactFootExtent = 148;
const double _kCompactContentGap = 8;
const double _kCopyBox = 168;
const double _kDotsExtent = 6;
const double _kDotsGap = 22;
// Space kept between the last line of copy and the dots
const double _kFootClearance = 16;

const String _kIntroLead =
    'Shared photo albums for the people who were actually there.';
const String _kEmailLead = 'We’ll send a one-time sign-in code to your email.';
const String _kPreviewEmail = 'your.name@example.com';

InlineSpan _otpLead(String email) => TextSpan(
      style: Warm.lead,
      children: [
        const TextSpan(text: 'Enter the 6-digit code we sent to '),
        TextSpan(text: email, style: const TextStyle(color: Warm.ink)),
        const TextSpan(text: '.'),
      ],
    );

enum _Phase { intro, email, otp, done }

class OnboardingScreen extends StatefulWidget {
  // Lays out every phase without contacting the server
  final bool preview;

  const OnboardingScreen({super.key, this.preview = false});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _emailCtrl = _EmailEditingController();
  final _otpCtrl = TextEditingController();
  final _emailFocus = FocusNode();
  final _otpFocus = FocusNode();

  _Phase _phase = _Phase.intro;
  bool _busy = false;
  // The wordmark writes with the camera clip, not with the screen
  final _wordCue = WordmarkCue();

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_onFieldChanged);
    _otpCtrl.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _emailCtrl.removeListener(_onFieldChanged);
    _otpCtrl.removeListener(_onFieldChanged);
    _emailCtrl.dispose();
    _otpCtrl.dispose();
    _emailFocus.dispose();
    _otpFocus.dispose();
    _wordCue.dispose();
    super.dispose();
  }

  void _onFieldChanged() => setState(() {});

  String get _email => widget.preview && _emailCtrl.text.trim().isEmpty
      ? _kPreviewEmail
      : _emailCtrl.text.trim();
  String get _code => _otpCtrl.text;

  bool get _ready => widget.preview || switch (_phase) {
        _Phase.intro => true,
        _Phase.email => _kEmailRe.hasMatch(_email),
        _Phase.otp => _code.length == _kOtpLength,
        _Phase.done => false,
      };

  String get _ctaLabel => switch (_phase) {
        _Phase.intro => 'Continue',
        _Phase.email => 'Send code',
        _ => 'Verify',
      };

  Future<void> _advance() async {
    if (!_ready || _busy) return;
    if (widget.preview) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _phase = switch (_phase) {
            _Phase.intro => _Phase.email,
            _Phase.email => _Phase.otp,
            _ => _Phase.intro,
          });
      return;
    }
    switch (_phase) {
      case _Phase.intro:
        // Avoid opening the keyboard during the phase transition
        setState(() => _phase = _Phase.email);
      case _Phase.email:
        await _sendCode();
      case _Phase.otp:
        await _verify();
      case _Phase.done:
        break;
    }
  }

  Future<void> _sendCode() async {
    setState(() => _busy = true);
    try {
      final sent = await AuthService().requestOtp(_email);
      if (!mounted) return;
      if (!sent) {
        setState(() => _busy = false);
        _showError('We could not send a code to that address.');
        return;
      }
      setState(() {
        _phase = _Phase.otp;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Connection error. Check your network and try again.');
    }
  }

  Future<void> _verify() async {
    final identity = context.read<IdentityService>();
    final flow = SignInFlow.of(context);
    setState(() => _busy = true);
    // Let the pressed state paint before the request starts
    await WidgetsBinding.instance.endOfFrame;

    try {
      final result = await flow.verify(_email, _code);
      if (!mounted) return;
      switch (result) {
        case SignInWrongCode():
          _otpCtrl.clear();
          setState(() => _busy = false);
          _otpFocus.requestFocus();
          HapticFeedback.vibrate();
          _showError('That code did not match. Try again.');
          return;
        case SignInRefused(:final outcome):
          setState(() => _busy = false);
          switch (outcome) {
            case AccountGateOutcome.lostDevice:
              _showKeysLost();
            case AccountGateOutcome.blockedDifferentAccount:
            case AccountGateOutcome.unclaimedVault:
              _showBelongsToAnother();
            case AccountGateOutcome.connectionRequired:
              _showError('Couldn’t connect. Try again when you’re online.');
            case AccountGateOutcome.proceed:
            case AccountGateOutcome.adoptUnbound:
            case AccountGateOutcome.newAccount:
              break;
          }
          return;
        case SignInDone():
          break;
      }

      final messenger = ScaffoldMessenger.of(context);
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        _phase = _Phase.done;
        _busy = false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      if (!mounted) return;
      await _setUpProfile();
      // Keep keystore work off the sign in transition
      unawaited(_bootstrapInBackground(identity, messenger));
    } on AccountDeletingException {
      if (!mounted) return;
      _otpCtrl.clear();
      setState(() => _busy = false);
      _showError('This account is still being deleted. Try again later.');
    } on TooManyAttemptsException {
      if (!mounted) return;
      _otpCtrl.clear();
      setState(() => _busy = false);
      _showError('Too many tries. Wait a few minutes and try again.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError('Sign-in failed. Please try again.');
    }
  }

  Future<void> _bootstrapInBackground(
      IdentityService identity, ScaffoldMessengerState messenger) async {
    try {
      await bootstrapIdentity(identity);
    } on BootstrapAccountConflictException {
      messenger.showSnackBar(const SnackBar(
        content: Text(
          'This account’s photos only open on the phone it was set up on.',
        ),
        duration: Duration(seconds: 6),
      ));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Something went wrong. Close Miuchio and open it again.'),
        duration: Duration(seconds: 5),
      ));
    }
  }

  void _goHome() {
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (_, __, ___) => const MainShell(),
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOutQuad),
          child: child,
        ),
      ),
      (_) => false,
    );
  }

  // Asks only for what this phone does not have yet, name before photo, so
  // someone signing back in goes straight in
  Future<void> _setUpProfile() async {
    final needsName = await StorageService().getName() == null;
    if (!mounted) return;
    final needsPhoto =
        context.read<OwnAvatarStore?>()?.state != OwnAvatarState.set;
    final steps = <Widget Function(VoidCallback next)>[
      if (needsName) (next) => AddNameScreen(onDone: next),
      if (needsPhoto) (next) => AddPhotoScreen(onDone: next),
    ];
    void show(int i) {
      if (i == steps.length) return _goHome();
      Navigator.of(context).push(PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (_, __, ___) => steps[i](() => show(i + 1)),
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOutQuad),
          child: child,
        ),
      ));
    }

    show(0);
  }

  void _showBelongsToAnother() {
    final wipe = context.read<TerminalWipe>();
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AccountBelongsToAnotherScreen(
        onUseOwnerAccount: (_) {
          Navigator.of(context).pop();
          _otpCtrl.clear();
          setState(() {
            _phase = _Phase.email;
            _busy = false;
          });
        },
        onEraseInstallation: (ctx) => confirmAndEraseInstallation(ctx, wipe),
      ),
    ));
  }

  void _showKeysLost() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AccountKeysLostScreen(
        onDismiss: (_) {
          Navigator.of(context).pop();
          _otpCtrl.clear();
          setState(() {
            _phase = _Phase.email;
            _busy = false;
          });
        },
        onDeleteAndStartOver: startDeletionFlow,
      ),
    ));
  }

  void _showError(String message) {
    final messenger = ScaffoldMessenger.of(context)..removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message, style: const TextStyle(color: Warm.ctaInk)),
      backgroundColor: Warm.cta,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      duration: const Duration(seconds: 3),
    ));
  }

  // Measured with the phone's font scale so large text keeps its room
  double _copyBody(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    TextPainter laid(InlineSpan span, double maxWidth) => TextPainter(
          text: TextSpan(
            style: const TextStyle(fontFamily: Warm.fontFamily),
            children: [span],
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: maxWidth);
    final leadWidth = math.min(Warm.leadMaxWidth, width);
    switch (_phase) {
      case _Phase.intro:
        final markHeight = math.min(
            Warm.wordmarkHeight, width / kWordmarkMiuchio.aspect);
        return markHeight +
            Warm.headingToLead +
            laid(const TextSpan(text: _kIntroLead, style: Warm.lead),
                    leadWidth)
                .height;
      case _Phase.email:
        return Warm.headingToLead +
            laid(const TextSpan(text: _kEmailLead, style: Warm.lead),
                    leadWidth)
                .height;
      case _Phase.otp:
      case _Phase.done:
        return Warm.headingToLead + laid(_otpLead(_email), leadWidth).height;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final keyboardOpen = keyboard > 0;
    final onIntro = _phase == _Phase.intro;
    final topInset = MediaQuery.viewPaddingOf(context).top;

    final compactCopyBox =
        _phase == _Phase.otp ? _kCompactOtpCopyBox : _kCompactEmailCopyBox;
    final compactCopyExtent =
        _kCompactCopyLead + compactCopyBox;
    final compactFootBottom = keyboard + 20;
    final compactFootTop =
        size.height - compactFootBottom - _kCompactFootExtent;
    final compactHeroMaxBottom =
        compactFootTop - compactCopyExtent - 2 * _kCompactContentGap;
    final compactStageScale = CameraStage.shrunkScaleToFit(
      context,
      maxVisualBottom: compactHeroMaxBottom,
    );
    final compactHeroBottom = CameraStage.shrunkVisualBottom(
      context,
      scale: compactStageScale,
    );
    final rawCompactSlack = compactFootTop -
        compactHeroBottom -
        compactCopyExtent -
        2 * _kCompactContentGap;
    final compactSlack = rawCompactSlack > 0 ? rawCompactSlack : 0.0;
    final compactCopyTop =
        compactHeroBottom + _kCompactContentGap + compactSlack / 2;

    // Fractions alone let the foot land on the copy on shorter screens
    final copyBody = _copyBody(context, size.width - Warm.pagePad * 2);
    final footExtent = _kDotsExtent +
        _kDotsGap +
        (onIntro ? 0 : Warm.fieldHeight + _kDotsGap) +
        Warm.ctaHeight;
    final footTop =
        size.height - size.height * Warm.ctaBottomInset - footExtent;
    final copyTop = math.min(
      topInset + size.height * Warm.topAir,
      footTop -
          _kFootClearance -
          _kCopyLead -
          copyBody,
    );
    final stageScale = CameraStage.scaleToFit(
      context,
      maxVisualBottom: copyTop - _kFootClearance,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        resizeToAvoidBottomInset: false,
        body: GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              const Positioned.fill(child: _Ground()),

              // Keep the scrim behind the camera so its colours stay unchanged
              const Positioned.fill(child: IgnorePointer(child: _Scrim())),

              CameraStage.positioned(
                context,
                // The lite clip runs at 30 fps, so the pen follows its frames
                onStart: (tier) =>
                    _wordCue.start(followClip: tier == StageTier.lite),
                onFrame: _wordCue.clip,
                onComplete: _wordCue.hurry,
                shrink: keyboardOpen,
                shrunkScale: compactStageScale,
                scale: stageScale,
              ),

              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                top: keyboardOpen ? compactCopyTop : copyTop,
                left: Warm.pagePad,
                right: Warm.pagePad,
                child: AnimatedOpacity(
                  opacity: _phase == _Phase.done ? 0 : 1,
                  duration: const Duration(milliseconds: 700),
                  curve: Warm.easeSoft,
                  child: _Copy(
                    wordCue: _wordCue,
                    phase: _phase,
                    email: _email,
                    compact: keyboardOpen,
                    box: math.max(_kCopyBox, copyBody),
                  ),
                ),
              ),

              Positioned(
                left: 0,
                right: 0,
                bottom: MediaQuery.viewPaddingOf(context).bottom + 12,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: onIntro && !keyboardOpen ? 1 : 0,
                    duration: Warm.quick,
                    child: Text('End-to-end encrypted · Beta 1.0',
                        textAlign: TextAlign.center, style: Warm.footMark),
                  ),
                ),
              ),

              AnimatedPositioned(
                duration: Warm.quick,
                curve: Warm.easeOut,
                left: Warm.pagePad,
                right: Warm.pagePad,
                bottom: (keyboard > 0
                    ? keyboard + 20
                    : size.height * Warm.ctaBottomInset),
                child: _phase == _Phase.done
                    ? const _Confirmation()
                    : _Foot(
                        onIntro: onIntro,
                        phase: _phase,
                        ready: _ready && !_busy,
                        busy: _busy,
                        label: _ctaLabel,
                        emailCtrl: _emailCtrl,
                        emailFocus: _emailFocus,
                        otpCtrl: _otpCtrl,
                        otpFocus: _otpFocus,
                        onSubmit: _advance,
                        compact: keyboardOpen,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
