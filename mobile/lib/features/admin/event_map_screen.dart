import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/server_config.dart';

/// Carte de détail d'un événement du journal, avant navigation terrain.
class EventMapScreen extends StatefulWidget {
  const EventMapScreen({super.key, required this.config, required this.event});

  final ServerConfig config;
  final Map<String, dynamic> event;

  @override
  State<EventMapScreen> createState() => _EventMapScreenState();
}

class _EventMapScreenState extends State<EventMapScreen> {
  static const _adminAvatarKey = 'carbtrack_map_admin_avatar';
  static const _eventAvatarKey = 'carbtrack_map_event_avatar';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final _mapController = MapController();
  LatLng? _adminPoint;
  List<LatLng> _routePoints = const [];
  double? _routeDistanceM;
  double? _routeDurationS;
  bool _locating = true;
  bool _loadingRoute = false;
  bool _workingIntervention = false;
  String? _locationError;
  Map<String, dynamic>? _intervention;
  String _adminAvatar = 'supervisor';
  String _eventAvatar = 'truck';

  double get _lat => (widget.event['lat'] as num).toDouble();
  double get _lng => (widget.event['lng'] as num).toDouble();
  LatLng get _eventPoint => LatLng(_lat, _lng);

  @override
  void initState() {
    super.initState();
    final intervention = widget.event['intervention'];
    if (intervention is Map) {
      _intervention = Map<String, dynamic>.from(intervention);
    }
    _loadAvatarPrefs();
    _loadAdminPosition();
  }

