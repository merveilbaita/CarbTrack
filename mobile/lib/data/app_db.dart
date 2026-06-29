import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Base locale de l'UI : cache des véhicules + file d'attente (outbox) des appros.
/// (Distincte de `buffer_db` qui sert les positions GPS dans l'isolate du service.)
class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();

  Database? _db;

  Future<void> open() async {
    if (_db != null) return;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'carbtrack_app.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE vehicles (
            id          INTEGER PRIMARY KEY,
            identifier  TEXT NOT NULL,
            label       TEXT,
            last_index  REAL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE pending_appros (
            client_id       TEXT PRIMARY KEY,
            date            TEXT NOT NULL,
            vehicle_id      INTEGER,
            index_precedent REAL,
            index_actuel    REAL,
            qte_litres      REAL NOT NULL,
            created_at      TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Database get _d => _db!;

  // ── Véhicules (cache) ───────────────────────────────────────
  Future<void> replaceVehicles(List<Map<String, dynamic>> vehicles) async {
    final batch = _d.batch();
    batch.delete('vehicles');
    for (final v in vehicles) {
      batch.insert('vehicles', {
        'id': v['id'],
        'identifier': v['identifier'],
        'label': v['label'],
        'last_index': (v['last_index'] as num?)?.toDouble() ?? 0,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> vehicles() async =>
      _d.query('vehicles', orderBy: 'identifier ASC');

  /// Met à jour localement le dernier index d'un véhicule après une saisie
  /// (pour pré-remplir le prochain appro même hors ligne).
  Future<void> bumpVehicleIndex(int vehicleId, double indexActuel) async {
    await _d.update('vehicles', {'last_index': indexActuel},
        where: 'id = ? AND last_index < ?', whereArgs: [vehicleId, indexActuel]);
  }

  // ── Appros (outbox) ─────────────────────────────────────────
  Future<void> enqueueAppro(Map<String, dynamic> appro) async {
    await _d.insert('pending_appros', {
      'client_id': appro['client_id'],
      'date': appro['date'],
      'vehicle_id': appro['vehicle_id'],
      'index_precedent': appro['index_precedent'],
      'index_actuel': appro['index_actuel'],
      'qte_litres': appro['qte_litres'],
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> pendingAppros() async {
    final rows = await _d.query('pending_appros', orderBy: 'created_at ASC');
    return rows
        .map((r) => {
              'client_id': r['client_id'],
              'date': r['date'],
              'vehicle_id': r['vehicle_id'],
              'index_precedent': r['index_precedent'],
              'index_actuel': r['index_actuel'],
              'qte_litres': r['qte_litres'],
            })
        .toList();
  }

  Future<void> deleteAppros(List<String> clientIds) async {
    if (clientIds.isEmpty) return;
    final ph = List.filled(clientIds.length, '?').join(',');
    await _d.delete('pending_appros',
        where: 'client_id IN ($ph)', whereArgs: clientIds);
  }

  Future<int> pendingApproCount() async {
    final r = await _d.rawQuery('SELECT COUNT(*) AS c FROM pending_appros');
    return (r.first['c'] as int?) ?? 0;
  }
}
