import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'server_config.dart';

/// Persistance chiffrée (Android Keystore) de la configuration serveur + token.
class ConfigStore {
  static const _key = 'carbtrack_server_config';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<void> save(ServerConfig config) =>
      _storage.write(key: _key, value: config.encode());

  static Future<ServerConfig?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ServerConfig.decode(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() => _storage.delete(key: _key);
}
