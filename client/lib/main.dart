import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium_sumo.dart' show SodiumSumo, SodiumSumoInit;

import 'package:miuchio/app/album_wipe.dart';
import 'package:miuchio/app/app.dart';
import 'package:miuchio/app/avatar_wiring.dart';
import 'package:miuchio/app/device_wipe.dart';
import 'package:miuchio/app/name_resolvers.dart';
import 'package:miuchio/app/realtime_router.dart';
import 'package:miuchio/app/sign_in_wiring.dart';
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/account_api.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/api/api_client.dart';
import 'package:miuchio/data/api/avatar_api.dart';
import 'package:miuchio/data/api/epoch_api.dart' as data_epoch;
import 'package:miuchio/data/api/invite_json_client.dart';
import 'package:miuchio/data/api/media_api.dart';
import 'package:miuchio/data/api/prekey_json_client.dart';
import 'package:miuchio/data/api/realtime_service.dart';
import 'package:miuchio/data/native/image_transcoder.dart';
import 'package:miuchio/data/storage/account_owner.dart';
import 'package:miuchio/data/storage/activity_store.dart';
import 'package:miuchio/data/storage/avatar_cache.dart';
import 'package:miuchio/data/storage/cache_root_key.dart';
import 'package:miuchio/data/storage/deletion_marker.dart';
import 'package:miuchio/data/storage/identity_pin_store.dart';
import 'package:miuchio/data/storage/install_guard.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/media_catalog.dart';
import 'package:miuchio/data/storage/media_plaintext_cache.dart';
import 'package:miuchio/data/storage/media_sealed_cache.dart';
import 'package:miuchio/data/storage/name_cache.dart';
import 'package:miuchio/data/storage/own_avatar_store.dart';
import 'package:miuchio/data/storage/secure_storage.dart';
import 'package:miuchio/data/storage/storage_service.dart';
import 'package:miuchio/data/upload/upload_adapters.dart';
import 'package:miuchio/data/upload/upload_outbox.dart';
import 'package:miuchio/diagnostics/debug_log.dart';
import 'package:miuchio/diagnostics/perf_probe.dart';
import 'package:miuchio/diagnostics/trace.dart';
import 'package:miuchio/domain/account/account_deletion.dart';
import 'package:miuchio/domain/account/account_gate.dart';
import 'package:miuchio/domain/account/local_identity.dart';
import 'package:miuchio/domain/account/sign_in_gate.dart';
import 'package:miuchio/domain/activity/activity_event.dart';
import 'package:miuchio/domain/activity/activity_recorder.dart';
import 'package:miuchio/domain/activity/activity_sync.dart';
import 'package:miuchio/domain/activity/trust_alarm.dart';
import 'package:miuchio/domain/albums/album_cleanup.dart';
import 'package:miuchio/domain/avatar/avatar_publisher.dart';
import 'package:miuchio/domain/upload/upload_coordinator.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/display_name.dart';
import 'package:miuchio/e2ee/epoch_api.dart';
import 'package:miuchio/e2ee/epoch_processor.dart';
import 'package:miuchio/e2ee/epoch_rotator.dart';
import 'package:miuchio/e2ee/expected_ik_resolver.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/e2ee/identity_label_map.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/e2ee/invite.dart';
import 'package:miuchio/e2ee/invite_api.dart';
import 'package:miuchio/e2ee/member_directory.dart';
import 'package:miuchio/e2ee/member_removal.dart';
import 'package:miuchio/e2ee/prekey_api.dart';
import 'package:miuchio/e2ee/rotation_recovery.dart';
import 'package:miuchio/secure_store/secure_key_store.dart';
import 'package:miuchio/ui/providers/album_summary_refresher.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'package:miuchio/ui/shelf/seen_store_impl.dart';
import 'package:miuchio/ui/shelf/shelf_covers_impl.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';
import 'package:miuchio/ui/shelf/shelf_view_preference.dart';

