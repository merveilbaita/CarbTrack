import 'package:flutter/material.dart';

import '../../core/config_store.dart';
import '../../core/server_config.dart';
import '../../tracking/tracking_service.dart';
import '../appro/appro_screen.dart';
import '../login_screen.dart';
import '../suivi/suivi_screen.dart';

/// Coquille principale : onglet « Appro » (outil principal) + « Suivi » (option).
class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.config});
  final ServerConfig config;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  Future<void> _logout() async {
    await TrackingService.stop();
    await ConfigStore.clear();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final titles = ['Appro', 'Suivi GPS'];
    return Scaffold(
      appBar: AppBar(
        title: Text('CarbTrack · ${titles[_index]}'),
        actions: [
          IconButton(
            tooltip: 'Déconnexion',
            onPressed: _logout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          ApproScreen(config: config),
          SuiviScreen(config: config),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.local_gas_station_outlined),
            selectedIcon: Icon(Icons.local_gas_station),
            label: 'Appro',
          ),
          NavigationDestination(
            icon: Icon(Icons.location_on_outlined),
            selectedIcon: Icon(Icons.location_on),
            label: 'Suivi',
          ),
        ],
      ),
    );
  }
}
