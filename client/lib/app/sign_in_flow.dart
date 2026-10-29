import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/data/api/auth_api.dart';
import 'package:miuchio/data/api/realtime_service.dart';
import 'package:miuchio/data/api/user_api.dart';
import 'package:miuchio/data/storage/activity_store.dart';
import 'package:miuchio/data/storage/storage_service.dart';
import 'package:miuchio/domain/account/account_gate.dart';
import 'package:miuchio/domain/account/sign_in_gate.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/ui/providers/app_state.dart';

sealed class SignInResult {
  const SignInResult();
}

class SignInWrongCode extends SignInResult {
  const SignInWrongCode();
}

// The account may not open this installation's vault
class SignInRefused extends SignInResult {
  final AccountGateOutcome outcome;
  const SignInRefused(this.outcome);
}

class SignInDone extends SignInResult {
  final AccountGateOutcome outcome;
  const SignInDone(this.outcome);
}

// Checks a sign-in code and opens the session. The onboarding screen and the
// dev seed both run it, so seeded accounts sign in the way real ones do.
// AccountDeletingException and TooManyAttemptsException pass through
class SignInFlow {
  final SignInGate _gate;
  final AppState _appState;
  final RealtimeService _realtime;
  final ActivityStore? _activity;
  final AuthService _auth;

  SignInFlow({
    required SignInGate gate,
    required AppState appState,
    required RealtimeService realtime,
    ActivityStore? activity,
    AuthService? auth,
  })  : _gate = gate,
        _appState = appState,
        _realtime = realtime,
        _activity = activity,
        _auth = auth ?? AuthService();

  factory SignInFlow.of(BuildContext context) => SignInFlow(
        gate: context.read<SignInGate>(),
        appState: context.read<AppState>(),
        realtime: context.read<RealtimeService>(),
        activity: context.read<ActivityStore?>(),
      );

  Future<SignInResult> verify(String email, String code) async {
    final pending = await _auth.verifyOtp(email, code);
    if (pending == null) return const SignInWrongCode();

    // Refuse a foreign vault before writing credentials
    if (!await _gate.admits(pending.userId)) {
      return const SignInRefused(AccountGateOutcome.blockedDifferentAccount);
    }

    await _auth.commit(pending, email: email);

    final outcome = await _gate.resolve(pending.userId);
    if (!AccountGate.admitsShelf(outcome)) {
      // Discard credentials that could reopen a refused vault offline
      if (!AccountGate.retainsSession(outcome)) {
        await StorageService().deleteAuth();
      }
      return SignInRefused(outcome);
    }

    if (outcome == AccountGateOutcome.newAccount) {
      try {
        await _activity?.seedEmptyBaseline();
      } catch (_) {}
    }

    final userData = await UserService().getMe();
    if (userData != null) _appState.setUserData(userData);
    _appState.setEmail(email);
    unawaited(_realtime.connect());
    return SignInDone(outcome);
  }
}

// Publishes this device's identity and fills its one-time prekey pool.
// Bootstrap failures, such as BootstrapAccountConflictException, pass through
Future<void> bootstrapIdentity(IdentityService identity) async {
  await identity.bootstrap();
  try {
    await identity.replenishOpks(
      target: kTargetOpkPool,
      trigger: kTargetOpkPool,
    );
  } catch (_) {}
}
