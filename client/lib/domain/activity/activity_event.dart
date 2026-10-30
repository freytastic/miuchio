import 'dart:typed_data';

import 'package:miuchio/e2ee/media_record.dart';

// Security groups changes to who can see an album; Albums groups your shelf:
// photos arriving and albums you were added to
enum ActivityLane { security, albums }

// Album history ages out; security history remains as the access record
const Duration kActivityWindow = Duration(days: 90);

sealed class ActivityEvent {
  // Stable across rederivation, so one upload cannot become a new row on
  // every launch
  final String id;
  final String albumId;
  final DateTime at;

  const ActivityEvent({
    required this.id,
    required this.albumId,
    required this.at,
  });

  ActivityLane get lane;

  bool get needsDecision => false;
}

// A pinned peer identity no longer matches what the server serves
class SafetyNumberChanged extends ActivityEvent {
  final String peerToken;
  // Exact key that raised the alarm; Compare must not reread a mutable roster
  // Null only for legacy rows
  final Uint8List? presentedIk;
  final bool verified;
  const SafetyNumberChanged({
    required super.id,
    required super.albumId,
    required super.at,
    required this.peerToken,
    this.presentedIk,
    this.verified = false,
  });

  SafetyNumberChanged asVerified() => SafetyNumberChanged(
        id: id,
        albumId: albumId,
        at: at,
        peerToken: peerToken,
        presentedIk: presentedIk,
        verified: true,
      );

  @override
  ActivityLane get lane => ActivityLane.security;
  @override
  bool get needsDecision => true;
}

// Joining is already done when this is seen, so it is news, not an access
// alarm: it waits at the top of Albums until opened or dismissed
class InvitedToAlbum extends ActivityEvent {
  const InvitedToAlbum({
    required super.id,
    required super.albumId,
    required super.at,
  });

  @override
  ActivityLane get lane => ActivityLane.albums;
  @override
  bool get needsDecision => true;
}

class RemovedFromAlbum extends ActivityEvent {
  const RemovedFromAlbum({
    required super.id,
    required super.albumId,
    required super.at,
  });

  @override
  ActivityLane get lane => ActivityLane.security;
  @override
  bool get needsDecision => true;
}

class MemberJoined extends ActivityEvent {
  final String memberToken;
  const MemberJoined({
    required super.id,
    required super.albumId,
    required super.at,
    required this.memberToken,
  });

  @override
  ActivityLane get lane => ActivityLane.security;
}

class MemberLeft extends ActivityEvent {
  final String memberToken;
  // Revocation commits before recovery rotation, which may remain owed
  // The row must not promise a rotation that has not happened
  final bool rotationPending;
  const MemberLeft({
    required super.id,
    required super.albumId,
    required super.at,
    required this.memberToken,
    this.rotationPending = false,
  });

  @override
  ActivityLane get lane => ActivityLane.security;

  MemberLeft settled() => MemberLeft(
        id: id,
        albumId: albumId,
        at: at,
        memberToken: memberToken,
      );
}

// uploaderToken is null until a media fetch attributes it: the shelf summary
// says how many arrived but never who sent them
class PhotosAdded extends ActivityEvent {
  final int count;
  final String? uploaderToken;
  // The uploader's newest few, so the row can show the photos themselves
  // Kept whole because a thumbnail cannot be opened without its wrap
  final List<MediaRecord> previews;
  const PhotosAdded({
    required super.id,
    required super.albumId,
    required super.at,
    required this.count,
    this.uploaderToken,
    this.previews = const [],
  });

  @override
  ActivityLane get lane => ActivityLane.albums;
}

// Only the owner can rename, so the row speaks for them. The listing carries
// sealed titles alone: the recorder opens both on this phone and names the
// owner from the roster, and the row is sealed with the rest of the feed
class AlbumRenamed extends ActivityEvent {
  final String? fromCt;
  final String toCt;
  final String? from;
  final String? to;
  final String? ownerToken;
  const AlbumRenamed({
    required super.id,
    required super.albumId,
    required super.at,
    required this.fromCt,
    required this.toCt,
    this.from,
    this.to,
    this.ownerToken,
  });

  AlbumRenamed opened({String? from, String? to, String? ownerToken}) =>
      AlbumRenamed(
        id: id,
        albumId: albumId,
        at: at,
        fromCt: fromCt,
        toCt: toCt,
        from: from ?? this.from,
        to: to ?? this.to,
        ownerToken: ownerToken ?? this.ownerToken,
      );

  @override
  ActivityLane get lane => ActivityLane.albums;
}
