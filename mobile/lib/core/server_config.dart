import 'dart:convert';

/// Configuration du serveur CarbTrack appairé + identité du chauffeur.
class ServerConfig {
  const ServerConfig({
    required this.host,
    required this.port,
    required this.token,
    this.secure = false,
    this.driverName = '',
    this.role = 'driver',
    this.vehicleId,
    this.vehicleLabel = '',
  });

  final String host;
  final int port;

  /// Token d'authentification du chauffeur (en-tête `Authorization: Token …`).
  final String token;

  /// HTTPS en prod ; HTTP en dev (LAN / adb reverse).
  final bool secure;

  final String driverName;

  /// Rôle du compte : 'driver' (interface chauffeur) ou 'supervisor' (interface admin).
  final String role;
  bool get isSupervisor => role == 'supervisor';

  /// Camion assigné au compte (renvoyé par le login). null = aucun camion lié.
  final int? vehicleId;
  final String vehicleLabel;

  String get baseUrl => '${secure ? 'https' : 'http'}://$host:$port';

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'token': token,
        'secure': secure,
        'driverName': driverName,
        'role': role,
        'vehicleId': vehicleId,
        'vehicleLabel': vehicleLabel,
      };

  static ServerConfig fromJson(Map<String, dynamic> j) => ServerConfig(
        host: j['host'] as String,
        port: (j['port'] as num).toInt(),
        token: j['token'] as String? ?? '',
        secure: j['secure'] as bool? ?? false,
        driverName: j['driverName'] as String? ?? '',
        role: j['role'] as String? ?? 'driver',
        vehicleId: (j['vehicleId'] as num?)?.toInt(),
        vehicleLabel: j['vehicleLabel'] as String? ?? '',
      );

  String encode() => jsonEncode(toJson());

  static ServerConfig decode(String raw) =>
      fromJson(jsonDecode(raw) as Map<String, dynamic>);

  ServerConfig copyWith({String? token, String? driverName}) => ServerConfig(
        host: host,
        port: port,
        token: token ?? this.token,
        secure: secure,
        driverName: driverName ?? this.driverName,
        role: role,
        vehicleId: vehicleId,
        vehicleLabel: vehicleLabel,
      );
}