// Composition root: builds every service once, in dependency order, and hands
// them to the widget tree through providers
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PerfProbe.start();
  DebugLog.start();

  // Use libsodium for curve operations and cryptography_flutter for AEAD
  final sodium = await SodiumSumoInit.init();
  Sign.bindSodium(sodium);
  Kex.bindSodium(sodium);

  installErrorHandlers();

  final appState = AppState();
  final apiClient = ApiClient();
  final realtimeService = RealtimeService(apiClient);

  final secureKeyStore = createSecureKeyStore();
  try {
    await prepareInstall(
      isIOS: Platform.isIOS,
      supportDir: await getApplicationSupportDirectory(),
      wipeKeychain: () async {
        await secureKeyStore.wipeAll();
        await appSecureStorage.deleteAll();
      },
    );
  } catch (_) {
    // Without the marker the next launch retries the wipe
  }
  final labelMap = IdentityLabelMap();
  await labelMap.load();
  final prekeyApi = HttpPrekeyApi(ApiClientPrekeyJsonClient(apiClient));
  final identityService = IdentityService(
    store: secureKeyStore,
    labels: labelMap,
    api: prekeyApi,
  );

  // Persist vault ownership with its keys
  final accountOwner = AccountOwnerStore(secureKeyStore);
  final albumKeyStore = AlbumKeyStore(secureKeyStore);
  // The wrapper key must exist before any key backed store is used
  await secureKeyStore.initialize();
  unawaited(_prewarmAlbumKeyStore(albumKeyStore));
  final albumService = AlbumService();
  final displayNamePublisher = DisplayNamePublisher(
    ks: albumKeyStore,
    putProfileCt: (albumId, ct) => albumService.putProfileCt(albumId, ct),
  );
  final memberDirectory = MemberDirectory((albumId) async {
    final members = await albumService.listMembers(uuidFromBytes(albumId));
    final out = <MemberRecord>[];
    for (final m in members) {
      if (m.revoked) continue;
      final ik = m.profile.ikPub;
      final lk = m.profile.lkPub;
      if (ik == null || lk == null) continue;
      out.add(MemberRecord(
        memberToken: base64Decode(m.memberToken),
        ikPub: base64Decode(ik),
        lkPub: base64Decode(lk),
      ));
    }
    return out;
  });
  final epochApi = HttpEpochApi(data_epoch.ApiClientEpochJsonClient(apiClient));
  final inviteApi = HttpInviteApi(ApiClientInviteJsonClient(apiClient));
  final epochRotator = EpochRotator(
    epochs: epochApi,
    prekeys: prekeyApi,
    identity: identityService,
    aks: albumKeyStore,
    // Rotations fetch member bundles by token when user IDs are hidden
    memberBundles: prekeyApi,
  );
  final mediaApi = MediaApi(apiClient);
  final cacheRootKey = await loadOrCreateCacheRootKey(secureKeyStore);
  unawaited(DebugLog.attach(cacheRootKey));
  final nameCache = await NameCache.open(cacheRootKey: cacheRootKey);
  final ownAvatar = await OwnAvatarStore.open(cacheRootKey: cacheRootKey);
  final avatarApi = AvatarApi(apiClient);
  final avatarCache = await AvatarCache.open(
    cacheRootKey: cacheRootKey,
    fetch: avatarFetcher(albumKeyStore, avatarApi),
  );
  final avatarPublisher = AvatarPublisher(
    own: ownAvatar,
    albums: () => appState.albums,
    seal: avatarSealer(albumKeyStore),
    upload: avatarApi.upload,
    remove: avatarApi.remove,
  );
  bool isListed(String albumId) => appState.albums.any((a) => a.id == albumId);
  appState.attachAlbumNameResolver(albumNameResolver(
      cache: nameCache, albumKeys: albumKeyStore, isListed: isListed));
  appState.attachMemberNameResolver(memberNameResolver(
      cache: nameCache, albumKeys: albumKeyStore, isListed: isListed));
  // Identity pins and signer bindings remain sealed across logout
  final identityPinStore =
      await IdentityPinStore.open(cacheRootKey: cacheRootKey);
  // Remove creator markers left by a crash after epoch 0 installed
  for (final albumIdStr in identityPinStore.creatingAlbums) {
    final b = uuidToBytes(albumIdStr);
    if (b == null || await albumKeyStore.latestEpoch(b) >= 0) {
      await identityPinStore.clearCreating(albumIdStr);
    }
  }
  late final ActivityStore activityStore;
  late final ActivitySync activitySync;
  // Recompute unread state after repeated alarms or restarts
  Future<void> refreshUnread() async =>
      appState.setUnreadNotifications(await activityStore.hasUnseen());
  final identityTrust = IdentityTrust(
    identity: identityService,
    pins: identityPinStore,
    onChanged: (albumId, memberToken, newIkPub) {
      // Serialize with activity sync and account wipe
      unawaited(activitySync.alarm(() => recordTrustAlarm(
            record: activityStore.record,
            onRecorded: refreshUnread,
            albumId: uuidFromBytes(albumId),
            memberToken: memberToken,
            newIkPub: newIkPub,
            now: DateTime.now(),
          )));
    },
  );
  // Pin the invitee IK used to wrap the historical album keys
  final inviteInitiator = InviteInitiator(
    prekeys: prekeyApi,
    invites: inviteApi,
    identity: identityService,
    aks: albumKeyStore,
    pinner: InviteIdentityPinner(
      pinnedIk: (albumId, token) =>
          identityPinStore.pinnedIk(hexAlbumId(albumId), base64.encode(token)),
      pin: (albumId, token, ik) async {
        identityPinStore.pin(hexAlbumId(albumId), base64.encode(token), ik);
        await identityPinStore.flush();
      },
    ),
  );
  final mediaSealedCache =
      await MediaSealedCache.open(cacheRootKey: cacheRootKey);
  final uploadOutbox = await UploadOutboxStore.open(cacheRootKey: cacheRootKey);
  final deletionMarker = await DeletionMarkerFile.open();
  PendingDeletion? pendingDeletion;
  try {
    pendingDeletion = await deletionMarker.read();
  } catch (_) {}
  // Seed only the authenticated owner's shelf before the first network request
  var shelfSeedAllowed = false;
  try {
    final maySeed = AccountGate.maySeedShelf(
      boundOwner: await accountOwner.read(),
      storedUserId: await StorageService().getUserId(),
    );
    shelfSeedAllowed = maySeed;
    if (maySeed) {
      final localAlbums = await mediaSealedCache.loadAlbums();
      if (localAlbums.isNotEmpty) appState.setAlbums(localAlbums);
    }
  } catch (_) {}

  final signInGate = SignInGate(
    owner: accountOwner,
    readLocalIdentity: () => readLocalIdentity(secureKeyStore),
    hasResidualVault: residualVaultProbe(secureKeyStore, mediaSealedCache),
    readServerIdentity: serverIdentityReader(prekeyApi),
  );

  activityStore = await ActivityStore.open(cacheRootKey: cacheRootKey);
  final activityRecorder = ActivityRecorder(
    record: activityStore.record,
    readSnapshot: activityStore.readSnapshot,
    writeSnapshot: activityStore.writeSnapshot,
    fetchMedia: (albumId) async {
      try {
        return await mediaApi.listMedia(albumId);
      } catch (_) {
        return null;
      }
    },
    selfTokenFor: appState.selfMemberToken,
    settleRotation: activityStore.settleRotation,
    commit: activityStore.commit,
  );
  activitySync = ActivitySync(
    observe: activityRecorder.observe,
    current: () => appState.albums,
    afterEach: () async {
      await activityStore.prune(
          albumRowsBefore: DateTime.now().subtract(kActivityWindow));
      await refreshUnread();
    },
  );
  if (shelfSeedAllowed) {
    try {
      await refreshUnread();
    } catch (_) {}
  }
  // Use the same listing for activity and deletion reconciliation
  appState.attachListingApplied(() {
    unawaited(activitySync.listed());
    unawaited(avatarPublisher.sync());
  });

  appState.attachShelfPersistence(mediaSealedCache.saveAlbums);
  final mediaPlaintextCache = MediaPlaintextCache();
  // Seen state must survive media cache eviction
  final seenStore = await SealedSeenStore.open(cacheRootKey: cacheRootKey);
  final mediaCacheManager = MediaCacheManager(
    plaintext: mediaPlaintextCache,
    ciphertext: mediaSealedCache,
    api: mediaApi,
    aks: albumKeyStore,
  );
  final shelfCovers = ShelfCoversImpl(
    sealedCache: mediaSealedCache,
    cache: mediaCacheManager,
  );
  void seedWatermarks() {
    for (final a in appState.albums) {
      if (!a.hasSummary) continue;
      if (!seenStore.knows(a.id)) {
        unawaited(seenStore.markSeen(a.id, a.mediaGeneration));
      }
    }
  }

  appState.addListener(seedWatermarks);
  seedWatermarks();

  appState.attachSummaryRefresh(() async {
    final fresh = await albumService.getMyAlbums();
    if (fresh != null) appState.applyListing(fresh);
  });

  final expectedIkResolver = ExpectedIkResolver.responder(
    selfToken: (albumId) {
      final t = appState.selfMemberToken(uuidFromBytes(albumId));
      return t == null ? null : base64.decode(base64.normalize(t));
    },
    pinned: (albumId, token) =>
        identityPinStore.pinnedIk(hexAlbumId(albumId), base64.encode(token)),
    // Roster discovery must never grant epoch signing authority
    signerPinned: (albumId, token) =>
        identityPinStore.signerIk(hexAlbumId(albumId), base64.encode(token)),
    currentIk: identityService.currentIkPub,
    // Only the creator may sign before epoch 0 installs
    soleSigner: (albumId) =>
        identityPinStore.isCreating(uuidFromBytes(albumId)),
    pin: (albumId, token, ik) async {
      identityPinStore.pinSigner(hexAlbumId(albumId), base64.encode(token), ik);
      await identityPinStore.flush();
    },
  );
  final epochProcessor = EpochProcessor(
    api: epochApi,
    identity: identityService,
    store: albumKeyStore,
    directory: memberDirectory,
    signerGate: expectedIkResolver,
    invites: inviteApi,
  );
  epochProcessor.blocked.listen((b) {
    // The album banner shows one plain message, so the reason lives here
    Trace.event('epoch.blocked', fields: {
      'album': Trace.id(uuidFromBytes(b.albumId)),
      'epoch': b.epoch,
      'reason': b.reason.name,
    });
    DebugLog.record(DebugEvent.albumBlocked,
        reason: b.reason.name, op: DebugLog.op(hexAlbumId(b.albumId)));
    appState.setKeyBlock(uuidFromBytes(b.albumId), b);
  });
  late final RotationRecoveryScheduler rotationRecovery;
  late final UploadQueueModel uploadQueue;
  epochProcessor.unblocked.listen((e) {
    appState.clearKeyBlock(uuidFromBytes(e.albumId), e.epoch);
    rotationRecovery.onEpochInstalled(e.albumId);
  });
  Future<bool> isRotationRequired(Uint8List albumId) async {
    final cur = await epochApi.getCurrentEpoch(uuidFromBytes(albumId));
    return cur?.rotationRequired ?? false;
  }

  // Resume uploads only after installing the authoritative epoch
  Future<void> reconcileAlbumKeys(Uint8List albumId) async {
    final cur = await epochApi.getCurrentEpoch(uuidFromBytes(albumId));
    if (cur == null) return;
    await epochProcessor.handleEvent(albumId: albumId, epoch: cur.currentEpoch);
  }

  late final AlbumWipe wipeLocalAlbum;

  final memberRemoval = MemberRemovalCoordinator(
    revoke: (albumId, token) =>
        albumService.removeMember(uuidFromBytes(albumId), base64.encode(token)),
    activeTokens: (albumId) async {
      final members = await albumService.listMembers(uuidFromBytes(albumId));
      return [
        for (final m in members)
          if (!m.revoked) base64.decode(base64.normalize(m.memberToken)),
      ];
    },
    currentEpoch: (albumId) => albumKeyStore.latestEpoch(albumId),
    rotate: (albumId, epoch, recipients) => epochRotator.rotate(
        albumIdBytes: albumId, epoch: epoch, recipients: recipients),
    expectedIk: expectedIkResolver.call,
    dropDirectory: (albumId, token) => memberDirectory.drop(albumId, token),
    wipeLocalAlbum: (albumId) => wipeLocalAlbum(albumId),
    isRotationRequired: isRotationRequired,
  );
  final albumCleanup = AlbumCleanupQueue(
    store: mediaSealedCache,
    probe: albumService.probeAlbum,
    wipe: (albumStr) async {
      final albumId = uuidToBytes(albumStr);
      if (albumId != null) await memberRemoval.onSelfRemoved(albumId);
    },
  );
  rotationRecovery = RotationRecoveryScheduler(
    isRotationRequired: isRotationRequired,
    canRotate: (albumId) => appState.isAdminOf(uuidFromBytes(albumId)),
    recover: memberRemoval.recoverIfPending,
    reconcile: reconcileAlbumKeys,
  );
  rotationRecovery.status.listen((s) {
    appState.setRotationStatus(uuidFromBytes(s.albumId), s);
  });
  appState.attachRotationPrompt((albumId) {
    final b = uuidToBytes(albumId);
    if (b != null) unawaited(rotationRecovery.request(b));
  });

  ApiClient.onMemberRevoked = (albumStr) {
    unawaited(albumCleanup.albumGone(albumStr).catchError((_) {}));
  };
  void onAlbumDeleted(String albumStr) {
    appState.markAlbumDeleted(albumStr);
    unawaited(albumCleanup.albumGone(albumStr).catchError((_) {}));
  }

  ApiClient.onNotMember = onAlbumDeleted;
  // Probe omissions because listings can race album creation
  appState.attachAlbumsVanished((ids) {
    for (final id in ids) {
      unawaited(albumCleanup.albumMissing(id).catchError((_) {}));
    }
  });
  unawaited(albumCleanup.drain());

  final realtimeRouter = RealtimeRouter(
    identity: identityService,
    epochProcessor: epochProcessor,
    mediaCache: mediaCacheManager,
    appState: appState,
    activitySync: activitySync,
    albumCleanup: albumCleanup,
    memberRemoval: memberRemoval,
    rotationRecovery: rotationRecovery,
    onAlbumDeleted: onAlbumDeleted,
  );
  realtimeService.stream.listen(realtimeRouter.handle);

  epochProcessor.joinedAlbums.listen((albumIdBytes) async {
    final albumIdStr = uuidFromBytes(albumIdBytes);
    await appState
        .refreshAlbumOnJoin(albumIdStr, albumService)
        .catchError((_) {});
    final name = appState.profileName;
    if (name.isEmpty) return;
    String? tok;
    for (final a in appState.albums) {
      if (a.id == albumIdStr) {
        tok = a.memberToken;
        break;
      }
    }
    if (tok == null) return;
    try {
      final tokenBytes = base64Decode(tok);
      await displayNamePublisher.publishToAlbum(
          albumId: albumIdStr, memberToken: tokenBytes, name: name);
    } catch (_) {}
  });

  final summaryRefresher = AlbumSummaryRefresher(
    fetch: albumService.getMyAlbums,
    apply: appState.applyListing,
  );
  final pickedSources = PickedSourceStoreImpl();
  final mediaPreparer = MediaPreparerImpl(albumKeyStore, uploadOutbox,
      owner: () => appState.userId, transcode: platformImageTranscoder);
  final uploadCoordinator = UploadCoordinator(
    sources: pickedSources,
    onRotationPending: (albumId) {
      final b = uuidToBytes(albumId);
      if (b != null) unawaited(rotationRecovery.request(b));
    },
    onConfirmed: (albumId, generation) =>
        unawaited(seenStore.markOwn(albumId, generation)),
    preparer: mediaPreparer,
    uploader: StagedMediaUploader(mediaApi),
    sink: UploadCacheSink(
      mediaCacheManager,
      (albumId) => summaryRefresher.refresh(),
      onPreview: (mediaId, thumb) => uploadQueue.putPreview(mediaId, thumb),
      selfToken: appState.selfMemberToken,
    ),
  );
  uploadQueue = UploadQueueModel(uploadCoordinator);
  wipeLocalAlbum = AlbumWipe(
    uploadQueue: uploadQueue,
    uploadOutbox: uploadOutbox,
    shelfCovers: shelfCovers,
    mediaCache: mediaCacheManager,
    sealedCache: mediaSealedCache,
    seenStore: seenStore,
    albumKeys: albumKeyStore,
    appState: appState,
    nameCache: nameCache,
    avatarCache: avatarCache,
    ownAvatar: ownAvatar,
    identityTrust: identityTrust,
    identityPins: identityPinStore,
    rotationRecovery: rotationRecovery,
  );
  // Restore the outbox only after its owning account is known
  appState.attachUserKnown((userId) {
    unawaited(StorageService().saveUserId(userId));
    unawaited(uploadQueue.restore());
  });
  unawaited(pickedSources.sweepStaleStaging());
  appState.attachUploadResume(uploadCoordinator.resumeAlbum);

  // Stop network and plaintext writes before clearing stores
  // Wipe steps must tolerate retries
  var catalogClosed = false;
  final terminalWipe = TerminalWipe(
    steps: [
      (name: 'network', run: () async => ApiClient.terminate()),
      (name: 'realtime', run: realtimeService.terminate),
      (name: 'uploads', run: uploadQueue.shutdown),
      (name: 'avatar sync', run: avatarPublisher.stop),
      (name: 'prepared photo', run: () async => mediaPreparer.wipeMemory()),
      (name: 'album cleanup', run: albumCleanup.shutdown),
      (name: 'covers', run: shelfCovers.shutdown),
      (name: 'downloads', run: mediaCacheManager.shutdown),
      (name: 'auth', run: StorageService().deleteAuth),
      (name: 'session', run: () async => appState.reset()),
      (
        name: 'catalog',
        run: () async {
          if (catalogClosed) return;
          await mediaCacheManager.clearAll();
          await mediaSealedCache.saveAlbums(const []);
          await mediaSealedCache.close();
          catalogClosed = true;
        }
      ),
      (name: 'outbox', run: uploadOutbox.clearAll),
      (name: 'activity sync', run: activitySync.stop),
      (name: 'activity', run: activityStore.clearAll),
      (name: 'names', run: nameCache.clear),
      (name: 'avatars', run: avatarCache.clearAll),
      (name: 'own avatar', run: ownAvatar.wipe),
      (name: 'pins', run: identityPinStore.clear),
      (name: 'seen', run: seenStore.clear),
      (name: 'debug log', run: DebugLog.shutdown),
      // Block late key installs before deleting the keystore
      (name: 'key handles', run: () async => albumKeyStore.forgetAll()),
      (name: 'labels', run: labelMap.clearAll),
      (name: 'keystore', run: secureKeyStore.wipeAll),
      (name: 'secure storage', run: () => appSecureStorage.deleteAll()),
      (
        name: 'preferences',
        run: () async => (await SharedPreferences.getInstance()).clear()
      ),
      (
        name: 'support dir',
        run: () async => emptyDir(await getApplicationSupportDirectory())
      ),
      (
        name: 'cache dir',
        run: () async => emptyDir(await getApplicationCacheDirectory())
      ),
      (
        name: 'temp dir',
        run: () async => emptyDir(await getTemporaryDirectory())
      ),
      (
        name: 'cache key',
        run: () async => cacheRootKey.fillRange(0, cacheRootKey.length, 0)
      ),
    ],
    leftovers: () => wipeLeftovers(secureKeyStore),
  );
  final accountDeletion = AccountDeletion(
    api: HttpAccountDeletionApi(apiClient),
    marker: deletionMarker,
    wipe: terminalWipe.run,
    random: Csprng.bytes,
  );

  realtimeService.connected.listen((_) {
    unawaited(albumCleanup.drain());
    unawaited(realtimeRouter.catchUpAfterReconnect());
  });

  // Load before the first frame to avoid a visible layout jump
  final shelfView =
      await ShelfViewPreference.load(await SharedPreferences.getInstance());

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider.value(value: realtimeService),
        Provider<IdentityLabelMap>.value(value: labelMap),
        Provider<IdentityService>.value(value: identityService),
        Provider<AlbumKeyStore>.value(value: albumKeyStore),
        Provider<MemberDirectory>.value(value: memberDirectory),
        Provider<EpochProcessor>.value(value: epochProcessor),
        Provider<EpochRotator>.value(value: epochRotator),
        Provider<MemberRemovalCoordinator>.value(value: memberRemoval),
        Provider<RotationRecoveryScheduler>.value(value: rotationRecovery),
        Provider<DisplayNamePublisher>.value(value: displayNamePublisher),
        Provider<NameCache>.value(value: nameCache),
        ChangeNotifierProvider<OwnAvatarStore>.value(value: ownAvatar),
        ChangeNotifierProvider<AvatarCache>.value(value: avatarCache),
        Provider<AvatarPublisher>.value(value: avatarPublisher),
        Provider<IdentityTrust>.value(value: identityTrust),
        Provider<IdentityPinStore>.value(value: identityPinStore),
        Provider<InviteInitiator>.value(value: inviteInitiator),
        Provider<MediaCacheManager>.value(value: mediaCacheManager),
        Provider<MediaSealedCache>.value(value: mediaSealedCache),
        Provider<MediaCatalog>.value(value: mediaSealedCache),
        Provider<AlbumCatalog>.value(value: mediaSealedCache),
        ListenableProvider<ShelfCovers>.value(value: shelfCovers),
        ListenableProvider<SeenStore>.value(value: seenStore),
        Provider<SodiumSumo>.value(value: sodium),
        Provider<MediaApi>.value(value: mediaApi),
        ChangeNotifierProvider<UploadQueueModel>.value(value: uploadQueue),
        Provider<AccountDeletion>.value(value: accountDeletion),
        Provider<SignInGate>.value(value: signInGate),
        Provider<ActivityFeed>.value(value: activityStore),
        Provider<ActivityStore>.value(value: activityStore),
        Provider<ActivitySync>.value(value: activitySync),
        ChangeNotifierProvider<ShelfViewPreference>.value(value: shelfView),
        Provider<TerminalWipe>.value(value: terminalWipe),
        Provider<AccountOwnerStore>.value(value: accountOwner),
      ],
      child: MiuchioApp(
        mediaCacheManager: mediaCacheManager,
        shelfCovers: shelfCovers,
        resumeDeletion: pendingDeletion == null ? null : accountDeletion,
      ),
    ),
  );
}

Future<void> _prewarmAlbumKeyStore(AlbumKeyStore aks) async {
  try {
    await aks.initialize();
  } catch (_) {}
}
