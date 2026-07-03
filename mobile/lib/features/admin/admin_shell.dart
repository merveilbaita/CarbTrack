import 'package:flutter/material.dart';

import '../../core/config_store.dart';
import '../../core/server_config.dart';
import '../../tracking/tracking_service.dart';
import '../login_screen.dart';
import 'breakdown_screen.dart';
import 'route_recorder_screen.dart';
import 'zone_recorder_screen.dart';

/// Interface Admin (superviseur) : itinéraires terrain + cartographie de zones.
class AdminShell extends StatefulWidget {
  const AdminShell({super.key, required this.config});
  final ServerConfig config;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _index = 0;

  Future<void> _logout(BuildContext context) async {
    await TrackingService.stop();
    await ConfigStore.clear();
    if (!context.mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
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
            color: Theme.of(
              context,
            ).colorScheme.secondary.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Superviseur : ${config.driverName.isEmpty ? config.host : config.driverName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                RouteRecorderScreen(config: config),
                ZoneRecorderScreen(config: config),
                BreakdownScreen(config: config),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route_rounded),
            label: 'Itinéraire',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_location_alt_outlined),
            selectedIcon: Icon(Icons.add_location_alt_rounded),
            label: 'Zone',
          ),
          NavigationDestination(
            icon: Icon(Icons.support_agent_outlined),
            selectedIcon: Icon(Icons.support_agent_rounded),
            label: 'Dépannage',
          ),
        ],
      ),
    );
  }
}
