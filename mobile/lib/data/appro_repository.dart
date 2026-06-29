import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/server_config.dart';
import 'app_db.dart';

/// Logique métier des appros : cache véhicules, file offline, synchronisation.
class ApproRepository {
  ApproRepository(this.config);
  final ServerConfig config;
  final _db = AppDb.instance;
  final _uuid = const Uuid();

  CarbTrackApi get _api =>
      CarbTrackApi(baseUrl: config.baseUrl, token: config.token);

  Future<void> open() => _db.open();

  /// Rafraîchit le cache des véhicules depuis le serveur (silencieux si hors ligne).
  Future<void> pullVehicles() async {
    try {
      final vehicles = await _api.getVehicles();
      await _db.replaceVehicles(vehicles);
    } catch (_) {
      // Hors ligne : on garde le cache existant.
    }
  }

  Future<List<Map<String, dynamic>>> cachedVehicles() => _db.vehicles();

  Future<int> pendingCount() => _db.pendingApproCount();

  /// Enregistre un appro : mise en file locale immédiate, puis tentative d'envoi.
  /// Retourne true si l'appro a été synchronisé tout de suite.
  Future<bool> saveAppro({
    required String date,
    required int vehicleId,
    required double indexPrecedent,
    required double indexActuel,
    required double qteLitres,
  }) async {
    await _db.enqueueAppro({
      'client_id': _uuid.v4(),
      'date': date,
      'vehicle_id': vehicleId,
      'index_precedent': indexPrecedent,
      'index_actuel': indexActuel,
      'qte_litres': qteLitres,
    });
    await _db.bumpVehicleIndex(vehicleId, indexActuel);
    return sync();
  }

  /// Pousse les appros en attente. Retourne true si tout est parti.
  Future<bool> sync() async {
    final pending = await _db.pendingAppros();
    if (pending.isEmpty) return true;
    try {
      final acked = await _api.postAppros(pending);
      await _db.deleteAppros(acked);
      return await _db.pendingApproCount() == 0;
    } catch (_) {
      return false; // reste en file, réessai plus tard
    }
  }

  /// Historique récent (serveur). Vide si hors ligne.
  Future<List<Map<String, dynamic>>> recentAppros() async {
    try {
      return await _api.getRecentAppros();
    } catch (_) {
      return const [];
    }
  }
}
