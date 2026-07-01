import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'core/config_store.dart';
import 'core/server_config.dart';
import 'features/admin/admin_shell.dart';
import 'features/login_screen.dart';
import 'features/shell/main_shell.dart';
import 'tracking/tracking_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Canal de communication service ↔ UI (doit précéder tout addTaskDataCallback).
  FlutterForegroundTask.initCommunicationPort();
  TrackingService.initService();
  runApp(const CarbTrackApp());
}

const petrol = Color(0xFF0E4C5B);
const amber = Color(0xFFF4A300);

class CarbTrackApp extends StatelessWidget {
  const CarbTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: petrol,
      primary: petrol,
      secondary: amber,
    );
    return MaterialApp(
      title: 'CarbTrack',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7F8),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      home: const _Gate(),
    );
  }
}

/// Décide de l'écran initial selon la présence d'une config appairée.
class _Gate extends StatefulWidget {
  const _Gate();
  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  late final Future<ServerConfig?> _future = ConfigStore.read();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ServerConfig?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final config = snap.data;
        if (config != null && config.token.isNotEmpty) {
          return config.isSupervisor
              ? AdminShell(config: config)
              : MainShell(config: config);
        }
        return const LoginScreen();
      },
    );
  }
}