  Future<void> _loadAvatarPrefs() async {
    final admin = await _storage.read(key: _adminAvatarKey);
    final event = await _storage.read(key: _eventAvatarKey);
    if (!mounted) return;
    setState(() {
      if (_avatarById(admin, _adminAvatars) != null) _adminAvatar = admin!;
      if (_avatarById(event, _eventAvatars) != null) _eventAvatar = event!;
    });
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
      await _loadRoadRoute(point);
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
    final points = _routePoints.isNotEmpty
        ? _routePoints
        : [?admin, _eventPoint];
    if (points.length < 2) return;
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(58),
      ),
    );
  }

  Future<void> _loadRoadRoute(LatLng admin) async {
    setState(() => _loadingRoute = true);
    try {
      final api = CarbTrackApi(
        baseUrl: widget.config.baseUrl,
        token: widget.config.token,
      );
      final data = await api.getDirections(
        originLat: admin.latitude,
        originLng: admin.longitude,
        destLat: _lat,
        destLng: _lng,
      );
      final geometry = data['geometry'];
      final coords = geometry is Map ? geometry['coordinates'] : null;
      final route = coords is List
          ? coords.whereType<List>().map((p) {
              return LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble());
            }).toList()
          : <LatLng>[];
      if (!mounted) return;
      setState(() {
        _routePoints = route;
        _routeDistanceM = (data['distance_m'] as num?)?.toDouble();
        _routeDurationS = (data['duration_s'] as num?)?.toDouble();
      });
    } catch (_) {
      if (mounted) setState(() => _routePoints = const []);
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
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

  Future<void> _callPhone(String phone) async {
    if (phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openWhatsapp(String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (cleaned.isEmpty) return;
    final uri = Uri.https('wa.me', '/${cleaned.replaceFirst('+', '')}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _startIntervention() async {
    setState(() => _workingIntervention = true);
    try {
      final api = CarbTrackApi(
        baseUrl: widget.config.baseUrl,
        token: widget.config.token,
      );
      final id = (widget.event['id'] as num).toInt();
      final intervention = await api.startIntervention(id);
      if (mounted) setState(() => _intervention = intervention);
    } finally {
      if (mounted) setState(() => _workingIntervention = false);
    }
  }

  Future<void> _setInterventionStatus(String status) async {
    final interventionId = (_intervention?['id'] as num?)?.toInt();
    if (interventionId == null) return;
    setState(() => _workingIntervention = true);
    try {
      final api = CarbTrackApi(
        baseUrl: widget.config.baseUrl,
        token: widget.config.token,
      );
      final intervention = await api.updateInterventionStatus(
        interventionId: interventionId,
        status: status,
      );
      if (mounted) setState(() => _intervention = intervention);
    } finally {
      if (mounted) setState(() => _workingIntervention = false);
    }
  }

  Future<void> _chooseAvatars() async {
    var selectedAdmin = _adminAvatar;
    var selectedEvent = _eventAvatar;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Avatars de carte',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _AvatarPicker(
                      title: 'Votre position',
                      avatars: _adminAvatars,
                      selected: selectedAdmin,
                      onSelected: (id) =>
                          setSheetState(() => selectedAdmin = id),
                    ),
                    const SizedBox(height: 16),
                    _AvatarPicker(
                      title: 'Événement / engin',
                      avatars: _eventAvatars,
                      selected: selectedEvent,
                      onSelected: (id) =>
                          setSheetState(() => selectedEvent = id),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Appliquer'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (saved != true) return;
    await _storage.write(key: _adminAvatarKey, value: selectedAdmin);
    await _storage.write(key: _eventAvatarKey, value: selectedEvent);
    if (!mounted) return;
    setState(() {
      _adminAvatar = selectedAdmin;
      _eventAvatar = selectedEvent;
    });
  }

  String _time(String? iso) {
    if (iso == null || iso.length < 16) return '--:--';
    return iso.substring(11, 16);
  }

  String _distanceLabel() {
    final routeDistance = _routeDistanceM;
    final routeDuration = _routeDurationS;
    if (routeDistance != null && routeDuration != null) {
      final km = routeDistance / 1000;
      final min = (routeDuration / 60).round();
      final dist = routeDistance < 1000
          ? '${routeDistance.round()} m'
          : '${km.toStringAsFixed(km >= 10 ? 0 : 1)} km';
      return _loadingRoute ? 'Calcul du trajet…' : '$dist · $min min';
    }
    if (_loadingRoute) return 'Calcul du trajet…';
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
    final driverPhone = '${widget.event['driver_phone'] ?? ''}'.trim();
    final whatsapp = '${widget.event['driver_whatsapp'] ?? ''}'.trim();
    final emergencyPhone = '${widget.event['driver_emergency_phone'] ?? ''}'
        .trim();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Position événement'),
        actions: [
          IconButton(
            tooltip: 'Choisir les avatars',
            onPressed: _chooseAvatars,
            icon: const Icon(Icons.badge_rounded),
          ),
        ],
      ),
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
                            points: _routePoints.isNotEmpty
                                ? _routePoints
                                : [admin, _eventPoint],
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
                            width: 54,
                            height: 62,
                            child: _MapAvatarMarker(
                              avatar: _avatarById(_adminAvatar, _adminAvatars)!,
                              selected: true,
                            ),
                          ),
                        Marker(
                          point: _eventPoint,
                          width: 58,
                          height: 66,
                          child: _MapAvatarMarker(
                            avatar: _avatarById(_eventAvatar, _eventAvatars)!,
                            selected: true,
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
                  _InterventionPanel(
                    intervention: _intervention,
                    working: _workingIntervention,
                    onStart: _startIntervention,
                    onArrived: () => _setInterventionStatus('arrived'),
                    onDone: () => _setInterventionStatus('done'),
                  ),
                  const SizedBox(height: 10),
                  _ContactActions(
                    driverName: '${widget.event['driver']}',
                    phone: driverPhone,
                    whatsapp: whatsapp,
                    emergencyPhone: emergencyPhone,
                    onCall: _callPhone,
                    onWhatsapp: _openWhatsapp,
                  ),
                  const SizedBox(height: 10),
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

class _ContactActions extends StatelessWidget {
  const _ContactActions({
    required this.driverName,
    required this.phone,
    required this.whatsapp,
    required this.emergencyPhone,
    required this.onCall,
    required this.onWhatsapp,
  });

  final String driverName;
  final String phone;
  final String whatsapp;
  final String emergencyPhone;
  final ValueChanged<String> onCall;
  final ValueChanged<String> onWhatsapp;

  @override
  Widget build(BuildContext context) {
    final hasAny =
        phone.isNotEmpty || whatsapp.isNotEmpty || emergencyPhone.isNotEmpty;
    if (!hasAny) {
      return OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.call_rounded),
        label: const Text('Téléphone indisponible'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (phone.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () => onCall(phone),
            icon: const Icon(Icons.call_rounded),
            label: Text('Appeler $driverName'),
          ),
        if (whatsapp.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => onWhatsapp(whatsapp),
            icon: const Icon(Icons.chat_rounded),
            label: const Text('WhatsApp conducteur'),
          ),
        ],
        if (emergencyPhone.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => onCall(emergencyPhone),
            icon: const Icon(Icons.emergency_rounded),
            label: const Text('Contact urgence'),
          ),
        ],
      ],
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

class _InterventionPanel extends StatelessWidget {
  const _InterventionPanel({
    required this.intervention,
    required this.working,
    required this.onStart,
    required this.onArrived,
    required this.onDone,
  });

  final Map<String, dynamic>? intervention;
  final bool working;
  final VoidCallback onStart;
  final VoidCallback onArrived;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final status = intervention?['status'];
    final label = intervention?['status_label'] ?? 'Aucune intervention active';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.engineering_rounded, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Intervention · $label',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (intervention == null)
            FilledButton.tonalIcon(
              onPressed: working ? null : onStart,
              icon: working
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Démarrer intervention'),
            )
          else if (status == 'en_route')
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: working ? null : onArrived,
                    icon: const Icon(Icons.flag_rounded),
                    label: const Text('Arrivé'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: working ? null : onDone,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Terminer'),
                  ),
                ),
              ],
            )
          else if (status == 'arrived')
            FilledButton.icon(
              onPressed: working ? null : onDone,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Terminer intervention'),
            )
          else
            Text(
              'Intervention terminée',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.outline,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}

class _MapAvatar {
  const _MapAvatar({
    required this.id,
    required this.label,
    required this.icon,
    required this.color,
  });

  final String id;
  final String label;
  final IconData icon;
  final Color color;
}

const _adminAvatars = [
  _MapAvatar(
    id: 'supervisor',
    label: 'Superviseur',
    icon: Icons.admin_panel_settings_rounded,
    color: Color(0xFF0E4C5B),
  ),
  _MapAvatar(
    id: 'support',
    label: 'Intervention',
    icon: Icons.support_agent_rounded,
    color: Color(0xFF2563EB),
  ),
  _MapAvatar(
    id: 'pickup',
    label: 'Pickup',
    icon: Icons.airport_shuttle_rounded,
    color: Color(0xFF047857),
  ),
];

const _eventAvatars = [
  _MapAvatar(
    id: 'truck',
    label: 'Engin',
    icon: Icons.local_shipping_rounded,
    color: Color(0xFFDC2626),
  ),
  _MapAvatar(
    id: 'breakdown',
    label: 'Panne',
    icon: Icons.build_circle_rounded,
    color: Color(0xFFB45309),
  ),
  _MapAvatar(
    id: 'site',
    label: 'Chantier',
    icon: Icons.location_city_rounded,
    color: Color(0xFF7C3AED),
  ),
];

_MapAvatar? _avatarById(String? id, List<_MapAvatar> avatars) {
  for (final avatar in avatars) {
    if (avatar.id == id) return avatar;
  }
  return null;
}

class _MapAvatarMarker extends StatelessWidget {
  const _MapAvatarMarker({required this.avatar, required this.selected});

  final _MapAvatar avatar;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: avatar.color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: selected ? 3 : 2),
            boxShadow: const [
              BoxShadow(
                blurRadius: 10,
                offset: Offset(0, 3),
                color: Color(0x33000000),
              ),
            ],
          ),
          child: Icon(avatar.icon, color: Colors.white, size: 25),
        ),
        Transform.translate(
          offset: const Offset(0, -7),
          child: Icon(
            Icons.arrow_drop_down_rounded,
            color: avatar.color,
            size: 28,
          ),
        ),
      ],
    );
  }
}

class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.title,
    required this.avatars,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final List<_MapAvatar> avatars;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: avatars.map((avatar) {
            final isSelected = avatar.id == selected;
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onSelected(avatar.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? avatar.color.withValues(alpha: 0.14)
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected ? avatar.color : Colors.transparent,
                    width: 1.4,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MapAvatarMarker(avatar: avatar, selected: isSelected),
                    const SizedBox(width: 8),
                    Text(
                      avatar.label,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: isSelected ? avatar.color : cs.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
