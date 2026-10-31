import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/album_header.dart';
import 'package:miuchio/ui/album/member_avatars.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/ui/people/trust_summary.dart';

void main() {
  late int cleared;

  Future<void> pump(
    WidgetTester tester, {
    String summary = '3 photos · 1.2 MB · 2 people',
    List<AvatarMember> members = const [
      AvatarMember(token: 'a', name: 'Ana'),
      AvatarMember(token: 'b', name: 'Bea'),
    ],
    String? filterToken,
    String? filterName,
    int filterCount = 0,
    TrustSummary? trust,
    VoidCallback? onSecurity,
  }) async {
    cleared = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AlbumHeader(
          albumId: 'album',
          title: 'Lisbon',
          summary: summary,
          members: members,
          filterToken: filterToken,
          filterName: filterName,
          filterCount: filterCount,
          onTapMember: (_) {},
          onClearFilter: () => cleared++,
          trust: trust,
          onSecurity: onSecurity,
        ),
      ),
    ));
  }

  testWidgets('shows the people as avatars, with no names beside them',
      (tester) async {
    await pump(tester);

    expect(find.byType(MemberAvatars), findsOneWidget);
    expect(find.text('Ana'), findsNothing);
    expect(find.text('Bea'), findsNothing);
  });

  testWidgets('while filtering it offers a way back to everyone',
      (tester) async {
    await pump(tester, filterToken: 'a', filterName: 'Ana', filterCount: 4);

    expect(find.text(AlbumCopy.filteredBy('Ana', 4)), findsOneWidget);

    await tester.tap(find.text(AlbumCopy.filteredBy('Ana', 4)));
    await tester.pump();

    expect(cleared, 1);
  });

  group('security line', () {
    TrustSummary of(List<TrustState> s) => TrustSummary.of(
        [for (final (i, t) in s.indexed) (name: 'P$i', trust: t)]);

    testWidgets('is calm and labelled before anyone is compared',
        (tester) async {
      var opened = 0;
      await pump(tester,
          trust: of([TrustState.unverified, TrustState.unverified]),
          onSecurity: () => opened++);

      expect(find.text('Security codes'), findsOneWidget);
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
      expect(find.byIcon(Icons.verified_user_outlined), findsNothing);

      await tester.tap(find.byKey(const Key('album-security')));
      expect(opened, 1);
      expect(tester.getSize(find.byKey(const Key('album-security'))).height,
          greaterThanOrEqualTo(44));
    });

    testWidgets('counts, and earns the check only when everyone is verified',
        (tester) async {
      await pump(tester,
          trust: of([TrustState.verified, TrustState.unverified]),
          onSecurity: () {});
      expect(find.text('1 of 2 verified'), findsOneWidget);
      expect(find.byIcon(Icons.verified_user_outlined), findsNothing);

      await pump(tester,
          trust: of([TrustState.verified, TrustState.verified]),
          onSecurity: () {});
      expect(find.text('2 of 2 verified'), findsOneWidget);
      expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);
    });

    testWidgets('a changed code replaces the count and is the only warning',
        (tester) async {
      await pump(tester,
          trust: of([TrustState.verified, TrustState.changed]),
          onSecurity: () {});

      final text = tester.widget<Text>(find.text("P1's security code changed"));
      expect(text.style?.color, Warm.warn);
      expect(find.textContaining('verified'), findsNothing);
      expect(find.byIcon(Icons.verified_user_outlined), findsNothing);
    });

    testWidgets('is hidden with nobody to compare, or before trust loads',
        (tester) async {
      await pump(tester, trust: of([]), onSecurity: () {});
      expect(find.byKey(const Key('album-security')), findsNothing);

      await pump(tester, onSecurity: () {});
      expect(find.byKey(const Key('album-security')), findsNothing);
    });
  });

  group('collapsed bar', () {
    testWidgets('is invisible and untappable until the header scrolls away',
        (tester) async {
      var more = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AlbumTopBar(
            title: 'Lisbon',
            visible: false,
            onBack: () {},
            onInfo: () => more++,
          ),
        ),
      ));

      await tester.tap(find.byTooltip(AlbumCopy.albumInfo), warnIfMissed: false);
      await tester.pump();

      expect(more, 0, reason: 'a hidden bar must not swallow taps');
    });

    testWidgets('keeps its controls clear of the status bar', (tester) async {
      const inset = 44.0;
      await tester.pumpWidget(const MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(top: inset)),
        child: MaterialApp(
          home: Scaffold(
            body: AlbumTopBar(
              title: 'Lisbon',
              visible: true,
              onBack: _noop,
              onInfo: _noop,
            ),
          ),
        ),
      ));

      final back = tester.getRect(find.byTooltip(AlbumCopy.back));
      expect(back.top, greaterThanOrEqualTo(inset));
      expect(
        tester.getSize(find.byType(AlbumTopBar)).height,
        AlbumTopBar.barHeight + inset,
        reason: 'the gradient still covers the status bar',
      );
    });
  });
}

void _noop() {}
