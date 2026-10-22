import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// The iOS plugin filters bulk reads and deletes by accessibility, so every
// caller must share these options
// Tokens and identity sidecars cannot migrate to another device, matching
// the Secure Enclave wrapper key
// The App Group matches SecureEnclaveBridge.ACCESS_GROUP so items survive an
// App Store transfer to another Team ID
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    groupId: 'group.com.freytastic.miuchio',
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);
