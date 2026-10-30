part of 'onboarding_screen.dart';

// Preserve IME composition without drawing Flutter's composing underline
class _EmailEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return TextSpan(style: style, text: text);
  }
}

class _Ground extends StatelessWidget {
  const _Ground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        color: Warm.ground,
        gradient: RadialGradient(
          center: Alignment(0, -1.4),
          radius: 1.1,
          colors: [Warm.groundLift, Warm.groundLift0],
        ),
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, 0.36),
          radius: 0.78,
          colors: [
            Color(0xB8F6F3EE),
            Color(0x52F6F3EE),
            Color(0x00F6F3EE),
          ],
          stops: [0, 0.55, 1],
        ),
      ),
    );
  }
}

class _Copy extends StatelessWidget {
  const _Copy({
    required this.phase,
    required this.email,
    required this.compact,
    required this.box,
  });

  final _Phase phase;
  final String email;
  final bool compact;
  final double box;

  @override
  Widget build(BuildContext context) {
    final onIntro = phase == _Phase.intro;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: compact ? _kCompactCopyLead : _kCopyLead),
        SizedBox(
          height: compact
              ? (phase == _Phase.otp
                  ? _kCompactOtpCopyBox
                  : _kCompactEmailCopyBox)
              : box,
          child: AnimatedSwitcher(
            duration: Warm.crossfade,
            switchInCurve: Warm.easeSoft,
            switchOutCurve: const FlippedCurve(Warm.easeSoft),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, if (current != null) current],
            ),
            child: onIntro
                ? const _IntroCopy(key: ValueKey('intro'))
                : _PhaseCopy(
                    key: ValueKey(phase),
                    phase: phase,
                    email: email,
                    compact: compact,
                  ),
          ),
        ),
      ],
    );
  }
}

class _IntroCopy extends StatelessWidget {
  const _IntroCopy({super.key});

  // The box shrinks to the email copy while this fades out, so it may overhang
  @override
  Widget build(BuildContext context) {
    return OverflowBox(
      alignment: Alignment.topCenter,
      maxHeight: double.infinity,
      child: _content(),
    );
  }

  Widget _content() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: HelloWordmark(
            glyphs: kWordmarkMiuchio,
            height: Warm.wordmarkHeight,
            color: Warm.cta,
            duration: Duration.zero,
            written: true,
            semanticsLabel: 'Miuchio',
          ),
        ),
        const SizedBox(height: Warm.headingToLead),
        const SizedBox(
          width: Warm.leadMaxWidth,
          child: Text(
            _kIntroLead,
            textAlign: TextAlign.center,
            style: Warm.lead,
          ),
        ),
      ],
    );
  }
}

class _PhaseCopy extends StatelessWidget {
  const _PhaseCopy({
    super.key,
    required this.phase,
    required this.email,
    required this.compact,
  });

  final _Phase phase;
  final String email;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Warm.leadMaxWidth,
      margin: EdgeInsets.only(top: compact ? 4 : Warm.headingToLead),
      child: phase == _Phase.email
          ? const Text(
              _kEmailLead,
              textAlign: TextAlign.center,
              style: Warm.lead,
            )
          : Text.rich(_otpLead(email), textAlign: TextAlign.center),
    );
  }
}

class _Foot extends StatelessWidget {
  const _Foot({
    required this.onIntro,
    required this.phase,
    required this.ready,
    required this.busy,
    required this.label,
    required this.emailCtrl,
    required this.emailFocus,
    required this.otpCtrl,
    required this.otpFocus,
    required this.onSubmit,
    required this.compact,
  });

