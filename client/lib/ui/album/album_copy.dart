abstract final class AlbumCopy {
  static const back = 'Back to albums';

  static const select = 'Select';
  static const addPhotos = 'Add photos';

  static const selectPhotos = 'Select photos';
  static const selectAll = 'Select all';
  static const selectNone = 'Clear';
  static const selectClose = 'Stop selecting';

  static String selectedCount(int count, int mine) {
    if (count == 0) return selectPhotos;
    if (mine == count) return '$count selected';
    if (mine == 0) return '$count selected · none yours';
    return '$count selected · $mine yours';
  }

  static String deleteSelected(int count, int mine) {
    if (mine == 0) return 'Delete';
    if (mine == count) return 'Delete $mine';
    return 'Delete $mine of $count';
  }

  static String deleteManyTitle(int count, int mine) {
    if (mine == count) {
      return mine == 1 ? deleteTitle : 'Delete these $mine photos?';
    }
    return mine == 1 ? 'Delete your 1 photo?' : 'Delete your $mine photos?';
  }

  static String deleteManyBody(int count, int mine) {
    final gone = mine == 1
        ? "It's deleted for everyone."
        : "They're deleted for everyone.";
    final others = count - mine;
    final kept = others == 0
        ? ''
        : others == 1
            ? " The other one isn't yours, so it stays."
            : " The other $others aren't yours, so they stay.";
    return "$gone$kept This can't be undone.";
  }

  static String deletingPhotos(int n) =>
      n == 1 ? deletingPhoto : 'Deleting $n photos for everyone';
  static String deleteManyFailed(int n) =>
      n == 1 ? deleteFailed : "Couldn't delete $n photos.";
  static const people = 'People';
  static const securityCodes = 'Security codes';
  static const securityHint = 'Opens people and security codes';
  static const peopleIntro =
      'Photos in this album are encrypted either way. Comparing a security '
      'code with someone in person confirms no one is in between. '
      "It's optional, and saved on this phone.";
  static const albumInfo = 'Album info';
  static const openAlbum = 'Open album';
  static const addSomeone = 'Add someone';

  static const addTitle = 'Add someone';
  static String addTo(String album) => 'to $album';
  static const addHelp =
      "Ask for their Miuchio ID. It's on their profile, under their name.";
  static const addPaste = 'Paste';
  static const addGo = 'Add to album';
  static const addFinding = 'Finding them…';
  static const addYours = 'They need yours? ';
  static const addCopy = 'Copy';
  static const addCopied = 'Copied';
  static const addUnknown =
      'No one has this ID. Check it with them.';
  static const addSelf = "That's your own ID. Theirs is on their profile.";
  static const addAlready = "They're already in this album.";
  static const addFull = 'This album is full. It can hold 10 people.';
  static const addRotating =
      'This album is being updated. Try again in a minute.';
  static const addFailed = "Couldn't add them right now. Try again.";
  static const addDoneTitle = 'Invited';
  static String addDoneBody(String album) =>
      ' can open $album the next time they open Miuchio, with every photo '
      'already in it.';
  static const addDoneNote = 'Their name shows up here once they open it.';
  static const addAnother = 'Add another';
  static const addDone = 'Done';
  static const invitedPending = "Invited, hasn't opened it yet";
  static const invitedShort = 'Invited';
  static const addShort = 'Add';
  static const albumSettings = 'Album settings';
  static const changeCover = 'Change cover';
  static const chooseCover = 'Cover photo';
  static const chooseCoverLead =
      'It leads the album on everyone\'s shelf.';
  static const coverNewest = 'Newest photo';
  static const coverNewestDetail = 'The cover follows each new photo';
  static const coverChosen = 'Cover you chose';
  static const coverFailed = "Couldn't change the cover.";
  static const infoDetail = 'Photos, storage and who added what';
  static String peopleOf(int count, int capacity) =>
      '$count of $capacity people';
  static const addByIdShort = 'With their Miuchio ID';
  static const ownerYou = 'You made this album';
  static const cancelShort = 'Cancel';
  static const manageNote =
      "Someone you remove loses the album on their phone and can't see "
      'anything added after. Photos they already added stay.';
  static const you = 'You';
  static String showEveryone(int people) =>
      'Show everyone in this album, $people ${people == 1 ? 'person' : 'people'}';


  static String onlyTheirPhotos(String? name) =>
      name == null ? 'Only their photos' : "Only $name's photos";

  static String filteredBy(String? name, int count) {
    final whose = name == null ? 'Their' : "$name's";
    return '$whose photos · $count';
  }

  static const clearFilter = 'Show everyone';

  static String nothingFrom(String? name) => name == null
      ? 'Nothing from them in here yet.'
      : 'Nothing from $name in here yet.';

  static const noPhotosYet = 'No photos yet';
  static const infoKey =
      'Only its members hold the key, so the server stores it without being '
      'able to open it';
  static const infoWho = 'Who can see it';
  static const owner = 'Owner';
  static const leftAlbum = 'No longer in the album';
  static const nothingAddedYet = 'Nothing added yet';

  static const delete = 'Delete';
  static const deleteTitle = 'Delete this photo?';
  static const deleteBody =
      "It's deleted for everyone. This can't be undone.";
  static const deleteConfirm = 'Delete';
  static const deleteCancel = 'Keep';
  static const deleteFailed = "Couldn't delete that photo.";
  static const deletingPhoto = 'Deleting the photo for everyone';
  static const unknownMember = 'Someone';

  static const details = 'Details';
  static String photoOf(int at, int count) => '$at of $count';
  static const deleteForEveryone = 'Delete for everyone';
  static const factSize = 'Size';
  static const factFormat = 'Type';
  static const factAdded = 'Added';
  static String sharedBy(String? name, {required bool mine}) => mine
      ? 'Shared by you'
      : 'Shared by ${name ?? 'someone'}';
  static const privateNote = 'Only people in this album can see it. Location '
      'and camera details were removed.';

  static const renameAlbum = 'Rename album';
  static const renameSave = 'Save';
  static const renameCancel = 'Cancel';
  static const renameHint = 'Album name';
  static const renameFailed = "Couldn't rename the album. Try again.";
  // Matches the limit when an album is made
  static const nameMax = 38;

  static const leaveAlbum = 'Leave album';
  static const leaveTitle = 'Leave this album?';
  static const leaveBody = 'It disappears from this phone and you need a new '
      'invite to come back.';
  static const leavePhotos = 'The photos you added';
  static const keepPhotos = 'Keep my photos';
  static const keepPhotosNote = 'Everyone in the album can still see them. '
      'They still count toward your storage.';
  static const deletePhotos = 'Delete my photos';
  static const deletePhotosNote = "They're deleted for everyone. Copies people "
      'saved stay on their phones.';
  static const leaveCancel = 'Stay';
  static const leaveFailed = "Couldn't leave the album.";

  static const deleteAlbum = 'Delete album';
  static const deleteAlbumTitle = 'Delete this album?';
  static const deleteAlbumBody =
      "Every photo in it is deleted for everyone. This can't be undone.";
  static const deleteAlbumFailed = "Couldn't delete the album.";
  static const deletingAlbum = 'Deleting the album for everyone';

  static const removeFromAlbum = 'Remove from album';
  static const safetyNumber = 'Safety number';
  static const madeThisAlbum = 'Made this album';
  static String removeTitle(String name) => 'Remove $name?';
  static const removeBody = 'The album disappears from their phone and they '
      "can't see anything added after now. The photos they added stay, unless "
      'their settings say to delete them.';
  static const remove = 'Remove';
  static const removeFailed = "Couldn't remove them.";
  static const cancelInviteTitle = 'Cancel this invite?';
  static const cancelInviteBody = "They won't be able to join with it.";
  static const cancelInvite = 'Cancel invite';

  static const madeByYou = 'You';
  static const ownerNote =
      'You made this album, so you can add and remove people.';
}
