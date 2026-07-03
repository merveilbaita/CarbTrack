import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
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
  bool _loadingFleet = false;
  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _fleet = const [];

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _refreshRunning();
    _loadFleet();
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

  Future<void> _loadFleet() async {
    if (mounted) setState(() => _loadingFleet = true);
    try {
      final api = CarbTrackApi(
        baseUrl: widget.config.baseUrl,
        token: widget.config.token,
      );
      final positions = await api.getLatestPositions();
      positions.sort((a, b) => '${a['driver']}'.compareTo('${b['driver']}'));
      if (mounted) setState(() => _fleet = positions);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _loadingFleet = false);
    }
  }

  Future<void> _startNavigation(Map<String, dynamic> position) async {
    final lat = (position['lat'] as num?)?.toDouble();
    final lng = (position['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;

    final navUri = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
    if (await canLaunchUrl(navUri)) {
      await launchUrl(navUri, mode: LaunchMode.externalApplication);
      return;
    }

    final webUri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '$lat,$lng',
      'travelmode': 'driving',
    });
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  }

  String _ageLabel(String? iso) {
    if (iso == null || iso.isEmpty) return 'heure inconnue';
    final ts = DateTime.tryParse(iso);
    if (ts == null) return 'heure inconnue';
    final minutes = DateTime.now().difference(ts.toLocal()).inMinutes;
    if (minutes < 2) return 'à l\'instant';
    if (minutes < 90) return 'il y a $minutes min';
    return 'il y a ${(minutes / 60).round()} h';
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
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                'Dépannage',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              tooltip: 'Actualiser',
              onPressed: _loadingFleet ? null : _loadFleet,
              icon: _loadingFleet
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_fleet.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              _loadingFleet
                  ? 'Chargement des engins…'
                  : 'Aucune position récente disponible.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          )
        else
          ..._fleet.map((p) {
            final offRoute = p['off_route'] == true;
            final vehicle = p['vehicle'];
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      offRoute
                          ? Icons.warning_amber_rounded
                          : Icons.local_shipping_outlined,
                      color: offRoute ? cs.error : cs.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${p['driver']}${vehicle != null ? ' · $vehicle' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            offRoute && p['dist_m'] != null
                                ? '${_ageLabel(p['recorded_at'] as String?)} · hors couloir ${(p['dist_m'] as num).round()} m'
                                : _ageLabel(p['recorded_at'] as String?),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: cs.outline),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _startNavigation(p),
                      icon: const Icon(Icons.navigation_rounded),
                      label: const Text('Démarrer'),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}
