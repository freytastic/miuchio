import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/domain/activity/activity_event.dart';
import 'package:miuchio/ui/activity/activity_copy.dart';

void main() {
  final at = DateTime.utc(2026, 9, 20, 10);

  String name(String token) =>
      {'noor': 'Noor', 'juno': 'Juno'}[token] ?? 'Someone';
  String title(String id) => {'a': 'Birthday'}[id] ?? 'an album';

  final names = ActivityNames(memberName: (_, t) => name(t), albumTitle: title);

  group('cards, for the things waiting on a decision', () {
    test('a safety number says what it might mean, without jargon', () {
      final copy = cardCopyFor(
        SafetyNumberChanged(id: 'x', albumId: 'a', at: at, peerToken: 'noor'),
        names,
      );

      expect(copy.title, "Noor's security code changed");
      expect(copy.where, 'Birthday');
      // In this build a new phone cannot keep the same membership (the
      // account gate refuses it), so "probably a new phone" was false comfort
      expect(copy.body.toLowerCase(), isNot(contains('new phone')));
      expect(copy.body.toLowerCase(), isNot(contains('probably')));
      expect(copy.body, contains('in person'));
      expect(copy.body, contains('pretending'));
      expect(copy.body.toLowerCase(), isNot(contains('fingerprint')));
      expect(copy.body.toLowerCase(), isNot(contains('identity key')));
      expect(copy.go, 'Compare');
    });

    test('a removal says what actually happened, and only acknowledges', () {
      final copy = cardCopyFor(
        RemovedFromAlbum(id: 'x', albumId: 'a', at: at),
        names,
      );

      expect(copy.title, contains('no longer in'));
      // Cleanup can lag while offline
      expect(copy.body, contains('being removed from this phone'));
      expect(copy.body, isNot(contains('rotated')));
      expect(copy.body, isNot(contains('stays')));
      expect(copy.go, 'Okay');
      expect(copy.quiet, isNull, reason: 'the copy is already gone');
    });
  });

  group('rows, for the things that merely happened', () {
    test('photos name the uploader when one is known', () {
      final line = lineFor(
        PhotosAdded(
            id: 'x', albumId: 'a', at: at, count: 5, uploaderToken: 'noor'),
        names,
      );

      expect(line.lead, 'Noor');
      expect(line.rest, ' added 5 photos');
      expect(line.where, 'Birthday');
    });

    // The shelf summary counts without attributing, so the row has to read
    // properly with nobody named rather than inventing one
    test('photos read without a name when nobody is attributed', () {
      final line = lineFor(
        PhotosAdded(id: 'x', albumId: 'a', at: at, count: 5),
        names,
      );

      expect(line.lead, '5 photos');
      expect(line.rest, ' were added');
    });

    test('one photo is not pluralised', () {
      final line = lineFor(
        PhotosAdded(
            id: 'x', albumId: 'a', at: at, count: 1, uploaderToken: 'noor'),
        names,
      );
      expect(line.rest, ' added 1 photo');
    });

    test('a completed rotation says what it bought you', () {
      final line = lineFor(
        MemberLeft(
            id: 'x',
            albumId: 'a',
            at: at,
            memberToken: 'juno',
            rotationPending: false),
        names,
      );

      expect(line.lead, 'Juno');
      expect(line.rest, ' left');
      expect(line.aside, contains("can't see anything added"));
      expect(line.aside, isNot(contains('still locking')));
      expect(line.warn, isFalse);
    });

    test('an owed rotation says so instead of claiming it happened', () {
      final line = lineFor(
        MemberLeft(
            id: 'x',
            albumId: 'a',
            at: at,
            memberToken: 'juno',
            rotationPending: true),
        names,
      );

      expect(line.aside, isNot(contains("can't see")));
      expect(line.aside, contains('still locking'));
      expect(line.warn, isTrue);
    });

    test('a compared safety number says it matched and stops warning', () {
      final line = lineFor(
        SafetyNumberChanged(
            id: 't', albumId: 'a', at: at, peerToken: 'noor', verified: true),
        names,
      );
      expect(line.aside, contains('matched'));
      expect(line.warn, isFalse);
    });

    test('an uncompared safety number keeps warning after dismissal', () {
      final line = lineFor(
        SafetyNumberChanged(id: 'x', albumId: 'a', at: at, peerToken: 'noor'),
        names,
      );

      expect(line.aside, contains("haven't compared"));
      expect(line.warn, isTrue);
    });
  });

  group('day labels follow the phone\'s own calendar', () {
    final now = DateTime(2026, 9, 22, 9);

    test('just after local midnight is today', () {
      expect(dayLabel(DateTime(2026, 9, 22, 1, 30).toUtc(), now: now), 'Today');
    });

    test('late last night is yesterday', () {
      expect(dayLabel(DateTime(2026, 9, 21, 23, 30).toUtc(), now: now),
          'Yesterday');
    });

    test('older spans read as spans', () {
      expect(dayLabel(DateTime(2026, 9, 18).toUtc(), now: now),
          'Earlier this week');
      expect(dayLabel(DateTime(2026, 9, 2).toUtc(), now: now),
          'Earlier this month');
      expect(dayLabel(DateTime(2026, 6, 1).toUtc(), now: now), 'Older');
    });

    test('an added album says when, never "added older"', () {
      expect(
          addedWhen(DateTime(2026, 9, 22, 8).toUtc(), now: now), 'Added today');
      expect(addedWhen(DateTime(2026, 6, 1).toUtc(), now: now),
          'Added a while ago');
    });
  });

  group('renames', () {
    AlbumRenamed renamed({String? from, String? to, String? owner}) =>
        AlbumRenamed(
          id: 'x',
          albumId: 'a',
          at: at,
          fromCt: 'ct-old',
          toCt: 'ct-new',
          from: from,
          to: to,
          ownerToken: owner,
        );

    test('says who renamed it, from what, to what', () {
      final line = lineFor(
          renamed(from: 'Spring break', to: 'Greece trip', owner: 'noor'),
          names);

      expect('${line.lead}${line.rest}', 'Noor renamed Spring break');
      expect(line.where, 'Now Greece trip');
    });

    test('reads without the titles or the owner', () {
      final line = lineFor(renamed(), names);

      expect('${line.lead}${line.rest}', 'The owner renamed an album');
      expect(line.where, 'Now Birthday');
    });
  });
}
