import 'dart:async';
import 'dart:ui' show ImageFilter, PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:miuchio/data/api/api_error.dart';
import 'package:miuchio/data/api/error_mapper.dart';
import 'package:miuchio/data/api/session_refresher.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/diagnostics/debug_log.dart';
import 'package:miuchio/diagnostics/perf_probe.dart';
import 'package:miuchio/diagnostics/trace.dart';
import 'package:miuchio/domain/account/account_deletion.dart';
import 'package:miuchio/ui/screens/account_deletion_screen.dart';
import 'package:miuchio/ui/screens/landing_screen.dart';
import 'package:miuchio/ui/screens/onboarding_screen.dart';
import 'package:miuchio/ui/shelf/shelf_covers_impl.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/default_status_bar.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

// ApiErrors become a snackbar, everything else goes to the debug log
void installErrorHandlers() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    final err = details.exception;
    if (err is ApiError) {
      showApiError(err);
    } else {
      DebugLog.record(DebugEvent.appError,
          reason: Trace.reasonOf(err), stage: 'flutter');
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    if (error is ApiError) {
      showApiError(error);
      return true;
    }
    DebugLog.record(DebugEvent.appError,
        reason: Trace.reasonOf(error), stage: 'async');
    return false;
  };
}

void showApiError(ApiError err) {
  final ux = mapApiError(err);
  rootMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text(ux.userMessage),
      duration: ux.isTransient
          ? const Duration(seconds: 3)
          : const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
    ),
  );
  if (ux.action == ErrorRecovery.abortAndReauth) {
    rootNavigatorKey.currentState?.pushNamedAndRemoveUntil(
      '/login',
      (_) => false,
    );
  }
}

class MiuchioApp extends StatefulWidget {
  final MediaCacheManager mediaCacheManager;
  final ShelfCoversImpl shelfCovers;
  // Set when an earlier run confirmed a deletion it never saw finish
  final AccountDeletion? resumeDeletion;
  const MiuchioApp({
    super.key,
    required this.mediaCacheManager,
    required this.shelfCovers,
    this.resumeDeletion,
  });

  @override
  State<MiuchioApp> createState() => _MiuchioAppState();
}

class _MiuchioAppState extends State<MiuchioApp> with WidgetsBindingObserver {
  // Hides shelf photos from task switcher snapshots
  bool _shielded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Clear plaintext on background but ignore transient inactive states
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Task switcher snapshots precede pause
    final shield = state != AppLifecycleState.resumed;
    if (shield != _shielded) setState(() => _shielded = shield);

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      widget.mediaCacheManager.onAppPaused();
      widget.shelfCovers.suspend();
      unawaited(DebugLog.flush());
    } else if (state == AppLifecycleState.resumed) {
      widget.shelfCovers.resume();
      // Refresh proactively because an expired session cannot be renewed
      unawaited(SessionRefresher().renewIfDue().catchError(
            (_) => null,
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Miuchio',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [PerfProbe.observer],
      scaffoldMessengerKey: rootMessengerKey,
      theme: Warm.theme,
      home: widget.resumeDeletion == null
          ? const LandingPage()
          : AccountDeletionScreen(
              deletion: widget.resumeDeletion!,
              onNotAccepted: (_) => const LandingPage(),
            ),
      routes: {
        '/login': (_) => const OnboardingScreen(),
      },
      builder: (context, child) => DefaultStatusBar(
        child: Stack(
          children: [
            if (child != null) child,
            if (_shielded)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: Warm.shieldBlur,
                    sigmaY: Warm.shieldBlur,
                  ),
                  child: const ColoredBox(color: Warm.shieldScrim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
