import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/ui/people/trust_summary.dart';

TrustSummary _of(List<TrustState> states) => TrustSummary.of([
      for (final (i, s) in states.indexed) (name: 'P$i', trust: s),
    ]);

void main() {
  test('nobody to compare is empty, so the album shows no line', () {
    expect(_of([]).isEmpty, isTrue);
  });

  test('stays a plain label until someone has been compared', () {
    final s = _of([TrustState.unverified, TrustState.unverified]);
    expect(s.label, 'Security codes');
    expect(s.status, '0 of 2 verified');
    expect(s.allVerified, isFalse);
  });

  test('counts verified people out of everyone comparable', () {
    final s =
        _of([TrustState.verified, TrustState.verified, TrustState.unverified]);
    expect(s.label, '2 of 3 verified');
    expect(s.allVerified, isFalse);
  });

  test('every person verified is the only state that earns the check', () {
    final s = _of([TrustState.verified, TrustState.verified]);
    expect(s.label, '2 of 2 verified');
    expect(s.allVerified, isTrue);
  });

  // A reassuring count must never hide an alarm
  test('a changed code outranks the count, even when the rest are verified',
      () {
    final one =
        _of([TrustState.verified, TrustState.verified, TrustState.changed]);
    expect(one.alarm, isTrue);
    expect(one.allVerified, isFalse);
    expect(one.label, "P2's security code changed");
    expect(one.status, "P2's security code changed");

    final two = _of([TrustState.changed, TrustState.changed]);
    expect(two.label, '2 security codes changed');
  });

  test('a changed person is not counted as verified', () {
    final s = _of([TrustState.changed]);
    expect(s.verified, 0);
    expect(s.total, 1);
  });
}
