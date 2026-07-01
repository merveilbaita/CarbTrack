import 'package:dio/dio.dart';

/// Erreur réseau/API normalisée.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Résultat d'un envoi de positions : par client_id, hors-couloir + écart.
class PingResult {
  PingResult({required this.clientId, required this.offRoute, this.distM});
  final String clientId;
  final bool offRoute;
  final double? distM;
}

/// Client de l'API CarbTrack (Django/DRF).
class CarbTrackApi {
  CarbTrackApi({required this.baseUrl, required this.token, Dio? dio})
      : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = const Duration(seconds: 8)
      ..receiveTimeout = const Duration(seconds: 15)
      ..sendTimeout = const Duration(seconds: 15)
      ..headers = {
        if (token.isNotEmpty) 'Authorization': 'Token $token',
        'Content-Type': 'application/json',
      }
      ..validateStatus = (s) => s != null && s < 500;
  }

  final String baseUrl;
  final String token;
  final Dio _dio;

  /// `POST /api/auth/login` — retourne `{token, driver:{name,...}}`.
  static Future<Map<String, dynamic>> login({
    required String baseUrl,
    required String phone,
    required String pin,
    String? deviceId,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      validateStatus: (s) => s != null && s < 500,
    ));
    try {
      final r = await dio.post('/api/auth/login', data: {
        'phone': phone,
        'pin': pin,
        'device_id': ?deviceId,
      });
      if ((r.statusCode ?? 0) == 401) {
        throw ApiException('Téléphone ou PIN incorrect.', statusCode: 401);
      }
      if ((r.statusCode ?? 0) >= 400) {
        throw ApiException('Erreur serveur (${r.statusCode}).',
            statusCode: r.statusCode);
      }
      return Map<String, dynamic>.from(r.data as Map);
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// `POST /api/positions` — envoie un batch de pings, retourne les résultats.
  Future<List<PingResult>> postPositions(List<Map<String, dynamic>> pings) async {
    try {
      final r = await _dio.post('/api/positions', data: {'positions': pings});
      if ((r.statusCode ?? 0) == 401) {
        throw ApiException('Token refusé.', statusCode: 401);
      }
      if ((r.statusCode ?? 0) >= 400) {
        throw ApiException('Erreur serveur (${r.statusCode}).',
            statusCode: r.statusCode);
      }
      final data = Map<String, dynamic>.from(r.data as Map);
      final results = (data['results'] as List?) ?? const [];
      return results.whereType<Map>().map((m) {
        return PingResult(
          clientId: '${m['client_id']}',
          offRoute: m['off_route'] == true,
          distM: (m['dist_m'] as num?)?.toDouble(),
        );
      }).toList();
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// `GET /api/vehicles` — véhicules actifs + dernier index connu.
  Future<List<Map<String, dynamic>>> getVehicles() async {
    final r = await _dio.get('/api/vehicles');
    _ensure(r);
    final list = (r.data['vehicles'] as List?) ?? const [];
    return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// `POST /api/appros` — envoie un lot d'appros. Retourne les `client_id` traités.
  Future<List<String>> postAppros(List<Map<String, dynamic>> appros) async {
    final r = await _dio.post('/api/appros', data: {'appros': appros});
    _ensure(r);
    final results = (r.data['results'] as List?) ?? const [];
    return results
        .whereType<Map>()
        .where((m) => m['status'] == 'ok' || m['status'] == 'duplicate')
        .map((m) => '${m['client_id']}')
        .toList();
  }

  /// `POST /api/routes` — crée un itinéraire depuis un tracé enregistré (superviseur).
  Future<Map<String, dynamic>> postRoute({
    required String name,
    required double corridorM,
    required List<Map<String, double>> points,
  }) async {
    final r = await _dio.post('/api/routes', data: {
      'name': name,
      'corridor_m': corridorM,
      'points': points,
    });
    if ((r.statusCode ?? 0) == 403) {
      throw ApiException('Réservé aux superviseurs.', statusCode: 403);
    }
    _ensure(r);
    return Map<String, dynamic>.from(r.data as Map);
  }

  /// `GET /api/appros/recent` — derniers appros du chauffeur.
  Future<List<Map<String, dynamic>>> getRecentAppros() async {
    final r = await _dio.get('/api/appros/recent');
    _ensure(r);
    final list = (r.data['appros'] as List?) ?? const [];
    return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  void _ensure(Response r) {
    final code = r.statusCode ?? 0;
    if (code == 401) throw ApiException('Token refusé.', statusCode: 401);
    if (code >= 400) throw ApiException('Erreur serveur ($code).', statusCode: code);
  }

  static ApiException _wrap(DioException e) {
    final m = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        'Délai dépassé — serveur joignable ?',
      DioExceptionType.connectionError =>
        'Connexion impossible — vérifiez le réseau / l\'adresse du serveur.',
      _ => e.message ?? 'Erreur réseau.',
    };
    return ApiException(m, statusCode: e.response?.statusCode);
  }
}
