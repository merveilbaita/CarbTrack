import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Carte de détail d'un événement du journal, avant navigation terrain.
class EventMapScreen extends StatelessWidget {
  const EventMapScreen({super.key, required this.event});

  final Map<String, dynamic> event;

  double get _lat => (event['lat'] as num).toDouble();
  double get _lng => (event['lng'] as num).toDouble();

  Future<void> _startNavigation() async {
    final navUri = Uri.parse('google.navigation:q=$_lat,$_lng&mode=d');
    if (await canLaunchUrl(navUri)) {
      await launchUrl(navUri, mode: LaunchMode.externalApplication);
      return;
    }

    final webUri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '$_lat,$_lng',
      'travelmode': 'driving',
    });
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  }

  String _time(String? iso) {
    if (iso == null || iso.length < 16) return '--:--';
    return iso.substring(11, 16);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final point = LatLng(_lat, _lng);
    final vehicle = event['vehicle'];
    final zone = event['zone'];
    return Scaffold(
      appBar: AppBar(title: const Text('Position événement')),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              options: MapOptions(initialCenter: point, initialZoom: 15),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.montgabaon.carbtrack',
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: point,
                      width: 52,
                      height: 52,
                      child: Icon(
                        Icons.location_pin,
                        color: cs.error,
                        size: 46,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${event['message'] ?? event['kind_label'] ?? 'Événement'}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      '${event['driver']}',
                      if (vehicle != null) '$vehicle',
                      if (zone != null) '$zone',
                      _time(event['started_at'] as String?),
                    ].join(' · '),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.outline),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _startNavigation,
                    icon: const Icon(Icons.navigation_rounded),
                    label: const Text('Démarrer la navigation'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
