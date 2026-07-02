import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/server_config.dart';
import 'location_task_handler.dart';

/// Pilote le service de premier plan de suivi GPS (démarrage, permissions, arrêt).
class TrackingService {
  static const _trackMs = 10000;  // suivi : échantillon toutes les 10 s
                                  // (l'envoi est filtré : conduite vs veille)
  static const _recordMs = 5000;  // enregistrement itinéraire : 1 point / 5 s

  /// Configure le canal de notification + l'intervalle du service.
  static void _init(int intervalMs) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'carbtrack_tracking',
        channelName: 'Suivi GPS CarbTrack',
        channelDescription: 'Indique que le suivi de position est actif.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(intervalMs),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// À appeler une fois au démarrage de l'app.
  static void initService() => _init(_trackMs);

  /// Demande, dans l'ordre, les permissions nécessaires au suivi continu.
  /// Retourne true si la localisation en arrière-plan est accordée.
  static Future<bool> requestPermissions() async {
    // 1) Notifications (Android 13+)
    final notif = await FlutterForegroundTask.checkNotificationPermission();
    if (notif != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    // 2) Localisation « pendant l'utilisation »
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }

    // 3) Localisation « toujours » (arrière-plan) — requise pour le 24/7
    final always = await Permission.locationAlways.request();

    // 4) Ignorer l'optimisation batterie (fiabilité du service)
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    return always.isGranted;
  }

  /// Démarre le suivi normal (envoi des positions à l'API).
  static Future<ServiceRequestResult> start(ServerConfig config) async {
    _init(_trackMs);
    await FlutterForegroundTask.saveData(key: 'baseUrl', value: config.baseUrl);
    await FlutterForegroundTask.saveData(key: 'token', value: config.token);
    await FlutterForegroundTask.saveData(key: 'mode', value: 'track');

    if (await FlutterForegroundTask.isRunningService) {
      return FlutterForegroundTask.restartService();
    }
    return FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'Suivi actif',
      notificationText: 'Démarrage du suivi GPS…',
      callback: startLocationCallback,
    );
  }

  /// Démarre l'enregistrement d'un itinéraire (accumule les points localement).
  static Future<ServiceRequestResult> startRecording() async {
    _init(_recordMs);
    await FlutterForegroundTask.saveData(key: 'mode', value: 'record');

    if (await FlutterForegroundTask.isRunningService) {
      return FlutterForegroundTask.restartService();
    }
    return FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'Enregistrement d\'itinéraire',
      notificationText: 'Trajet en cours…',
      callback: startLocationCallback,
    );
  }

  /// Démarrage automatique à l'ouverture de l'app (session chauffeur) :
  /// la conduite est détectée par le service, sans action du chauffeur.
  /// Retourne false si les permissions manquent (démarrage manuel possible).
  static Future<bool> ensureStarted(ServerConfig config) async {
    if (await FlutterForegroundTask.isRunningService) return true;
    final ok = await requestPermissions();
    if (!ok) return false;
    await start(config);
    return true;
  }

  static Future<ServiceRequestResult> stop() =>
      FlutterForegroundTask.stopService();

  static Future<bool> isRunning() => FlutterForegroundTask.isRunningService;
}
