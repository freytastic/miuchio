import 'package:miuchio/data/storage/media_sealed_cache.dart';
import 'package:miuchio/domain/account/account_gate.dart';
import 'package:miuchio/domain/account/sign_in_gate.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/prekey_api.dart';
import 'package:miuchio/secure_store/secure_key_store.dart';

// Album keys and catalog entries count as leftover vault data. Partial
// identities are detected separately by AccountGate. An unreadable vault
// counts as nonempty
ResidualVaultProbe residualVaultProbe(
        SecureKeyStore keys, MediaSealedCache catalog) =>
    () async {
      try {
        final handles = await keys.list();
        if (handles.any((h) => h.label.startsWith(kAlbumLabelPrefix))) {
          return true;
        }
        return (await catalog.loadAlbums()).isNotEmpty;
      } catch (_) {
        return true;
      }
    };

ServerIdentityReader serverIdentityReader(PrekeyApi prekeys) => () async {
      try {
        final keys = await prekeys.fetchOwnKeys();
        if (keys.ikPub.isEmpty || keys.lkPub.isEmpty) {
          return (
            state: ServerIdentityState.unpublished,
            ik: null,
            lk: null,
          );
        }
        return (
          state: ServerIdentityState.published,
          ik: keys.ikPub,
          lk: keys.lkPub,
        );
      } catch (_) {
        // A network failure cannot prove that no identity is published
        return (state: ServerIdentityState.unavailable, ik: null, lk: null);
      }
    };
