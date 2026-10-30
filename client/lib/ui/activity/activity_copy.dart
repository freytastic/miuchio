import 'package:miuchio/domain/activity/activity_event.dart';

// Names are sealed per album, so a token alone cannot resolve one
class ActivityNames {
  final String Function(String albumId, String memberToken) memberName;
  final String Function(String albumId) albumTitle;
  const ActivityNames({required this.memberName, required this.albumTitle});
}

class CardCopy {
  final String title;
  final String where;
  final String body;
  final String go;
  final String? quiet;
  const CardCopy({
    required this.title,
    required this.where,
    required this.body,
    required this.go,
    this.quiet,
  });
}

class LineCopy {
  final String lead;
  final String rest;
  final String where;
  final String? aside;
  final bool warn;
  const LineCopy({
    required this.lead,
    required this.rest,
    required this.where,
    this.aside,
    this.warn = false,
  });
}

CardCopy cardCopyFor(ActivityEvent e, ActivityNames names) {
  final where = names.albumTitle(e.albumId);
  return switch (e) {
    SafetyNumberChanged() => CardCopy(
        title:
            "${names.memberName(e.albumId, e.peerToken)}'s security code changed",
        where: where,
        // Account binding rules out a same membership phone change, so this is
        // never "probably a new phone"
        body: 'This can mean someone is pretending to be '
            '${names.memberName(e.albumId, e.peerToken)}. Check the code with '
            'them in person before trusting new photos.',
        go: 'Compare',
        quiet: 'Not now',
      ),
    // Covers removal and deletion while offline cleanup may still be queued
    RemovedFromAlbum() => CardCopy(
        title: "You're no longer in $where",
        where: 'No longer on your shelf',
        body: 'You were removed, or the album was deleted. Its photos are '
            'being removed from this phone.',
        go: 'Okay',
      ),
    _ => CardCopy(
        title: 'Something changed',
        where: where,
        body: 'Open the album to see.',
        go: 'Okay',
        quiet: 'Not now',
      ),
  };
}

LineCopy lineFor(ActivityEvent e, ActivityNames names) {
  final where = names.albumTitle(e.albumId);
  return switch (e) {
    PhotosAdded() => _photos(e, names, where),
    MemberJoined() => LineCopy(
        lead: names.memberName(e.albumId, e.memberToken),
        rest: ' joined',
        where: where,
      ),
    MemberLeft() => LineCopy(
        lead: names.memberName(e.albumId, e.memberToken),
        rest: ' left',
        where: where,
        // Removal commits before rotation, which can still fail
        aside: e.rotationPending
            ? 'Miuchio is still locking '
                '${names.memberName(e.albumId, e.memberToken)} out. Until '
                "that's done, they may see new photos."
            : "${names.memberName(e.albumId, e.memberToken)} can't see "
                'anything added from now on.',
        warn: e.rotationPending,
      ),
    SafetyNumberChanged() => LineCopy(
        lead: names.memberName(e.albumId, e.peerToken),
        rest: "'s security code changed",
        where: where,
        aside: e.verified
            ? 'You compared it and it matched.'
            : "You haven't compared it yet.",
        warn: !e.verified,
      ),
    InvitedToAlbum() => LineCopy(
        lead: 'You', rest: ' were added to $where', where: 'On your shelf'),
    RemovedFromAlbum() => LineCopy(
        lead: 'You',
        rest: "'re no longer in $where",
        where: 'No longer on your shelf',
      ),
    AlbumRenamed() => _renamed(e, names, where),
  };
}

// Names the titles from the moment of the rename, so a later rename does not
// rewrite this row, and still reads if a title could not be opened
LineCopy _renamed(AlbumRenamed e, ActivityNames names, String where) {
  final owner = e.ownerToken;
  final from = e.from;
  final to = e.to ?? where;
  return LineCopy(
    lead: owner == null ? 'The owner' : names.memberName(e.albumId, owner),
    rest: from == null ? ' renamed an album' : ' renamed $from',
    where: 'Now $to',
  );
}

// The shelf summary counts without attributing, so the row has to read
// properly with nobody named rather than inventing one
LineCopy _photos(PhotosAdded e, ActivityNames names, String where) {
  final plural = e.count == 1 ? 'photo' : 'photos';
  final who = e.uploaderToken;
  if (who == null) {
    return LineCopy(
      lead: '${e.count} $plural',
      rest: e.count == 1 ? ' was added' : ' were added',
      where: where,
    );
  }
  return LineCopy(
    lead: names.memberName(e.albumId, who),
    rest: ' added ${e.count} $plural',
    where: where,
  );
}

// When an album you were added to arrived, for its row under the heading
String addedWhen(DateTime at, {DateTime? now}) {
  final day = dayLabel(at, now: now);
  return day == 'Older' ? 'Added a while ago' : 'Added ${day.toLowerCase()}';
}

// Group stored UTC timestamps by the phone's local calendar date
String dayLabel(DateTime at, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final local = at.toLocal();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(local.year, local.month, local.day))
      .inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return 'Earlier this week';
  if (days < 30) return 'Earlier this month';
  return 'Older';
}
