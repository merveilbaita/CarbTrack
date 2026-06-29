import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/server_config.dart';
import 'location_task_handler.dart';

/// Pilote le service de premier plan de suivi GPS (démarrage, permissions, arrêt).
class TrackingService {
  static const _intervalMs = 20000; // 20 s

  /// Configure le canal de notification + les options du service. À appeler une fois.
  static void initService() {
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
        eventAction: ForegroundTaskEventAction.repeat(_intervalMs),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

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

  static Future<ServiceRequestResult> start(ServerConfig config) async {
    await FlutterForegroundTask.saveData(key: 'baseUrl', value: config.baseUrl);
    await FlutterForegroundTask.saveData(key: 'token', value: config.token);

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

  static Future<ServiceRequestResult> stop() =>
      FlutterForegroundTask.stopService();

  static Future<bool> isRunning() => FlutterForegroundTask.isRunningService;
}
