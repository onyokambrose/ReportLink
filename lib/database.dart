import 'package:postgres/postgres.dart';

/// Single shared Postgres connection for the app.
///
/// Works on Android via `adb reverse tcp:5432 tcp:5432`,
/// which makes the phone's localhost:5432 reach the PC's Postgres.
class Database {
  Database._();
  static final Database instance = Database._();

  Connection? _conn;
  bool _broken = false;

  bool get isBroken => _broken;

  /// Opens (or reuses) a connection. Returns null if unreachable.
  Future<Connection?> open() async {
    if (_broken) return null;
    if (_conn != null && _conn!.isOpen) return _conn;

    try {
      _conn = await Connection.open(
        Endpoint(
          host: '10.1.2.113',
          port: 5432,
          database: 'reportlink',
          username: 'postgres',
          password: '2Keroos@4', // â† change to your real Postgres password
        ),
        settings: const ConnectionSettings(
          sslMode: SslMode.disable,
          connectTimeout: Duration(seconds: 5),
        ),
      );
      return _conn;
    } catch (_) {
      _broken = true;
      return null;
    }
  }

  Future<void> close() async {
    try {
      await _conn?.close();
    } catch (_) {}
    _conn = null;
  }

  /// Allows the app to retry after a failure.
  void reset() {
    _broken = false;
    _conn = null;
  }
}

