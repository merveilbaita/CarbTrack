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
      version: 1,
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
      },
    );
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
