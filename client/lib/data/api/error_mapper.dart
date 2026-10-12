import 'api_error.dart';

enum ErrorRecovery {
  retry,

  abortAndReauth,

  abortAndShowTofu,

  abortAndWipe,

  none,
}

class AppErrorUx {
  final String userMessage;

  final ErrorRecovery action;

  final bool isTransient;

  const AppErrorUx({
    required this.userMessage,
    required this.action,
    required this.isTransient,
  });
}

//Maps a server [ApiError] to the UX action and copy... the codes are the
// same set defined in `internal/apierr/apierr.go`... new server codes that
// dont appear here get a generic message , adding them is mechanical
AppErrorUx mapApiError(ApiError err) {
  switch (err.code) {
    case 'E_AUTH':
      return const AppErrorUx(
        userMessage: 'You’ve been signed out. Sign in again.',
        action: ErrorRecovery.abortAndReauth,
        isTransient: false,
      );
    case 'E_FORBIDDEN':
      return const AppErrorUx(
        userMessage: 'You can’t do that in this album.',
        action: ErrorRecovery.none,
        isTransient: false,
      );
    case 'E_NOT_MEMBER':
      return const AppErrorUx(
        userMessage: 'You are not a member of this album.',
        action: ErrorRecovery.none,
        isTransient: false,
      );
    case 'E_MEMBER_REVOKED':
      return const AppErrorUx(
        userMessage: 'You were removed from this album.',
        action: ErrorRecovery.none,
        isTransient: false,
      );
    case 'E_VALIDATION':
      return AppErrorUx(
        // Server messages are written for developers, not people
        userMessage: 'Something went wrong. Try again.',
        action: ErrorRecovery.none,
        isTransient: true,
      );
    case 'E_NOT_FOUND':
      return const AppErrorUx(
        userMessage: 'That’s no longer here.',
        action: ErrorRecovery.none,
        isTransient: true,
      );
    case 'E_CONFLICT':
      return const AppErrorUx(
        userMessage: 'Something changed. Try again.',
        action: ErrorRecovery.retry,
        isTransient: true,
      );
    case 'E_ALBUM_FULL':
      return const AppErrorUx(
        userMessage: 'This album is full.',
        action: ErrorRecovery.none,
        isTransient: false,
      );
    case 'E_OPK_EXHAUSTED':
      return const AppErrorUx(
        userMessage:
            'Couldn’t reach them right now. Try again soon.',
        action: ErrorRecovery.retry,
        isTransient: true,
      );
    case 'E_EPOCH_REPLAY':
      return const AppErrorUx(
        userMessage: 'Updating the album…',
        action: ErrorRecovery.retry,
        isTransient: true,
      );
    case 'E_INVITE_EXPIRED':
      return const AppErrorUx(
        userMessage: 'This invite has expired.',
        action: ErrorRecovery.none,
        isTransient: false,
      );
    case 'E_INVITE_CONSUMED':
      return const AppErrorUx(
        userMessage: 'This invite has already been used.',
        action: ErrorRecovery.none,
        isTransient: false,
      );
    case 'E_SIG_INVALID':
      return const AppErrorUx(
        userMessage: 'Something about this invite didn’t check out. Check your '
            'security code with the person who added you.',
        action: ErrorRecovery.abortAndShowTofu,
        isTransient: false,
      );
    case 'E_MANIFEST_TAMPER':
      return const AppErrorUx(
        userMessage: 'Something about this album didn’t check out.',
        action: ErrorRecovery.abortAndShowTofu,
        isTransient: false,
      );
    case 'E_RATE_LIMITED':
      return const AppErrorUx(
        userMessage: 'Too many tries. Wait a moment and try again.',
        action: ErrorRecovery.retry,
        isTransient: true,
      );
    case 'E_INTERNAL':
    case 'E_UNKNOWN':
      return const AppErrorUx(
        userMessage: 'Something went wrong on our end. Please try again.',
        action: ErrorRecovery.retry,
        isTransient: true,
      );
    case 'E_NOT_IMPLEMENTED':
      return const AppErrorUx(
        userMessage: 'This feature is not available yet.',
        action: ErrorRecovery.none,
        isTransient: false,
      );
    default:
      return AppErrorUx(
        userMessage: 'Something went wrong. Try again.',
        action: ErrorRecovery.none,
        isTransient: true,
      );
  }
}
