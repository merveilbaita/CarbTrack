import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';

/// Cartographie terrain (superviseur) : enregistre la zone où l'on se trouve
/// (chantier, base vie…) — la position GPS courante devient le centre.
class ZoneRecorderScreen extends StatefulWidget {
  const ZoneRecorderScreen({super.key, required this.config});
  final ServerConfig config;

  @override
  State<ZoneRecorderScreen> createState() => _ZoneRecorderScreenState();
}

class _ZoneRecorderScreenState extends State<ZoneRecorderScreen> {
  static const _kinds = [
    ('chantier', 'Chantier', Icons.construction_rounded),
    ('base', 'Base vie', Icons.home_work_rounded),
    ('station', 'Station carburant', Icons.local_gas_station_rounded),
    ('rouge', 'Zone rouge 🚫', Icons.block_rounded),
    ('autre', 'Autre', Icons.place_rounded),
  ];

  final _nameCtl = TextEditingController();
  String _kind = 'chantier';
  double _radiusM = 300;

  Position? _pos;
  bool _locating = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _locate() async {
    setState(() => _locating = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) _snack('Autorisez la localisation pour cartographier.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (mounted) setState(() => _pos = pos);
    } catch (e) {
      if (mounted) _snack('Position introuvable : $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _send() async {
    final pos = _pos;
    if (pos == null) return;
    setState(() => _sending = true);
    try {
      final api = CarbTrackApi(
          baseUrl: widget.config.baseUrl, token: widget.config.token);
      final r = await api.postZone(
        name: _nameCtl.text.trim().isEmpty
            ? 'Zone terrain'
            : _nameCtl.text.trim(),
        kind: _kind,
        lat: pos.latitude,
        lng: pos.longitude,
        radiusM: _radiusM,
      );
      _nameCtl.clear();
      _snack('Zone « ${r['name']} » enregistrée ✓ — arrivées/départs '
          'des camions désormais journalisés ici.');
    } on ApiException catch (e) {
      _snack('Erreur : ${e.message}');
    } catch (e) {
      _snack('Erreur : $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pos = _pos;
    final goodFix = pos != null && pos.accuracy <= 25;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Position courante (centre de la zone)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: goodFix ? cs.primaryContainer : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Icon(Icons.my_location_rounded,
                  size: 40, color: goodFix ? cs.primary : cs.outline),
              const SizedBox(height: 8),
              Text(
                pos == null
                    ? (_locating ? 'Recherche GPS…' : 'Position inconnue')
                    : '${pos.latitude.toStringAsFixed(6)}, '
                        '${pos.longitude.toStringAsFixed(6)}',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                pos == null
                    ? 'Placez-vous au centre du site à cartographier.'
                    : 'Précision : ±${pos.accuracy.round()} m'
                        '${goodFix ? '' : ' — attendez un meilleur signal si possible'}',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _locating ? null : _locate,
                icon: _locating
                    ? const SizedBox(height: 16, width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Actualiser la position'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        TextField(
          controller: _nameCtl,
          decoration: const InputDecoration(
            labelText: 'Nom de la zone',
            hintText: 'Chantier Nord, Base vie…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),

        Text('Type de site', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final (value, label, icon) in _kinds)
              ChoiceChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: _kind == value,
                onSelected: (_) => setState(() => _kind = value),
              ),
          ],
        ),
        const SizedBox(height: 16),

        Text('Rayon de la zone : ${_radiusM.round()} m',
            style: Theme.of(context).textTheme.labelLarge),
        Slider(
          value: _radiusM,
          min: 50,
          max: 1000,
          divisions: 19,
          label: '${_radiusM.round()} m',
          onChanged: (v) => setState(() => _radiusM = v),
        ),
        const SizedBox(height: 8),

        FilledButton.icon(
          onPressed: (pos == null || _sending) ? null : _send,
          icon: _sending
              ? const SizedBox(height: 20, width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.add_location_alt_rounded),
          label: const Text('Enregistrer cette zone'),
        ),
        const SizedBox(height: 12),
        Text(
          'La zone est envoyée à la base de données et visible immédiatement '
          'sur le dashboard (page « Zones »). Les arrivées, départs et arrêts '
          'des camions y seront journalisés automatiquement.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
