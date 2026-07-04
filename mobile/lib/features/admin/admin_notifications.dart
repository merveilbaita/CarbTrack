import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';

class AdminNotifications {
  AdminNotifications(this.config);

  static const _lastSeenKey = 'carbtrack_admin_last_notified_event_id';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final ServerConfig config;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  Timer? _timer;
  int? _lastSeenId;

  Future<void> start() async {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();

    _lastSeenId = int.tryParse(await _storage.read(key: _lastSeenKey) ?? '');
    await check();
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => check());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> check() async {
    try {
      final api = CarbTrackApi(baseUrl: config.baseUrl, token: config.token);
      final events = await api.getEvents(date: _today());
      if (events.isEmpty) return;

      final newestId = (events.first['id'] as num?)?.toInt();
      if (newestId == null) return;
      final previous = _lastSeenId;
      _lastSeenId = newestId;
      await _storage.write(key: _lastSeenKey, value: '$newestId');
      if (previous == null) return;

      final fresh = events.where((e) {
        final id = (e['id'] as num?)?.toInt() ?? 0;
        return id > previous && _isNotifiable(e);
      }).toList();
      for (final event in fresh.reversed) {
        await _notify(event);
      }
    } catch (_) {
      // Les notifications ne doivent jamais perturber l'interface admin.
    }
  }

  bool _isNotifiable(Map<String, dynamic> event) {
    final kind = event['kind'];
    return kind == 'stop' || kind == 'zone_enter' || kind == 'zone_exit';
  }

  Future<void> _notify(Map<String, dynamic> event) async {
    final id = (event['id'] as num?)?.toInt() ?? 0;
    final vehicle = event['vehicle'];
    await _plugin.show(
      id,
      '${event['kind_label'] ?? 'Événement CarbTrack'}',
      '${event['driver']}${vehicle != null ? ' · $vehicle' : ''} — ${event['message'] ?? ''}',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'carbtrack_admin_events',
          'Événements CarbTrack',
          channelDescription: 'Nouveaux événements du journal superviseur.',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  String _today() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
