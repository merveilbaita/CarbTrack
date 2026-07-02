import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';
import '../../data/buffer_db.dart';
import '../../tracking/tracking_service.dart';

/// Enregistrement d'un itinéraire terrain (superviseur) : rouler → terminer → envoyer.
class RouteRecorderScreen extends StatefulWidget {
  const RouteRecorderScreen({super.key, required this.config});
  final ServerConfig config;

  @override
  State<RouteRecorderScreen> createState() => _RouteRecorderScreenState();
}

class _RouteRecorderScreenState extends State<RouteRecorderScreen> {
  final _buffer = BufferDb();
  bool _recording = false;
  bool _working = false;
  int _points = 0;

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _init();
  }

  Future<void> _init() async {
    await _buffer.open();
    final running = await TrackingService.isRunning();
    final count = await _buffer.routePointCount();
    if (mounted) {
      setState(() {
        _recording = running;
        _points = count;
      });
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    super.dispose();
  }

  void _onData(Object data) {
    if (data is! String) return;
    try {
      final m = jsonDecode(data) as Map<String, dynamic>;
      if (m['record'] == true && mounted) {
        setState(() => _points = (m['points'] as num?)?.toInt() ?? _points);
      }
    } catch (_) {}
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _start() async {
    setState(() => _working = true);
    final ok = await TrackingService.requestPermissions();
    if (!ok) {
      if (mounted) {
        setState(() => _working = false);
        _snack('Autorisez la localisation « Toujours » pour enregistrer.');
      }
      return;
    }
    await _buffer.clearRoutePoints();
    await TrackingService.startRecording();
    if (mounted) {
      setState(() {
        _working = false;
        _recording = true;
        _points = 0;
      });
    }
  }

  Future<void> _stop() async {
    setState(() => _working = true);
    await TrackingService.stop();
    final points = await _buffer.routePoints();
    if (mounted) {
      setState(() {
        _recording = false;
        _working = false;
      });
    }
    if (points.length < 2) {
      await _buffer.clearRoutePoints();
      _snack('Trajet trop court (${points.length} point). Réessayez.');
      return;
    }
    if (mounted) await _showSaveDialog(points);
  }

  double _distanceKm(List<Map<String, double>> pts) {
    double d = 0;
    for (var i = 1; i < pts.length; i++) {
      d += Geolocator.distanceBetween(
          pts[i - 1]['lat']!, pts[i - 1]['lng']!, pts[i]['lat']!, pts[i]['lng']!);
    }
    return d / 1000;
  }

  Future<void> _showSaveDialog(List<Map<String, double>> points) async {
    final nameCtl = TextEditingController();
    final widthCtl = TextEditingController(text: '200');
    final km = _distanceKm(points);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enregistrer l\'itinéraire'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${points.length} points · ${km.toStringAsFixed(2)} km',
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(
                labelText: 'Nom', hintText: 'Base vie → Chantier Nord',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: widthCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Largeur du couloir (m)', border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer')),
        ],
      ),
    );

    if (saved != true) return;
    if (mounted) setState(() => _working = true);
    try {
      final api = CarbTrackApi(baseUrl: widget.config.baseUrl, token: widget.config.token);
      await api.postRoute(
        name: nameCtl.text.trim().isEmpty ? 'Itinéraire' : nameCtl.text.trim(),
        corridorM: double.tryParse(widthCtl.text.replaceAll(',', '.')) ?? 200,
        points: points,
      );
      await _buffer.clearRoutePoints();
      if (mounted) setState(() => _points = 0);
      _snack('Itinéraire envoyé ✓ (visible sur le dashboard)');
    } on ApiException catch (e) {
      _snack('${e.message} Le trajet est conservé : touchez « Renvoyer ».');
    } catch (e) {
      _snack('Erreur : $e — le trajet est conservé, touchez « Renvoyer ».');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Renvoie un trajet capturé dont l'envoi a échoué (points encore en buffer).
  Future<void> _resend() async {
    final points = await _buffer.routePoints();
    if (points.length < 2) {
      await _buffer.clearRoutePoints();
      if (mounted) setState(() => _points = 0);
      return;
    }
    if (mounted) await _showSaveDialog(points);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _recording ? cs.errorContainer : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Icon(_recording ? Icons.fiber_manual_record : Icons.route_rounded,
                  size: 44, color: _recording ? cs.error : cs.primary),
              const SizedBox(height: 8),
              Text(_recording ? 'Enregistrement en cours…' : 'Prêt à enregistrer',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('$_points point(s) capturé(s)',
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (_recording)
          FilledButton.icon(
            onPressed: _working ? null : _stop,
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            icon: const Icon(Icons.stop_rounded),
            label: const Text('Terminer et envoyer'),
          )
        else ...[
          FilledButton.icon(
            onPressed: _working ? null : _start,
            icon: _working
                ? const SizedBox(height: 20, width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Démarrer l\'enregistrement'),
          ),
          if (_points >= 2) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _working ? null : _resend,
              icon: const Icon(Icons.send_rounded),
              label: Text('Renvoyer le trajet capturé ($_points points)'),
            ),
          ],
        ],
        const SizedBox(height: 16),
        Text(
          'Roulez de la base vie jusqu\'au chantier. L\'app enregistre le tracé '
          '(1 point / 5 s). À l\'arrivée, touchez « Terminer », nommez l\'itinéraire '
          'et envoyez-le : il apparaîtra sur le dashboard, prêt à être assigné.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
