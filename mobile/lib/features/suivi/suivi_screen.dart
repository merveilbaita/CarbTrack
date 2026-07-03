import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../core/server_config.dart';
import '../../tracking/tracking_service.dart';
import '../../widgets/info_tile.dart';

/// Onglet « Suivi » (option) : démarrer/arrêter le suivi GPS continu + état.
class SuiviScreen extends StatefulWidget {
  const SuiviScreen({super.key, required this.config});
  final ServerConfig config;

  @override
  State<SuiviScreen> createState() => _SuiviScreenState();
}

class _SuiviScreenState extends State<SuiviScreen> {
  bool _running = false;
  bool _working = false;
  Map<String, dynamic>? _status;

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _refreshRunning();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    super.dispose();
  }

  void _onTaskData(Object data) {
    if (data is! String) return;
    try {
      final map = jsonDecode(data) as Map<String, dynamic>;
      if (mounted) setState(() => _status = map);
    } catch (_) {}
  }

  Future<void> _refreshRunning() async {
    final r = await TrackingService.isRunning();
    if (mounted) setState(() => _running = r);
  }

  Future<void> _start() async {
    setState(() => _working = true);
    final ok = await TrackingService.requestPermissions();
    if (!ok) {
      if (mounted) {
        setState(() => _working = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Autorisez la localisation « Toujours » pour le suivi continu.',
            ),
          ),
        );
      }
      return;
    }
    await TrackingService.start(widget.config);
    await _refreshRunning();
    if (mounted) setState(() => _working = false);
  }

  Future<void> _stop() async {
    setState(() => _working = true);
    await TrackingService.stop();
    await _refreshRunning();
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final offRoute = _status?['off_route'] == true;
    final pending = _status?['pending'];
    final lat = _status?['lat'];
    final lng = _status?['lng'];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _running
                ? (offRoute ? cs.errorContainer : cs.primaryContainer)
                : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Icon(
                _running
                    ? (offRoute
                          ? Icons.warning_amber_rounded
                          : Icons.gps_fixed_rounded)
                    : Icons.gps_off_rounded,
                color: _running
                    ? (offRoute ? cs.error : cs.primary)
                    : cs.outline,
                size: 28,
              ),
              const SizedBox(width: 12),
              Text(
                _running
                    ? (offRoute ? 'Hors itinéraire' : 'Suivi actif')
                    : 'Suivi arrêté',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        InfoTile(
          icon: Icons.my_location_rounded,
          label: 'Dernière position',
          value: (lat != null && lng != null)
              ? '${(lat as num).toStringAsFixed(5)}, ${(lng as num).toStringAsFixed(5)}'
              : '—',
        ),
        InfoTile(
          icon: Icons.route_rounded,
          label: 'Écart au couloir',
          value: offRoute && _status?['dist_m'] != null
              ? '${(_status!['dist_m'] as num).round()} m (hors)'
              : (_running ? 'Dans le couloir' : '—'),
        ),
        InfoTile(
          icon: Icons.cloud_upload_rounded,
          label: 'En attente d\'envoi',
          value: pending == null ? '—' : '$pending position(s)',
        ),
        const SizedBox(height: 24),
        if (_running)
          FilledButton.tonalIcon(
            onPressed: _working ? null : _stop,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('Arrêter le suivi'),
          )
        else
          FilledButton.icon(
            onPressed: _working ? null : _start,
            icon: _working
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Démarrer le suivi'),
          ),
        const SizedBox(height: 12),
        Text(
          'Le suivi continue en arrière-plan tant que le service est actif. '
          'Une notification persistante l\'indique.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.outline),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
