import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/ui/widgets/safety_number_sheet.dart';

const _digits = '12345 67890 12345 67890 12345 67890';

Future<void> _pump(
  WidgetTester tester, {
  required TrustState state,
  FutureOr<void> Function()? onVerify,
  String? albumName,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SafetyNumberSheet(
        displayName: 'Sami',
        digits: _digits,
        state: state,
        albumName: albumName,
        onVerify: onVerify ?? () {},
      ),
    ),
  ));
  // Let the digits land before anything is tapped
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the digits and names the peer', (tester) async {
    await _pump(tester, state: TrustState.unverified);

    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(_digits), findsOneWidget);
    expect(find.textContaining('Sami'), findsWidgets);
  });

  // TOFU cannot rule out a MITM who was present at first sight, so an
  // un compared key must never be dressed up as safe
  testWidgets('unverified never claims the connection is safe or verified',
      (tester) async {
    await _pump(tester, state: TrustState.unverified);

    expect(find.text('Verified'), findsNothing);
    expect(find.text('They match'), findsOneWidget);

    // what must NOT appear is a claim
    // that the connection itself is already safe / secure / verified
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => (t.data ?? '').toLowerCase())
        .join(' ');
    expect(
        texts, isNot(matches(RegExp(r'\b(safe|secure|encrypted|private)\b'))));
    expect(texts, isNot(contains('is verified')));
  });

  // Verification has no undo, is not album scoped, and may unblock key installs
  // A reflex tap while viewing substituted digits must not grant it
  testWidgets('Mark as verified asks the user to confirm the digits matched',
      (tester) async {
    var verified = false;
    await _pump(tester,
        state: TrustState.unverified, onVerify: () => verified = true);

    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();

    expect(verified, isFalse, reason: 'one tap must not be enough');
    expect(find.textContaining('match on both phones'), findsOneWidget);
  });

  testWidgets('confirming the prompt fires onVerify', (tester) async {
    var verified = false;
    await _pump(tester,
        state: TrustState.unverified, onVerify: () => verified = true);

    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They matched'));
    await tester.pumpAndSettle();

    expect(verified, isTrue);
  });

  testWidgets('They match waits until the digits have landed', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SafetyNumberSheet(
          displayName: 'Sami',
          digits: _digits,
          state: TrustState.unverified,
          onVerify: () {},
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('They match'));
    await tester.pump();
    expect(find.textContaining('match on both phones'), findsNothing);

    await tester.pumpAndSettle();
    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    expect(find.textContaining('match on both phones'), findsOneWidget);
  });

  testWidgets('dismissing the prompt leaves the key unverified',
      (tester) async {
    var verified = false;
    await _pump(tester,
        state: TrustState.unverified, onVerify: () => verified = true);

    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("They didn't"));
    await tester.pumpAndSettle();

    expect(verified, isFalse);
  });

  testWidgets('verified shows the confirmed state and no verify button',
      (tester) async {
    await _pump(tester, state: TrustState.verified);

    expect(find.text('Verified'), findsOneWidget);
    expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
    expect(find.text('They match'), findsNothing);
  });

  // Verification grants signer authority, so accepting without comparing
  // would bypass the out of band check
  testWidgets('a changed key cannot be accepted without comparing digits',
      (tester) async {
    await _pump(tester, state: TrustState.changed);

    expect(find.textContaining('security code changed'), findsOneWidget);
    expect(find.text('They match'), findsOneWidget);
    expect(find.textContaining("It's them"), findsNothing);
    expect(find.textContaining('new phone'), findsNothing);
  });

  // Codes differ per album, so both people must know which one to open
  testWidgets('names the album the code belongs to', (tester) async {
    await _pump(tester, state: TrustState.unverified, albumName: 'Lisbon');

    expect(find.text('Code for Lisbon'), findsOneWidget);
    expect(find.textContaining('open Lisbon'), findsOneWidget);
  });

  testWidgets('explains what comparing does and where it is saved',
      (tester) async {
    await _pump(tester, state: TrustState.unverified);

    await tester.tap(find.text('Why compare?'));
    await tester.pumpAndSettle();

    expect(find.textContaining('encrypted either way'), findsOneWidget);
    expect(find.textContaining('saved on this phone only'), findsOneWidget);
  });

  testWidgets('a save that fails stays open and offers to try again',
      (tester) async {
    var calls = 0;
    await _pump(tester, state: TrustState.unverified, onVerify: () async {
      calls++;
      if (calls == 1) throw const VerificationNotSaved();
    });

    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They matched'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('safety-save-failed')), findsOneWidget);
    expect(find.text('They match'), findsNothing);

    // The digits were already confirmed, so retrying only saves
    await tester.tap(find.text('Try saving again'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Did every digit match?'), findsNothing);
    expect(find.byKey(const Key('safety-save-failed')), findsNothing);
  });
}
