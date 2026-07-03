import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';

/// Journal superviseur : événements du dashboard + navigation dépannage.
class BreakdownScreen extends StatefulWidget {
  const BreakdownScreen({super.key, required this.config});
  final ServerConfig config;

  @override
  State<BreakdownScreen> createState() => _BreakdownScreenState();
}

class _BreakdownScreenState extends State<BreakdownScreen> {
  late DateTime _day = DateTime.now();
  bool _loading = false;
  List<Map<String, dynamic>> _events = const [];

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  String get _dateParam {
    final y = _day.year.toString().padLeft(4, '0');
    final m = _day.month.toString().padLeft(2, '0');
    final d = _day.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _loadEvents() async {
    setState(() => _loading = true);
    try {
      final api = CarbTrackApi(
        baseUrl: widget.config.baseUrl,
        token: widget.config.token,
      );
      final events = await api.getEvents(date: _dateParam);
      if (mounted) setState(() => _events = events);
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

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _day = picked);
    await _loadEvents();
  }

  Future<void> _startNavigation(Map<String, dynamic> event) async {
    final lat = (event['lat'] as num?)?.toDouble();
    final lng = (event['lng'] as num?)?.toDouble();
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

  IconData _iconFor(String kind) => switch (kind) {
    'zone_enter' => Icons.place_rounded,
    'zone_exit' => Icons.local_shipping_rounded,
    'trip' => Icons.route_rounded,
    _ => Icons.pause_circle_filled_rounded,
  };

  Color _colorFor(ColorScheme cs, String kind) => switch (kind) {
    'zone_enter' => Colors.green.shade700,
    'zone_exit' => Colors.blue.shade700,
    'trip' => cs.primary,
    _ => Colors.orange.shade800,
  };

  String _time(String? iso) {
    if (iso == null || iso.length < 16) return '--:--';
    return iso.substring(11, 16);
  }

  String _subtitle(Map<String, dynamic> e) {
    final vehicle = e['vehicle'];
    final zone = e['zone'];
    final parts = [
      '${e['driver']}',
      if (vehicle != null) '$vehicle',
      if (zone != null) '$zone',
    ];
    return parts.join(' · ');
  }

  String _message(Map<String, dynamic> e) {
    final kind = e['kind'];
    final minutes = e['minutes'];
    final base = '${e['message'] ?? e['kind_label'] ?? 'Événement'}';
    if (kind == 'stop' || kind == 'trip') {
      return minutes == null ? '$base · en cours' : '$base · $minutes min';
    }
    return base;
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
                'Journal',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              tooltip: 'Actualiser',
              onPressed: _loading ? null : _loadEvents,
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
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _loading ? null : _pickDate,
          icon: const Icon(Icons.calendar_month_rounded),
          label: Text(_dateParam),
        ),
        const SizedBox(height: 12),
        Text(
          '${_events.length} événement(s)',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: cs.outline),
        ),
        const SizedBox(height: 12),
        if (_events.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              _loading
                  ? 'Chargement du journal…'
                  : 'Aucun événement ce jour-là.',
            ),
          )
        else
          ..._events.map((e) {
            final lat = e['lat'];
            final lng = e['lng'];
            final hasPosition = lat != null && lng != null;
            final kind = '${e['kind']}';
            final color = _colorFor(cs, kind);
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(_iconFor(kind), color: color),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _message(e),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _subtitle(e),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: cs.outline),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${e['kind_label']} · ${_time(e['started_at'] as String?)}',
                            style: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(color: color),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: hasPosition ? () => _startNavigation(e) : null,
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
