import 'package:miuchio/domain/safety/reporter.dart';

abstract final class SafetyCopy {
  static const report = 'Report';
  static const reportPhotoTitle = 'Report this photo';
  static const reportPhotoAction = 'Report photo';
  static String reportPersonTitle(String? name) =>
      name == null ? 'Report this person' : 'Report $name';
  static const reportAsk = 'Why are you reporting this?';
  static const reportNote = 'Add a note (optional)';
  static const reportNoteMax = 500;
  static const reportPhotoConsent =
      'Only I see this photo and your answer. No one in the album is told.';
  static const reportPersonConsent =
      'Only I see your answer. No one in the album is told.';
  static const reportSend = 'Send report';
  static const reportSent = 'Report sent';
  static const reportFailed = "Couldn't send. Try again.";
  static const cancel = 'Cancel';

  static String reason(ReportReason r) => switch (r) {
        ReportReason.sexual => 'Inappropriate',
        ReportReason.violence => 'Violent or disturbing',
        ReportReason.harassment => 'Bullying or hateful',
        ReportReason.childSafety => 'A child may be at risk',
        ReportReason.other => 'Something else',
      };

  static const block = 'Block';
  static String blockTitle(String? name) =>
      name == null ? 'Block this person?' : 'Block $name?';
  static const blockBody = 'Neither of you can add the other to albums.';
  static const blockAndLeave = 'Block and leave';
  static const blockAndRemove = 'Block and remove';
  static const blockOnly = 'Block only';
  static const blockFailed = "Couldn't block them. Try again.";
  static String blocked(String? name) =>
      name == null ? 'Blocked' : '$name is blocked';

  static const untitled = 'Untitled album';
  static String gateAddedBy(String? name) => name == null
      ? 'Someone added you to this album'
      : '$name added you to this album';
  static const gateBody = 'Photos stay hidden until you open it.';
  static const gateOpen = 'Open album';
  static const gateLeave = 'Leave';
  static const gateLeaveFailed = "Couldn't leave the album. Try again.";

  static const blockedTitle = 'Blocked';
  static const blockedSubtitle = "They can't add you to albums";
  static const blockedEmpty = "You haven't blocked anyone.";
  static const blockedLoadFailed = "Couldn't load your blocked list.";
  static const blockedSomeone = 'Someone you blocked';
  static String blockedOn(String day) => 'Blocked $day';
  static const unblock = 'Unblock';
  static String unblockTitle(String? name) =>
      name == null ? 'Unblock this person?' : 'Unblock $name?';
  static const unblockBody = 'You can add each other again.';
  static const unblockFailed = "Couldn't unblock them. Try again.";

  static const addBlocked = "You can't add this person.";
}
