import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/config_store.dart';
import '../core/server_config.dart';
import 'shell/main_shell.dart';

/// Connexion du chauffeur : adresse du serveur + téléphone + PIN.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8001');
  final _phone = TextEditingController();
  final _pin = TextEditingController();
  bool _secure = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _phone.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 8001;
    final baseUrl = '${_secure ? 'https' : 'http'}://$host:$port';

    try {
      final res = await CarbTrackApi.login(
        baseUrl: baseUrl,
        phone: _phone.text.trim(),
        pin: _pin.text.trim(),
      );
      final token = '${res['token']}';
      final driver = (res['driver'] as Map?) ?? const {};
      final vehicle = driver['vehicle'] as Map?;
      final config = ServerConfig(
        host: host,
        port: port,
        token: token,
        secure: _secure,
        driverName: '${driver['name'] ?? ''}',
        vehicleId: (vehicle?['id'] as num?)?.toInt(),
        vehicleLabel: vehicle == null
            ? ''
            : '${vehicle['identifier']}'
                '${(vehicle['label'] ?? '').toString().isNotEmpty ? ' · ${vehicle['label']}' : ''}',
      );
      await ConfigStore.save(config);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MainShell(config: config)),
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Erreur : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.local_shipping_rounded, size: 56, color: cs.primary),
                    const SizedBox(height: 12),
                    Text('CarbTrack',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold, color: cs.primary)),
                    Text('Connexion chauffeur',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 28),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextFormField(
                            controller: _host,
                            decoration: const InputDecoration(
                              labelText: 'Adresse serveur',
                              hintText: '192.168.x.x ou 127.0.0.1',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                (v == null || v.trim().isEmpty) ? 'Requis' : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('HTTPS (serveur hébergé)'),
                      value: _secure,
                      onChanged: (v) => setState(() => _secure = v),
                    ),
                    const SizedBox(height: 4),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Téléphone',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Requis' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _pin,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Code PIN',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Requis' : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_error!,
                            style: TextStyle(color: cs.onErrorContainer)),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Se connecter'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
