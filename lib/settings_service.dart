import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class AppPublicSettings {
  AppPublicSettings({
    required this.appName,
    required this.supportEmail,
    required this.supportPhone,
    required this.maintenanceMode,
    required this.maintenanceMessage,
  });

  final String appName;
  final String supportEmail;
  final String supportPhone;
  final bool maintenanceMode;
  final String maintenanceMessage;

  static AppPublicSettings defaults() => AppPublicSettings(
        appName: 'ReportLink',
        supportEmail: '',
        supportPhone: '',
        maintenanceMode: false,
        maintenanceMessage:
            'The application is under maintenance. We apologize for the inconvenience.',
      );

  factory AppPublicSettings.fromJson(Map<String, dynamic> j) =>
      AppPublicSettings(
        appName: (j['app_name'] ?? 'ReportLink').toString(),
        supportEmail: (j['support_email'] ?? '').toString(),
        supportPhone: (j['support_phone'] ?? '').toString(),
        maintenanceMode: j['maintenance_mode'] == true,
        maintenanceMessage: (j['maintenance_message'] ?? '').toString(),
      );
}

class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const String _baseUrl =
      'http://10.1.2.113/admin-dashboard/api/public-settings/';

  AppPublicSettings _cache = AppPublicSettings.defaults();

  AppPublicSettings get cache => _cache;

  Future<AppPublicSettings> fetch() async {
    try {
      final resp = await http
          .get(Uri.parse(_baseUrl))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        _cache = AppPublicSettings.fromJson(map);
      }
    } catch (_) {
      // keep last known settings
    }
    return _cache;
  }
}


