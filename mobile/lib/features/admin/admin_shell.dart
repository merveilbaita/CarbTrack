import 'package:flutter/material.dart';

import '../../core/config_store.dart';
import '../../core/server_config.dart';
import '../../tracking/tracking_service.dart';
import '../login_screen.dart';
import 'route_recorder_screen.dart';

/// Interface Admin (superviseur) : enregistrement des itinéraires terrain.
class AdminShell extends StatelessWidget {
  const AdminShell({super.key, required this.config});
  final ServerConfig config;

  Future<void> _logout(BuildContext context) async {
    await TrackingService.stop();
    await ConfigStore.clear();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CarbTrack · Admin'),
        actions: [
          IconButton(
            tooltip: 'Déconnexion',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Superviseur : ${config.driverName.isEmpty ? config.host : config.driverName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: RouteRecorderScreen(config: config)),
        ],
      ),
    );
  }
}
