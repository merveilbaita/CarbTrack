import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';

/// Dépannage superviseur : voir les dernières positions et lancer la navigation.
class BreakdownScreen extends StatefulWidget {
  const BreakdownScreen({super.key, required this.config});
  final ServerConfig config;

  @override
  State<BreakdownScreen> createState() => _BreakdownScreenState();
}

class _BreakdownScreenState extends State<BreakdownScreen> {
  bool _loading = false;
  List<Map<String, dynamic>> _fleet = const [];

  @override
  void initState() {
    super.initState();
    _loadFleet();
  }

  Future<void> _loadFleet() async {
    setState(() => _loading = true);
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
      if (mounted) setState(() => _loading = false);
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
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Dépannage',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              tooltip: 'Actualiser',
              onPressed: _loading ? null : _loadFleet,
              icon: _loading
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
        Text(
          'Lancez un itinéraire vers la dernière position connue d\'un engin.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.outline),
        ),
        const SizedBox(height: 16),
        if (_fleet.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              _loading
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
