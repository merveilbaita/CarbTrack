import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Carte de détail d'un événement du journal, avant navigation terrain.
class EventMapScreen extends StatefulWidget {
  const EventMapScreen({super.key, required this.event});

  final Map<String, dynamic> event;

  @override
  State<EventMapScreen> createState() => _EventMapScreenState();
}

class _EventMapScreenState extends State<EventMapScreen> {
  final _mapController = MapController();
  LatLng? _adminPoint;
  bool _locating = true;
  String? _locationError;

  double get _lat => (widget.event['lat'] as num).toDouble();
  double get _lng => (widget.event['lng'] as num).toDouble();
  LatLng get _eventPoint => LatLng(_lat, _lng);

  @override
  void initState() {
    super.initState();
    _loadAdminPosition();
  }

  Future<void> _loadAdminPosition() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Position actuelle non autorisée.');
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final point = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() => _adminPoint = point);
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitRoute());
    } catch (e) {
      if (mounted) {
        setState(
          () => _locationError = e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _fitRoute() {
    final admin = _adminPoint;
    if (admin == null) return;
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints([admin, _eventPoint]),
        padding: const EdgeInsets.all(58),
      ),
    );
  }

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

  String _distanceLabel() {
    final admin = _adminPoint;
    if (admin == null) return 'Distance indisponible';
    final meters = const Distance().as(LengthUnit.Meter, admin, _eventPoint);
    if (meters < 1000) return '${meters.round()} m à vol d\'oiseau';
    return '${(meters / 1000).toStringAsFixed(meters >= 10000 ? 0 : 1)} km à vol d\'oiseau';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final vehicle = widget.event['vehicle'];
    final zone = widget.event['zone'];
    final admin = _adminPoint;
    return Scaffold(
      appBar: AppBar(title: const Text('Position événement')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _eventPoint,
                    initialZoom: 15,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.montgabaon.carbtrack',
                    ),
                    if (admin != null)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [admin, _eventPoint],
                            color: cs.primary,
                            strokeWidth: 4,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        if (admin != null)
                          Marker(
                            point: admin,
                            width: 42,
                            height: 42,
                            child: Container(
                              decoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    blurRadius: 8,
                                    color: Color(0x33000000),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.person_pin_circle_rounded,
                                color: Colors.white,
                                size: 25,
                              ),
                            ),
                          ),
                        Marker(
                          point: _eventPoint,
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
                Positioned(
                  left: 12,
                  right: 12,
                  top: 12,
                  child: _MapStatus(
                    locating: _locating,
                    error: _locationError,
                    distance: _distanceLabel(),
                    onRetry: _loadAdminPosition,
                  ),
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
                    '${widget.event['message'] ?? widget.event['kind_label'] ?? 'Événement'}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      '${widget.event['driver']}',
                      if (vehicle != null) '$vehicle',
                      if (zone != null) '$zone',
                      _time(widget.event['started_at'] as String?),
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

class _MapStatus extends StatelessWidget {
  const _MapStatus({
    required this.locating,
    required this.error,
    required this.distance,
    required this.onRetry,
  });

  final bool locating;
  final String? error;
  final String distance;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            if (locating)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                error == null
                    ? Icons.route_rounded
                    : Icons.location_searching_rounded,
                color: error == null ? cs.primary : cs.error,
                size: 20,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                locating ? 'Recherche de votre position…' : error ?? distance,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: error == null ? cs.onSurface : cs.error,
                ),
              ),
            ),
            if (error != null)
              TextButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}
