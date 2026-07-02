import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../data/buffer_db.dart';

/// Point d'entrée du service de premier plan (isolate dédié).
@pragma('vm:entry-point')
void startLocationCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

/// Capture la position à intervalle régulier, la met en file (offline-safe),
/// puis tente de vider la file vers l'API CarbTrack. Pousse l'état vers l'UI.
///
/// Mode « track » hybride : la conduite (>= 20 km/h) déclenche l'envoi de
/// chaque point pour un profil de vitesse précis ; à l'arrêt, seul un signal
/// de présence est envoyé toutes les 5 min (économie data/batterie).
class LocationTaskHandler extends TaskHandler {
  static const _driveStartKmh = 20.0; // au-dessus : conduite détectée
  static const _driveEndKmh = 8.0;    // en dessous pendant _driveEndAfter : fin
  static const _driveEndAfter = Duration(minutes: 3);
  static const _idleHeartbeat = Duration(minutes: 5);

  final BufferDb _buffer = BufferDb();
  final _uuid = const Uuid();

  String? _baseUrl;
  String? _token;
  String _mode = 'track'; // 'track' (suivi) ou 'record' (enregistrement itinéraire)
  bool _busy = false;

  bool _driving = false;
  DateTime? _slowSince;   // début de la période lente (hystérésis de fin)
  DateTime? _lastQueued;  // dernier point mis en file (cadence du heartbeat)

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _baseUrl = await FlutterForegroundTask.getData<String>(key: 'baseUrl');
    _token = await FlutterForegroundTask.getData<String>(key: 'token');
    _mode = await FlutterForegroundTask.getData<String>(key: 'mode') ?? 'track';
    await _buffer.open();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _tick();
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      if (_mode == 'record') {
        await _record(pos);
      } else {
        _updateDriving(pos);
        // État courant ; _flush affinera (hors couloir / en attente) s'il envoie.
        FlutterForegroundTask.updateService(
          notificationTitle: _driving
              ? 'En conduite · ${(pos.speed * 3.6).round()} km/h'
              : 'Suivi actif · veille',
          notificationText: _driving
              ? 'Trajet envoyé en temps réel'
              : 'Signal de présence toutes les 5 min',
        );
        if (_shouldQueue(pos)) {
          await _capture(pos);
          _lastQueued = DateTime.now();
        }
        await _flush();
      }
    } catch (_) {
      // Silencieux : on réessaiera au prochain tick (les points sont persistés).
    } finally {
      _busy = false;
    }
  }

  /// Mode enregistrement : accumule le point du tracé et pousse le compteur à l'UI.
  Future<void> _record(Position pos) async {
    await _buffer.insertRoutePoint(
        pos.latitude, pos.longitude, pos.timestamp.toUtc().toIso8601String());
    final count = await _buffer.routePointCount();
    FlutterForegroundTask.updateService(
      notificationTitle: 'Enregistrement d\'itinéraire',
      notificationText: '$count point(s) · trajet en cours…',
    );
    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'record': true,
      'points': count,
      'lat': pos.latitude,
      'lng': pos.longitude,
    }));
  }

  /// Machine à états conduite/arrêt, avec hystérésis pour ignorer les
  /// ralentissements passagers (feu, barrière, croisement).
  void _updateDriving(Position pos) {
    final kmh = pos.speed * 3.6;
    if (kmh >= _driveStartKmh) {
      _driving = true;
      _slowSince = null;
      return;
    }
    if (!_driving) return;
    if (kmh < _driveEndKmh) {
      _slowSince ??= DateTime.now();
      if (DateTime.now().difference(_slowSince!) >= _driveEndAfter) {
        _driving = false;
        _slowSince = null;
      }
    } else {
      _slowSince = null; // entre 8 et 20 km/h : la conduite continue
    }
  }

  /// En conduite : chaque point. À l'arrêt : un heartbeat toutes les 5 min.
  bool _shouldQueue(Position pos) {
    if (_driving) return true;
    final last = _lastQueued;
    return last == null || DateTime.now().difference(last) >= _idleHeartbeat;
  }

  Future<void> _capture(Position pos) async {
    await _buffer.insert({
      'client_id': _uuid.v4(),
      'lat': pos.latitude,
      'lng': pos.longitude,
      'ts': pos.timestamp.toUtc().toIso8601String(),
      'speed': pos.speed,
      'accuracy': pos.accuracy,
    });
  }

  Future<void> _flush() async {
    final baseUrl = _baseUrl, token = _token;
    if (baseUrl == null || token == null) return;

    final batch = await _buffer.takeBatch(50);
    if (batch.isEmpty) return;

    final api = CarbTrackApi(baseUrl: baseUrl, token: token);
    final results = await api.postPositions(batch);

    // Tous les client_id renvoyés (ok ou duplicate) sont purgeables.
    final acked = results.map((r) => r.clientId).toList();
    await _buffer.deleteClientIds(acked);

    final pending = await _buffer.count();
    final last = batch.last;
    final lastResult = results.isNotEmpty ? results.last : null;
    final offRoute = lastResult?.offRoute ?? false;

    FlutterForegroundTask.updateService(
      notificationTitle: offRoute ? '⚠️ Hors itinéraire' : 'Suivi actif',
      notificationText: pending > 0
          ? 'En attente d\'envoi : $pending position(s)'
          : 'Position transmise',
    );

    FlutterForegroundTask.sendDataToMain(jsonEncode({
      'lat': last['lat'],
      'lng': last['lng'],
      'ts': last['ts'],
      'off_route': offRoute,
      'dist_m': lastResult?.distM,
      'pending': pending,
    }));
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Ne pas fermer la base ici : sqflite partage un seul handle natif par
    // fichier entre les isolates. Le fermer ici casserait le BufferDb encore
    // ouvert côté UI (DatabaseException database_closed). L'OS libère le
    // handle à la mort du processus.
  }
}
