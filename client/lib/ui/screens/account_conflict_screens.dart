import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// Account-gate refusals have different destructive remedies

class _Dead extends StatelessWidget {
  final String title;
  final String body;
  final List<Widget> actions;
  const _Dead({required this.title, required this.body, required this.actions});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Warm.pagePad),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Warm.h1),
                const SizedBox(height: Warm.headingToLead),
                Text(body, style: Warm.sub),
                const SizedBox(height: 32),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// This account may erase local data but cannot delete the vault owner's account
// Actions receive this screen's context because the caller route is removed
typedef ScreenAction = void Function(BuildContext context);

class AccountBelongsToAnotherScreen extends StatelessWidget {
  final ScreenAction onUseOwnerAccount;
  final ScreenAction onEraseInstallation;

  const AccountBelongsToAnotherScreen({
    super.key,
    required this.onUseOwnerAccount,
    required this.onEraseInstallation,
  });

  @override
  Widget build(BuildContext context) {
    return _Dead(
      title: 'This phone is set up for another account',
      body: 'Miuchio allows one account per phone. Sign in with that account, '
          'or erase Miuchio on this phone and start fresh.',
      actions: [
        FilledButton(
          onPressed: () => onUseOwnerAccount(context),
          child: const Text("Sign in with this phone's account"),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => onEraseInstallation(context),
          child: const Text('Erase and start fresh'),
        ),
      ],
    );
  }
}

// New identity keys cannot recover album keys lost with the old installation
class AccountKeysLostScreen extends StatelessWidget {
  final ScreenAction onDeleteAndStartOver;
  final ScreenAction onDismiss;

  const AccountKeysLostScreen({
    super.key,
    required this.onDeleteAndStartOver,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return _Dead(
      title: 'Your photos are locked to your old phone',
      body: 'This account’s photos only open on the phone it was set up on.'
          '\n\nUse Miuchio on that phone, or delete this account and start '
          'over. Starting over loses the old photos.',
      actions: [
        FilledButton(
          onPressed: () => onDismiss(context),
          child: const Text('I still have that phone'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => onDeleteAndStartOver(context),
          child: const Text('Delete this account and start over'),
        ),
      ],
    );
  }
}

// Owns the wipe so failures cannot be mistaken for completed erasure
class EraseInstallationScreen extends StatefulWidget {
  final Future<void> Function() wipe;
  const EraseInstallationScreen({super.key, required this.wipe});

  @override
  State<EraseInstallationScreen> createState() =>
      _EraseInstallationScreenState();
}

enum _ErasedPhase { working, done, stuck }

class _EraseInstallationScreenState extends State<EraseInstallationScreen> {
  _ErasedPhase _phase = _ErasedPhase.working;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _phase = _ErasedPhase.working);
    try {
      await widget.wipe();
      if (mounted) setState(() => _phase = _ErasedPhase.done);
    } catch (_) {
      if (mounted) setState(() => _phase = _ErasedPhase.stuck);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (_phase) {
      _ErasedPhase.working => (
          'Erasing…',
          'Removing everything the previous account kept on this phone.'
        ),
      _ErasedPhase.done => (
          'This phone is clear',
          'Everything the previous account kept on this phone is gone. Close '
              'Miuchio and open it again to sign in.'
        ),
      _ErasedPhase.stuck => (
          'Couldn’t erase everything',
          'Some of the other account’s data is still here. Try again before '
              'signing in.'
        ),
    };

    return _Dead(
      title: title,
      body: body,
      actions: [
        if (_phase == _ErasedPhase.stuck)
          FilledButton(onPressed: _run, child: const Text('Try again')),
      ],
    );
  }
}

// An unowned vault cannot be attributed without the server
class ConnectionRequiredScreen extends StatelessWidget {
  const ConnectionRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _Dead(
      title: 'Miuchio needs the internet',
      body: 'Your account isn’t fully set up on this phone yet. Connect and '
          'open Miuchio again.',
      actions: [],
    );
  }
}
