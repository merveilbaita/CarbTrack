import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key, required this.config});
  final ServerConfig config;

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  bool _loading = false;
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _today {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = CarbTrackApi(
        baseUrl: widget.config.baseUrl,
        token: widget.config.token,
      );
      final summary = await api.getAdminSummary(date: _today);
      if (mounted) setState(() => _summary = summary);
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final summary = _summary;
    final fleet = Map<String, dynamic>.from(summary?['fleet'] as Map? ?? {});
    final alerts = Map<String, dynamic>.from(summary?['alerts'] as Map? ?? {});
    final interventions = Map<String, dynamic>.from(
      summary?['interventions'] as Map? ?? {},
    );
    final events = Map<String, dynamic>.from(summary?['events'] as Map? ?? {});
    final interventionItems =
        (interventions['items'] as List?)?.whereType<Map>().toList() ??
        const [];
    final criticalEvents =
        (events['critical'] as List?)?.whereType<Map>().toList() ?? const [];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Tableau de bord',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Actualiser',
                onPressed: _loading ? null : _load,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            childAspectRatio: 1.45,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: [
              _MetricTile(
                label: 'Suivis',
                value: '${fleet['tracked'] ?? 0}',
                detail: '${fleet['online'] ?? 0} en ligne',
                icon: Icons.gps_fixed_rounded,
                color: cs.primary,
              ),
              _MetricTile(
                label: 'Silencieux',
                value: '${fleet['silent'] ?? 0}',
                detail: '${fleet['offline'] ?? 0} hors ligne',
                icon:
                    Icons.signal_wifi_statusbar_connected_no_internet_4_rounded,
                color: Colors.orange.shade800,
              ),
              _MetricTile(
                label: 'Alertes',
                value: '${alerts['open'] ?? 0}',
                detail: 'ouvertes',
                icon: Icons.warning_amber_rounded,
                color: cs.error,
              ),
              _MetricTile(
                label: 'Interventions',
                value: '${interventions['active'] ?? 0}',
                detail: 'en cours',
                icon: Icons.engineering_rounded,
                color: Colors.blue.shade700,
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SectionHeader(
            title: 'Interventions en cours',
            trailing: '${interventionItems.length}',
          ),
          const SizedBox(height: 8),
          if (interventionItems.isEmpty)
            _EmptyPanel(text: 'Aucune intervention active.')
          else
            ...interventionItems.map((item) {
              return _ListPanel(
                icon: Icons.engineering_rounded,
                color: Colors.blue.shade700,
                title: '${item['status_label'] ?? 'Intervention'}',
                subtitle: '${item['supervisor'] ?? ''}',
              );
            }),
          const SizedBox(height: 18),
          _SectionHeader(
            title: 'Événements prioritaires',
            trailing: '${criticalEvents.length}',
          ),
          const SizedBox(height: 8),
          if (criticalEvents.isEmpty)
            _EmptyPanel(text: 'Aucun événement prioritaire aujourd’hui.')
          else
            ...criticalEvents.map((event) {
              final vehicle = event['vehicle'];
              return _ListPanel(
                icon: Icons.priority_high_rounded,
                color: cs.error,
                title:
                    '${event['message'] ?? event['kind_label'] ?? 'Événement'}',
                subtitle:
                    '${event['driver'] ?? ''}${vehicle != null ? ' · $vehicle' : ''}',
              );
            }),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const Spacer(),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: cs.onSurface,
            ),
          ),
          Text(
            '$label · $detail',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.trailing});

  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        Text(
          trailing,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: cs.outline,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _ListPanel extends StatelessWidget {
  const _ListPanel({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(color: cs.outline)),
    );
  }
}
