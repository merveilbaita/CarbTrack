import 'package:carbtrack/core/server_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ServerConfig encode/decode round-trip', () {
    const cfg = ServerConfig(
      host: '192.168.1.10',
      port: 8001,
      token: 'abc123',
      secure: true,
      driverName: 'Chauffeur Démo',
    );
    final restored = ServerConfig.decode(cfg.encode());
    expect(restored.host, cfg.host);
    expect(restored.port, cfg.port);
    expect(restored.token, cfg.token);
    expect(restored.secure, cfg.secure);
    expect(restored.driverName, cfg.driverName);
    expect(restored.baseUrl, 'https://192.168.1.10:8001');
  });
}
