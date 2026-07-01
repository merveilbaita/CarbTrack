import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// File d'attente locale (outbox) des positions GPS, pour ne rien perdre
/// hors couverture réseau. Les pings sont supprimés après accusé du serveur.
class BufferDb {
  Database? _db;

  Future<void> open() async {
    if (_db != null) return;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'carbtrack_buffer.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE pending (
            client_id  TEXT PRIMARY KEY,
            lat        REAL NOT NULL,
            lng        REAL NOT NULL,
            ts         TEXT NOT NULL,
            speed      REAL,
            accuracy   REAL,
            created_at TEXT NOT NULL
          )
        ''');
        await _createRoutePoints(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) await _createRoutePoints(db);
      },
    );
  }

  Future<void> _createRoutePoints(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS route_points (
        id  INTEGER PRIMARY KEY AUTOINCREMENT,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        ts  TEXT NOT NULL
      )
    ''');
  }

  // ── Enregistrement d'itinéraire (mode superviseur) ──────────
  Future<void> insertRoutePoint(double lat, double lng, String ts) async {
    await _db?.insert('route_points', {'lat': lat, 'lng': lng, 'ts': ts});
  }

  Future<List<Map<String, double>>> routePoints() async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query('route_points', orderBy: 'id ASC');
    return rows
        .map((r) => {'lat': r['lat'] as double, 'lng': r['lng'] as double})
        .toList();
  }

  Future<int> routePointCount() async {
    final db = _db;
    if (db == null) return 0;
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM route_points');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> clearRoutePoints() async {
    await _db?.delete('route_points');
  }

  Future<void> insert(Map<String, dynamic> ping) async {
    final db = _db;
    if (db == null) return;
    await db.insert('pending', {
      'client_id': ping['client_id'],
      'lat': ping['lat'],
      'lng': ping['lng'],
      'ts': ping['ts'],
      'speed': ping['speed'],
      'accuracy': ping['accuracy'],
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Plus anciens d'abord, prêts pour l'envoi à l'API.
  Future<List<Map<String, dynamic>>> takeBatch(int limit) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query('pending', orderBy: 'ts ASC', limit: limit);
    return rows
        .map((r) => {
              'client_id': r['client_id'],
              'lat': r['lat'],
              'lng': r['lng'],
              'ts': r['ts'],
              'speed': r['speed'],
              'accuracy': r['accuracy'],
            })
        .toList();
  }

  Future<void> deleteClientIds(List<String> ids) async {
    final db = _db;
    if (db == null || ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('pending', where: 'client_id IN ($placeholders)', whereArgs: ids);
  }

  Future<int> count() async {
    final db = _db;
    if (db == null) return 0;
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM pending');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