  final bool onIntro;
  final _Phase phase;
  final bool ready;
  final bool busy;
  final String label;
  final TextEditingController emailCtrl;
  final FocusNode emailFocus;
  final TextEditingController otpCtrl;
  final FocusNode otpFocus;
  final Future<void> Function() onSubmit;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dots(step: onIntro ? 0 : 1),
        SizedBox(height: compact ? 14 : 22),
        AnimatedSize(
          duration: Warm.springSnappy,
          curve: Warm.easeSoft,
          child: onIntro
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.only(bottom: compact ? 14 : 22),
                  child: AnimatedSwitcher(
                    duration: Warm.quick,
                    child: phase == _Phase.email
                        ? _EmailPill(
                            key: const ValueKey('email'),
                            controller: emailCtrl,
                            focusNode: emailFocus,
                            onSubmit: onSubmit,
                          )
                        : _OtpRow(
                            key: const ValueKey('otp'),
                            controller: otpCtrl,
                            focusNode: otpFocus,
                            onSubmit: onSubmit,
                          ),
                  ),
                ),
        ),
        _Cta(label: label, ready: ready, busy: busy, onTap: onSubmit),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(2, (i) {
        final active = i == step;
        return AnimatedContainer(
          duration: Warm.springSoft,
          curve: Warm.easeSoft,
          margin: EdgeInsets.only(right: i == 0 ? Warm.dotsGap : 0),
          width: active ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: Warm.cta.withValues(alpha: active ? 1 : 0.28),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}

class _EmailPill extends StatelessWidget {
  const _EmailPill({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: WarmField(
          controller: controller,
          focusNode: focusNode,
          label: 'Email address',
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.go,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          soft: true,
          onSubmitted: (_) => onSubmit(),
        ),
      ),
    );
  }
}

// One field preserves paste and SMS autofill across all six cells
class _OtpRow extends StatelessWidget {
  const _OtpRow({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final code = controller.text;
    return GestureDetector(
      onTap: focusNode.requestFocus,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_kOtpLength, (i) {
              return Padding(
                padding: EdgeInsets.only(right: i == _kOtpLength - 1 ? 0 : 8),
                child: _OtpCell(
                  digit: i < code.length ? code[i] : '',
                  active: i == code.length && focusNode.hasFocus,
                ),
              );
            }),
          ),
          SizedBox(
            height: Warm.otpCellHeight,
            width: _kOtpLength * Warm.otpCellWidth + (_kOtpLength - 1) * 8,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.go,
              maxLength: _kOtpLength,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => onSubmit(),
              showCursor: false,
              style: const TextStyle(color: Colors.transparent, height: 0.01),
              decoration: const InputDecoration(
                border: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OtpCell extends StatelessWidget {
  const _OtpCell({required this.digit, required this.active});

  final String digit;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final rule = active
        ? Warm.ink
        : digit.isNotEmpty
            ? Warm.inkFaint
            : Warm.inkGhost;
    return SizedBox(
      width: Warm.otpCellWidth,
      height: Warm.otpCellHeight,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (digit.isNotEmpty)
            Text(digit, style: Warm.otpDigit)
          else if (active)
            const _Caret(),
          Positioned(
            left: 4,
            right: 4,
            bottom: 4,
            child: AnimatedContainer(
              duration: Warm.quick,
              height: 2,
              decoration: BoxDecoration(
                color: rule,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Caret extends StatefulWidget {
  const _Caret();

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> {
  final CaretBlink _blink = CaretBlink(const Duration(milliseconds: 1100));

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _blink,
      builder: (context, on, child) => Opacity(opacity: on ? 1 : 0, child: child),
      child: Container(
        width: 2,
        height: 24,
        decoration: BoxDecoration(
          color: Warm.ink,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

class _Cta extends StatelessWidget {
  const _Cta({
    required this.label,
    required this.ready,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool ready;
  final bool busy;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return WarmButton(
      label: label,
      width: 300,
      busy: busy,
      onTap: ready ? onTap : null,
    );
  }
}

class _Confirmation extends StatelessWidget {
  const _Confirmation();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('You’re in.', style: Warm.confirmTitle),
        SizedBox(height: 8),
        Text('Setting up your albums…', style: Warm.confirmSub),
      ],
    );
  }
}
