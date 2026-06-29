import 'package:flutter/material.dart';

import '../../core/server_config.dart';
import '../../data/appro_repository.dart';

/// Onglet principal : saisie d'un approvisionnement (carburant) par le chauffeur.
class ApproScreen extends StatefulWidget {
  const ApproScreen({super.key, required this.config});
  final ServerConfig config;

  @override
  State<ApproScreen> createState() => _ApproScreenState();
}

class _ApproScreenState extends State<ApproScreen> {
  late final ApproRepository _repo = ApproRepository(widget.config);
  final _formKey = GlobalKey<FormState>();
  final _indexPrec = TextEditingController();
  final _indexAct = TextEditingController();
  final _qte = TextEditingController();

  List<Map<String, dynamic>> _vehicles = [];
  List<Map<String, dynamic>> _recent = [];
  int _pending = 0;
  int? _vehicleId;
  DateTime _date = DateTime.now();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _indexPrec.dispose();
    _indexAct.dispose();
    _qte.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _repo.open();
    await _repo.pullVehicles();
    await _repo.sync(); // vide la file restante
    await _reload();
    if (mounted) setState(() => _loading = false);
  }

  int? get _lockedVehicleId => widget.config.vehicleId;

  Future<void> _reload() async {
    final vehicles = await _repo.cachedVehicles();
    final recent = await _repo.recentAppros();
    final pending = await _repo.pendingCount();
    if (!mounted) return;
    setState(() {
      _vehicles = vehicles;
      _recent = recent;
      _pending = pending;
      // Compte lié à un camion → on le verrouille et on pré-remplit l'index.
      if (_lockedVehicleId != null) {
        _vehicleId = _lockedVehicleId;
        final v = _vehicles.firstWhere((e) => e['id'] == _lockedVehicleId,
            orElse: () => const {});
        final last = (v['last_index'] as num?)?.toDouble() ?? 0;
        if (last > 0) _indexPrec.text = _fmtNum(last);
      }
    });
  }

  void _onVehicleChanged(int? id) {
    _vehicleId = id;
    final v = _vehicles.firstWhere((e) => e['id'] == id, orElse: () => const {});
    final last = (v['last_index'] as num?)?.toDouble() ?? 0;
    setState(() => _indexPrec.text = last > 0 ? _fmtNum(last) : '');
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_vehicleId == null) {
      _snack('Choisissez un véhicule.');
      return;
    }
    setState(() => _saving = true);
    final synced = await _repo.saveAppro(
      date: _isoDate(_date),
      vehicleId: _vehicleId!,
      indexPrecedent: double.tryParse(_indexPrec.text.replaceAll(',', '.')) ?? 0,
      indexActuel: double.tryParse(_indexAct.text.replaceAll(',', '.')) ?? 0,
      qteLitres: double.tryParse(_qte.text.replaceAll(',', '.')) ?? 0,
    );
    _indexAct.clear();
    _qte.clear();
    await _reload();
    if (!mounted) return;
    setState(() => _saving = false);
    _snack(synced
        ? 'Appro enregistré et synchronisé ✓'
        : 'Appro enregistré (hors ligne) — sera envoyé plus tard.');
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _init,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_pending > 0)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cs.tertiaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                const Icon(Icons.cloud_off_rounded, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('$_pending appro(s) en attente d\'envoi')),
              ]),
            ),
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_lockedVehicleId != null)
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Mon camion',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.local_shipping_rounded),
                    ),
                    child: Text(
                      widget.config.vehicleLabel.isNotEmpty
                          ? widget.config.vehicleLabel
                          : 'Camion assigné',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  )
                else
                  DropdownButtonFormField<int>(
                    initialValue: _vehicleId,
                    decoration: const InputDecoration(
                      labelText: 'Véhicule',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.local_shipping_rounded),
                    ),
                    items: _vehicles
                        .map((v) => DropdownMenuItem<int>(
                              value: v['id'] as int,
                              child: Text(
                                '${v['identifier']}'
                                '${(v['label'] ?? '').toString().isNotEmpty ? ' · ${v['label']}' : ''}',
                              ),
                            ))
                        .toList(),
                    onChanged: _onVehicleChanged,
                    validator: (v) => v == null ? 'Requis' : null,
                  ),
                const SizedBox(height: 16),
                InkWell(
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.event_rounded),
                    ),
                    child: Text(_fmtDate(_date)),
                  ),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _indexPrec,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Index précédent',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _indexAct,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Index actuel',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Requis' : null,
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _qte,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Quantité (litres)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.local_gas_station_rounded),
                  ),
                  validator: (v) {
                    final d = double.tryParse((v ?? '').replaceAll(',', '.'));
                    if (d == null || d <= 0) return 'Quantité invalide';
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_rounded),
                  label: const Text('Enregistrer l\'appro'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text('Derniers appros',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('Aucun appro récent.',
                  style: TextStyle(color: cs.outline)),
            )
          else
            ..._recent.map((a) => _ApproRow(a: a)),
        ],
      ),
    );
  }
}

class _ApproRow extends StatelessWidget {
  const _ApproRow({required this.a});
  final Map<String, dynamic> a;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final qte = (a['qte_litres'] as num?)?.toStringAsFixed(1) ?? '—';
    final diff = (a['difference'] as num?)?.round();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(children: [
        Icon(Icons.local_gas_station_rounded, color: cs.primary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${a['vehicle'] ?? '—'} · $qte L',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('${a['date']}${diff != null ? '  ·  +$diff' : ''}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.outline)),
          ]),
        ),
      ]),
    );
  }
}

String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
String _fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
String _isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
