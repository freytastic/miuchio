abstract final class CreateCopy {
  static const title = 'New album';
  static const namePlaceholder = 'Album name';
  static const nameRequired = 'Give the album a name';

  static const invitePeople = 'Invite people';
  static const idPlaceholder = 'Miuchio ID';
  static const idHint = 'XXXX-XXXX';
  static const idInvalid = 'A Miuchio ID has 8 letters and numbers';
  static const idDuplicate = 'They’re already on the list';
  static const idSelf = 'That’s your own ID';
  static const albumFull = 'An album holds 10 people, you included';
  static const add = 'Add';
  static const addSomeoneNew = 'Add someone new';
  static const withTheirId = 'With their Miuchio ID';
  static const newPerson = 'New';
  static const notJoinedYet = 'Hasn’t opened an album yet';
  static const knownEmpty =
      'People you invite show up here next time, so you can add them '
      'with a tap.';
  static String chosen(int n) => '$n chosen';

  static const privacyEmpty = 'Only people in the album can see names.';
  static const privacyWithInvites = 'Their names appear once they join.';

  static const createOnly = 'Create album';

  static String createAndInvite(int count) =>
      count == 0 ? createOnly : 'Create and invite $count';

  static const keySetupFailed = 'Couldn’t create the album. Try again.';

  static String invitesFailed(int count) => count == 1
      ? "One invite couldn't be sent. Add them from the album."
      : "$count invites couldn't be sent. Add them from the album.";
}
