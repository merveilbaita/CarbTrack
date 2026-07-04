import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';
import 'event_map_screen.dart';

/// Journal superviseur : événements du dashboard + navigation dépannage.
class BreakdownScreen extends StatefulWidget {
  const BreakdownScreen({super.key, required this.config});
  final ServerConfig config;

  @override
  State<BreakdownScreen> createState() => _BreakdownScreenState();
}

class _BreakdownScreenState extends State<BreakdownScreen> {
  static const _offlineKey = 'carbtrack_last_breakdown_event';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  late DateTime _day = DateTime.now();
  bool _loading = false;
  List<Map<String, dynamic>> _events = const [];
  Map<String, dynamic>? _offlineEvent;

  @override
  void initState() {
    super.initState();
    _loadOfflineEvent();
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

  Future<void> _loadOfflineEvent() async {
    final raw = await _storage.read(key: _offlineKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (mounted) setState(() => _offlineEvent = decoded);
    } catch (_) {
      await _storage.delete(key: _offlineKey);
    }
  }

  Future<void> _saveOfflineEvent(Map<String, dynamic> event) async {
    await _storage.write(key: _offlineKey, value: jsonEncode(event));
    if (mounted) setState(() => _offlineEvent = event);
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

  Future<void> _openMap(Map<String, dynamic> event) async {
    final lat = (event['lat'] as num?)?.toDouble();
    final lng = (event['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    await _saveOfflineEvent(event);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EventMapScreen(config: widget.config, event: event),
      ),
    );
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
        if (_offlineEvent != null) ...[
          _OfflineDestinationCard(
            event: _offlineEvent!,
            onOpen: () => _openMap(_offlineEvent!),
          ),
          const SizedBox(height: 12),
        ],
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
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(_iconFor(kind), color: color, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _message(e),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                _subtitle(e),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: cs.outline),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MetaChip(
                          icon: Icons.label_rounded,
                          label: '${e['kind_label']}',
                          color: color,
                        ),
                        _MetaChip(
                          icon: Icons.schedule_rounded,
                          label: _time(e['started_at'] as String?),
                          color: cs.outline,
                        ),
                        if (hasPosition)
                          _MetaChip(
                            icon: Icons.location_on_rounded,
                            label: 'Position disponible',
                            color: cs.primary,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: hasPosition ? () => _openMap(e) : null,
                            icon: const Icon(Icons.map_rounded),
                            label: const Text('Voir la carte'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(
                          hasPosition
                              ? Icons.chevron_right_rounded
                              : Icons.location_off_rounded,
                          color: hasPosition ? cs.outline : cs.error,
                        ),
                      ],
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

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OfflineDestinationCard extends StatelessWidget {
  const _OfflineDestinationCard({required this.event, required this.onOpen});

  final Map<String, dynamic> event;
  final VoidCallback onOpen;

  String _time(String? iso) {
    if (iso == null || iso.length < 16) return '--:--';
    return iso.substring(11, 16);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final vehicle = event['vehicle'];
    final zone = event['zone'];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.offline_pin_rounded, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Dernière destination sauvegardée',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${event['message'] ?? event['kind_label'] ?? 'Événement'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            [
              '${event['driver']}',
              if (vehicle != null) '$vehicle',
              if (zone != null) '$zone',
              _time(event['started_at'] as String?),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.map_rounded),
            label: const Text('Rouvrir la carte'),
          ),
        ],
      ),
    );
  }
}
