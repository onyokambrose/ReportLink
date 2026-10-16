import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'messages_screen.dart';
import 'notification_detail_screen.dart';
import 'package:postgres/postgres.dart';
import 'database.dart';
import 'emergency_trigger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReportLinkRoot());
}

class ReportLinkRoot extends StatefulWidget {
  const ReportLinkRoot({super.key});

  @override
  State<ReportLinkRoot> createState() => _ReportLinkRootState();
}

class _ReportLinkRootState extends State<ReportLinkRoot> {
  final AppState _appState = AppState();
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _appState.load();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      EmergencyTrigger.instance.start(
        contextProvider: () {
          final ctx = _navKey.currentContext;
          if (ctx != null) return ctx;
          return context;
        },
        getNumber: () => _appState.settings.emergencyNumber,
      );
    });
  }

  @override
  @override
  void dispose() {
    EmergencyTrigger.instance.stop();
    super.dispose();
  }

  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final isDark = _appState.settings.darkMode;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'ReportLink',
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          navigatorKey: _navKey,
          home: _buildHome(),
        );
      },
    );
  }

  Widget _buildHome() {
    if (!_appState.initialized) return const SplashScreen();
    if (!_appState.onboardingSeen) {
      return OnboardingScreen(onContinue: _appState.completeOnboarding);
    }
    if (_appState.currentUser == null) {
      return AuthScreen(appState: _appState);
    }
    return HomeShell(appState: _appState);
  }
}

ThemeData buildTheme(Brightness brightness) {
  const orange = Color(0xFFE15712);
  const blue = Color(0xFF2FA0E1);
  final scheme = ColorScheme.fromSeed(
    seedColor: orange,
    brightness: brightness,
    primary: orange,
    secondary: blue,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: brightness == Brightness.dark
        ? const Color(0xFF121212)
        : const Color(0xFFF8F9FB),
    cardTheme: CardThemeData(
      elevation: brightness == Brightness.dark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: orange, width: 1.5),
      ),
    ),
  );
}

class AppState extends ChangeNotifier {
  bool initialized = false;
  bool onboardingSeen = false;
  final AppSettings settings = AppSettings();

  final List<UserAccount> _users = [];
  final List<IncidentReport> _reports = [];
  final List<AppNotificationItem> _notifications = [];

  int _reportSequence = 0;
  String? _sessionUserId;
  String? _adminKeyHash;

  UserAccount? get currentUser =>
      _users.where((u) => u.id == _sessionUserId).cast<UserAccount?>().firstOrNull;

  List<IncidentReport> get myReports {
    final user = currentUser;
    if (user == null) return [];
    if (user.isAdmin) {
      final copy = [..._reports];
      copy.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return copy;
    }
    final mine = _reports.where((r) => r.userId == user.id).toList();
    mine.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return mine;
  }

  List<AppNotificationItem> get myNotifications {
    final user = currentUser;
    if (user == null) return [];
    final visible = user.isAdmin
        ? _notifications
        : _notifications.where((n) => n.userId == user.id).toList();
    final sorted = [...visible]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
  }

  int get unreadNotificationCount => myNotifications.where((n) => !n.read).length;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    onboardingSeen = prefs.getBool('onboarding_seen') ?? false;
    settings.darkMode = prefs.getBool('settings_dark_mode') ?? false;
    settings.notificationsEnabled = prefs.getBool('settings_notifications') ?? true;
    settings.language = prefs.getString('settings_language') ?? 'English';

    _sessionUserId = prefs.getString('session_user_id');
    _adminKeyHash = prefs.getString('admin_key_hash');

    final conn = await Database.instance.open();
    if (conn != null) {
      try {
        await _loadFromPostgres(conn);

        // Fetch emergency number from the DB
        try {
          final emRows = await conn.execute(
            Sql.named('SELECT emergency_number FROM system_settings WHERE id = 1'),
          );
          if (emRows.isNotEmpty) {
            final v = emRows.first[0];
            if (v is String && v.isNotEmpty) settings.emergencyNumber = v;
          }
        } catch (_) {}
        initialized = true;
        notifyListeners();
        return;
      } catch (_) {}
    }

    _reportSequence = prefs.getInt('report_sequence') ?? 0;
    final usersRaw = prefs.getString('users_json') ?? '[]';
    final reportsRaw = prefs.getString('reports_json') ?? '[]';
    final notificationsRaw = prefs.getString('notifications_json') ?? '[]';

    _users
      ..clear()
      ..addAll((jsonDecode(usersRaw) as List)
          .map((e) => UserAccount.fromMap(Map<String, dynamic>.from(e))));
    _reports
      ..clear()
      ..addAll((jsonDecode(reportsRaw) as List)
          .map((e) => IncidentReport.fromMap(Map<String, dynamic>.from(e))));
    _notifications
      ..clear()
      ..addAll((jsonDecode(notificationsRaw) as List)
          .map((e) => AppNotificationItem.fromMap(Map<String, dynamic>.from(e))));

    if (_sessionUserId != null && !_users.any((u) => u.id == _sessionUserId)) {
      _sessionUserId = null;
      await prefs.remove('session_user_id');
    }

    initialized = true;
    notifyListeners();
  }

  Future<void> _loadFromPostgres(Connection conn) async {
    final userRows = await conn.execute('SELECT * FROM users');
    _users.clear();
    for (final row in userRows) {
      _users.add(UserAccount(
        id: row[0] as String,
        fullName: row[1] as String,
        phone: row[2] as String,
        email: row[3] as String,
        passwordSalt: row[4] as String,
        passwordHash: row[5] as String,
        location: (row[6] ?? '') as String,
        profileInfo: (row[7] ?? '') as String,
        createdAt: row[8] as DateTime,
        isAdmin: (row[9] ?? false) as bool,
        profileImagePath: row[10] as String?,
      ));
    }

    final reportRows = await conn.execute('SELECT * FROM reports');
    _reports.clear();
    for (final row in reportRows) {
      final reportId = row[0] as String;
      final timelineRows = await conn.execute(
        Sql.named(
            'SELECT status, description, timestamp FROM report_updates WHERE report_id = @rid ORDER BY timestamp ASC'),
        parameters: {'rid': reportId},
      );
      final timeline = timelineRows
          .map((t) => ReportUpdate(
                status: t[0] as String,
                description: t[1] as String,
                timestamp: t[2] as DateTime,
              ))
          .toList();

      _reports.add(IncidentReport(
        id: reportId,
        userId: row[1] as String,
        reportType: row[2] as String,
        category: row[3] as String,
        subcategory: row[4] as String,
        title: row[5] as String,
        description: row[6] as String,
        priority: row[7] as String,
        contact: (row[8] ?? '') as String,
        latitude: row[9] as double?,
        longitude: row[10] as double?,
        locationDescription: (row[11] ?? '') as String,
        manualLocation: ManualLocation(
          area: (row[12] ?? '') as String,
          town: (row[13] ?? '') as String,
          parish: (row[14] ?? '') as String,
          district: (row[15] ?? '') as String,
          landmark: (row[16] ?? '') as String,
          directions: (row[17] ?? '') as String,
        ),
        attachmentPaths: ((row[18] as List?) ?? []).cast<String>(),
        status: row[19] as String,
        dynamicFields: Map<String, String>.from((row[20] as Map?) ?? const {}),
        timeline: timeline,
        createdAt: row[21] as DateTime,
        updatedAt: row[22] as DateTime,
      ));
    }

    final notifRows = await conn.execute('SELECT * FROM notifications');
    _notifications.clear();
    for (final row in notifRows) {
      _notifications.add(AppNotificationItem(
        id: row[0] as String,
        userId: row[1] as String,
        title: row[2] as String,
        message: row[3] as String,
        type: row[4] as String,
        reportId: row[5] as String?,
        read: (row[6] ?? false) as bool,
        createdAt: row[7] as DateTime,
      ));
    }

    final seqRows = await conn.execute(
        "SELECT COALESCE(MAX(CAST(SPLIT_PART(id, '-', 3) AS INT)), 0) FROM reports");
    _reportSequence = (seqRows.first[0] as int?) ?? 0;
  }

  Future<void> _persistAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('users_json',
        jsonEncode(_users.map((u) => u.toMap()).toList()));
    await prefs.setString('reports_json',
        jsonEncode(_reports.map((r) => r.toMap()).toList()));
    await prefs.setString('notifications_json',
        jsonEncode(_notifications.map((n) => n.toMap()).toList()));
    await prefs.setInt('report_sequence', _reportSequence);
    if (_sessionUserId == null) {
      await prefs.remove('session_user_id');
    } else {
      await prefs.setString('session_user_id', _sessionUserId!);
    }
    if (_adminKeyHash == null) {
      await prefs.remove('admin_key_hash');
    } else {
      await prefs.setString('admin_key_hash', _adminKeyHash!);
    }
    await prefs.setBool('settings_dark_mode', settings.darkMode);
    await prefs.setBool('settings_notifications', settings.notificationsEnabled);
    await prefs.setString('settings_language', settings.language);

    final conn = await Database.instance.open();
    if (conn == null) return;
    try {
      await _writeAllToPostgres(conn);
    } catch (_) {}
  }

  Future<void> _writeAllToPostgres(Connection conn) async {
    for (final u in _users) {
      await conn.execute(
        Sql.named('''
          INSERT INTO users
            (id, full_name, phone, email, password_salt, password_hash,
             location, profile_info, created_at, is_admin, profile_image_path)
          VALUES (@id, @fn, @ph, @em, @salt, @hash, @loc, @info, @ca, @adm, @img)
          ON CONFLICT (id) DO UPDATE SET
            full_name = EXCLUDED.full_name,
            phone = EXCLUDED.phone,
            email = EXCLUDED.email,
            password_salt = EXCLUDED.password_salt,
            password_hash = EXCLUDED.password_hash,
            location = EXCLUDED.location,
            profile_info = EXCLUDED.profile_info,
            is_admin = EXCLUDED.is_admin,
            profile_image_path = EXCLUDED.profile_image_path
        '''),
        parameters: {
          'id': u.id,
          'fn': u.fullName,
          'ph': u.phone,
          'em': u.email,
          'salt': u.passwordSalt,
          'hash': u.passwordHash,
          'loc': u.location,
          'info': u.profileInfo,
          'ca': u.createdAt,
          'adm': u.isAdmin,
          'img': u.profileImagePath,
        },
      );
    }

    for (final r in _reports) {
      await conn.execute(
        Sql.named('''
          INSERT INTO reports
            (id, user_id, report_type, category, subcategory, title, description,
             priority, contact, latitude, longitude, location_description,
             manual_area, manual_town, manual_parish, manual_district,
             manual_landmark, manual_directions, attachment_paths, status,
             dynamic_fields, created_at, updated_at)
          VALUES (@id, @uid, @rt, @cat, @sub, @title, @desc,
             @pri, @con, @lat, @lng, @ld,
             @ma, @mt, @mp, @md,
             @ml, @mdir, @ap, @st,
             @df, @ca, @ua)
          ON CONFLICT (id) DO UPDATE SET
            status = EXCLUDED.status,
            updated_at = EXCLUDED.updated_at,
            title = EXCLUDED.title,
            description = EXCLUDED.description,
            priority = EXCLUDED.priority,
            contact = EXCLUDED.contact,
            latitude = EXCLUDED.latitude,
            longitude = EXCLUDED.longitude,
            location_description = EXCLUDED.location_description,
            manual_area = EXCLUDED.manual_area,
            manual_town = EXCLUDED.manual_town,
            manual_parish = EXCLUDED.manual_parish,
            manual_district = EXCLUDED.manual_district,
            manual_landmark = EXCLUDED.manual_landmark,
            manual_directions = EXCLUDED.manual_directions,
            attachment_paths = EXCLUDED.attachment_paths,
            dynamic_fields = EXCLUDED.dynamic_fields
        '''),
        parameters: {
          'id': r.id,
          'uid': r.userId,
          'rt': r.reportType,
          'cat': r.category,
          'sub': r.subcategory,
          'title': r.title,
          'desc': r.description,
          'pri': r.priority,
          'con': r.contact,
          'lat': r.latitude,
          'lng': r.longitude,
          'ld': r.locationDescription,
          'ma': r.manualLocation.area,
          'mt': r.manualLocation.town,
          'mp': r.manualLocation.parish,
          'md': r.manualLocation.district,
          'ml': r.manualLocation.landmark,
          'mdir': r.manualLocation.directions,
          'ap': r.attachmentPaths,
          'st': r.status,
          'df': r.dynamicFields,
          'ca': r.createdAt,
          'ua': r.updatedAt,
        },
      );

      await conn.execute(
        Sql.named('DELETE FROM report_updates WHERE report_id = @rid'),
        parameters: {'rid': r.id},
      );
      for (final t in r.timeline) {
        await conn.execute(
          Sql.named('''
            INSERT INTO report_updates (report_id, status, description, timestamp)
            VALUES (@rid, @st, @desc, @ts)
          '''),
          parameters: {
            'rid': r.id,
            'st': t.status,
            'desc': t.description,
            'ts': t.timestamp,
          },
        );
      }
    }

    for (final n in _notifications) {
      await conn.execute(
        Sql.named('''
          INSERT INTO notifications
            (id, user_id, title, message, type, report_id, read, created_at)
          VALUES (@id, @uid, @title, @msg, @type, @rid, @read, @ca)
          ON CONFLICT (id) DO UPDATE SET read = EXCLUDED.read
        '''),
        parameters: {
          'id': n.id,
          'uid': n.userId,
          'title': n.title,
          'msg': n.message,
          'type': n.type,
          'rid': n.reportId,
          'read': n.read,
          'ca': n.createdAt,
        },
      );
    }
  }

  Future<void> completeOnboarding() async {
    onboardingSeen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_seen', true);
    notifyListeners();
  }

  String _hashPassword(String password, String salt) {
    return sha256.convert(utf8.encode('$salt:$password')).toString();
  }

  String _randomSalt() {
    final r = Random.secure();
    final values = List<int>.generate(16, (_) => r.nextInt(256));
    return base64Url.encode(values);
  }

  Future<String?> register({
    required String fullName,
    required String phone,
    required String email,
    required String password,
    required String location,
    required String profileInfo,
  }) async {
    if (_users.any((u) => u.email.toLowerCase() == email.toLowerCase())) {
      return 'An account with that email already exists.';
    }
    if (_users.any((u) => u.phone == phone)) {
      return 'An account with that phone already exists.';
    }

    final salt = _randomSalt();
    final user = UserAccount(
      id: 'u_${DateTime.now().millisecondsSinceEpoch}',
      fullName: fullName.trim(),
      phone: phone.trim(),
      email: email.trim().toLowerCase(),
      passwordSalt: salt,
      passwordHash: _hashPassword(password, salt),
      location: location.trim(),
      profileInfo: profileInfo.trim(),
      createdAt: DateTime.now(),
      isAdmin: false,
    );

    _users.add(user);
    _sessionUserId = user.id;

    _createNotification(
      userId: user.id,
      title: 'Registration successful',
      message: 'Welcome to ReportLink, ${user.fullName}.',
      type: 'account',
    );

    await _persistAll();
    notifyListeners();
    return null;
  }

  Future<String?> login(
      {required String emailOrPhone, required String password}) async {
    final query = emailOrPhone.trim().toLowerCase();
    final user = _users.firstWhereOrNull((u) =>
        u.email.toLowerCase() == query ||
        u.phone.trim().toLowerCase() == query);
    if (user == null) return 'No account found with those credentials.';

    final hash = _hashPassword(password, user.passwordSalt);
    if (hash != user.passwordHash) return 'Incorrect password.';
    _sessionUserId = user.id;
    await _persistAll();
    notifyListeners();
    return null;
  }

  Future<void> logout() async {
    _sessionUserId = null;
    await _persistAll();
    notifyListeners();
  }

  Future<String?> updateProfile({
    required String fullName,
    required String phone,
    required String location,
    required String profileInfo,
  }) async {
    final user = currentUser;
    if (user == null) return 'No authenticated user.';

    if (_users.any((u) => u.id != user.id && u.phone == phone.trim())) {
      return 'That phone number is already in use.';
    }

    user.fullName = fullName.trim();
    user.phone = phone.trim();
    user.location = location.trim();
    user.profileInfo = profileInfo.trim();

    await _persistAll();
    notifyListeners();
    return null;
  }

  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = currentUser;
    if (user == null) return 'No authenticated user.';

    final currentHash = _hashPassword(currentPassword, user.passwordSalt);
    if (currentHash != user.passwordHash) return 'Current password is incorrect.';

    final newSalt = _randomSalt();
    user.passwordSalt = newSalt;
    user.passwordHash = _hashPassword(newPassword, newSalt);

    await _persistAll();
    notifyListeners();
    return null;
  }

  Future<void> deleteCurrentAccount() async {
    final user = currentUser;
    if (user == null) return;

    _reports.removeWhere((r) => r.userId == user.id);
    _notifications.removeWhere((n) => n.userId == user.id);
    _users.removeWhere((u) => u.id == user.id);
    _sessionUserId = null;

    await _persistAll();
    notifyListeners();
  }

  Future<void> clearCurrentUserDataOnly() async {
    final user = currentUser;
    if (user == null) return;
    _reports.removeWhere((r) => r.userId == user.id);
    _notifications.removeWhere((n) => n.userId == user.id);
    await _persistAll();
    notifyListeners();
  }

  Future<void> clearAllLocalData() async {
    _users.clear();
    _reports.clear();
    _notifications.clear();
    _sessionUserId = null;
    _reportSequence = 0;
    _adminKeyHash = null;
    onboardingSeen = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    notifyListeners();
  }

  Future<String?> setAdminKeyAndPromoteCurrentUser(String passphrase) async {
    final user = currentUser;
    if (user == null) return 'No authenticated user.';
    if (passphrase.trim().length < 8)
      return 'Admin key must be at least 8 characters.';

    final salt = _randomSalt();
    _adminKeyHash = '$salt:${_hashPassword(passphrase.trim(), salt)}';
    user.isAdmin = true;

    _createNotification(
      userId: user.id,
      title: 'Administrator enabled',
      message: 'Administrator mode has been enabled for your account.',
      type: 'account',
    );

    await _persistAll();
    notifyListeners();
    return null;
  }

  Future<String?> promoteCurrentUserWithAdminKey(String passphrase) async {
    final user = currentUser;
    if (user == null) return 'No authenticated user.';
    if (_adminKeyHash == null) return 'No admin key configured on this device.';

    final parts = _adminKeyHash!.split(':');
    if (parts.length != 2) return 'Admin key data is invalid.';
    final salt = parts[0];
    final hash = parts[1];
    final incoming = _hashPassword(passphrase.trim(), salt);

    if (incoming != hash) return 'Admin key is incorrect.';
    user.isAdmin = true;
    await _persistAll();
    notifyListeners();
    return null;
  }

  Future<void> disableCurrentUserAdmin() async {
    final user = currentUser;
    if (user == null) return;
    user.isAdmin = false;
    await _persistAll();
    notifyListeners();
  }

  Future<void> updateSettings(
      {bool? darkMode, bool? notifications, String? language}) async {
    if (darkMode != null) settings.darkMode = darkMode;
    if (notifications != null) settings.notificationsEnabled = notifications;
    if (language != null) settings.language = language;
    await _persistAll();
    notifyListeners();
  }

  String _nextReportId() {
    _reportSequence += 1;
    final year = DateTime.now().year;
    final sequence = _reportSequence.toString().padLeft(5, '0');
    return 'RL-$year-$sequence';
  }

  Future<String?> submitReport(ReportDraft draft) async {
    final user = currentUser;
    if (user == null) return 'No authenticated user.';

    final now = DateTime.now();
    final report = IncidentReport(
      id: _nextReportId(),
      userId: user.id,
      reportType: draft.reportType,
      category: draft.category,
      subcategory: draft.subcategory,
      title: draft.title,
      description: draft.description,
      priority: draft.priority,
      contact: draft.contact,
      latitude: draft.latitude,
      longitude: draft.longitude,
      locationDescription: draft.locationDescription,
      manualLocation: draft.manualLocation,
      attachmentPaths: draft.attachmentPaths,
      status: ReportStatus.pending.name,
      dynamicFields: draft.dynamicFields,
      timeline: [
        ReportUpdate(
          status: ReportStatus.pending.name,
          description: 'Submitted',
          timestamp: now,
        )
      ],
      createdAt: now,
      updatedAt: now,
    );

    _reports.add(report);

    _createNotification(
      userId: user.id,
      title: 'Report successfully saved',
      message: 'Your report ${report.id} was submitted.',
      type: 'report',
      reportId: report.id,
    );

    await _persistAll();
    notifyListeners();
    return report.id;
  }

  Future<String?> updateReportStatus({
    required String reportId,
    required ReportStatus status,
    required String note,
  }) async {
    final actor = currentUser;
    if (actor == null || !actor.isAdmin)
      return 'Only an administrator can update status.';

    final report = _reports.firstWhereOrNull((r) => r.id == reportId);
    if (report == null) return 'Report not found.';

    report.status = status.name;
    report.updatedAt = DateTime.now();
    report.timeline.add(
      ReportUpdate(
        status: status.name,
        description: note.trim().isEmpty
            ? 'Status updated to ${status.label}'
            : note.trim(),
        timestamp: DateTime.now(),
      ),
    );

    _createNotification(
      userId: report.userId,
      title: 'Report status changed',
      message: '${report.id} is now ${status.label}.',
      type: 'status',
      reportId: report.id,
    );

    await _persistAll();
    notifyListeners();
    return null;
  }

  void _createNotification({
    required String userId,
    required String title,
    required String message,
    required String type,
    String? reportId,
  }) {
    if (!settings.notificationsEnabled) return;
    _notifications.add(AppNotificationItem(
      id: 'n_${DateTime.now().microsecondsSinceEpoch}',
      userId: userId,
      title: title,
      message: message,
      type: type,
      reportId: reportId,
      read: false,
      createdAt: DateTime.now(),
    ));
  }

  Future<void> markNotificationRead(String id) async {
    final n = _notifications.firstWhereOrNull((e) => e.id == id);
    if (n == null) return;
    n.read = true;
    await _persistAll();
    notifyListeners();
  }

  Future<void> markAllNotificationsRead() async {
    final user = currentUser;
    if (user == null) return;
    for (final n in myNotifications) {
      n.read = true;
    }
    await _persistAll();
    notifyListeners();
  }

  int reportsCountForCurrentUser() {
    final user = currentUser;
    if (user == null) return 0;
    if (user.isAdmin) return _reports.length;
    return _reports.where((r) => r.userId == user.id).length;
  }

  int resolvedCountForCurrentUser() {
    final user = currentUser;
    if (user == null) return 0;
    if (user.isAdmin) {
      return _reports
          .where((r) => r.status == ReportStatus.resolved.name)
          .length;
    }
    return _reports
        .where((r) =>
            r.userId == user.id && r.status == ReportStatus.resolved.name)
        .length;
  }

  Map<String, int> statusStats({bool all = false}) {
    final user = currentUser;
    if (user == null) return {};
    final source = all || user.isAdmin
        ? _reports
        : _reports.where((r) => r.userId == user.id).toList();

    return {
      'Total': source.length,
      'Pending': source.where((r) => r.status == ReportStatus.pending.name).length,
      'Under Review':
          source.where((r) => r.status == ReportStatus.underReview.name).length,
      'Assigned':
          source.where((r) => r.status == ReportStatus.assigned.name).length,
      'In Progress':
          source.where((r) => r.status == ReportStatus.inProgress.name).length,
      'Resolved':
          source.where((r) => r.status == ReportStatus.resolved.name).length,
      'Rejected':
          source.where((r) => r.status == ReportStatus.rejected.name).length,
      'Critical': source.where((r) => r.priority == 'Critical').length,
    };
  }

  Map<String, int> categoryStats({bool all = false}) {
    final user = currentUser;
    if (user == null) return {};
    final source = all || user.isAdmin
        ? _reports
        : _reports.where((r) => r.userId == user.id).toList();
    final map = <String, int>{};
    for (final r in source) {
      map[r.category] = (map[r.category] ?? 0) + 1;
    }
    return map;
  }

  Map<String, int> priorityStats({bool all = false}) {
    final user = currentUser;
    if (user == null) return {};
    final source = all || user.isAdmin
        ? _reports
        : _reports.where((r) => r.userId == user.id).toList();
    final map = <String, int>{};
    for (final r in source) {
      map[r.priority] = (map[r.priority] ?? 0) + 1;
    }
    return map;
  }
}

class AppSettings {
  bool darkMode = false;
  bool notificationsEnabled = true;
  String language = 'English';
  String emergencyNumber = '999';
}

class UserAccount {
  UserAccount({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.email,
    required this.passwordSalt,
    required this.passwordHash,
    required this.location,
    required this.profileInfo,
    required this.createdAt,
    required this.isAdmin,
    this.profileImagePath,
  });

  final String id;
  String fullName;
  String phone;
  final String email;
  String passwordSalt;
  String passwordHash;
  String location;
  String profileInfo;
  final DateTime createdAt;
  bool isAdmin;
  String? profileImagePath;

  Map<String, dynamic> toMap() => {
    'id': id,
    'fullName': fullName,
    'phone': phone,
    'email': email,
    'passwordSalt': passwordSalt,
    'passwordHash': passwordHash,
    'location': location,
    'profileInfo': profileInfo,
    'createdAt': createdAt.toIso8601String(),
    'isAdmin': isAdmin,
    'profileImagePath': profileImagePath,
  };

  factory UserAccount.fromMap(Map<String, dynamic> map) => UserAccount(
    id: map['id'],
    fullName: map['fullName'],
    phone: map['phone'],
    email: map['email'],
    passwordSalt: map['passwordSalt'],
    passwordHash: map['passwordHash'],
    location: map['location'] ?? '',
    profileInfo: map['profileInfo'] ?? '',
    createdAt: DateTime.parse(map['createdAt']),
    isAdmin: map['isAdmin'] ?? false,
    profileImagePath: map['profileImagePath'],
  );
}

class ManualLocation {
  ManualLocation({
    this.area = '',
    this.town = '',
    this.parish = '',
    this.district = '',
    this.landmark = '',
    this.directions = '',
  });

  String area;
  String town;
  String parish;
  String district;
  String landmark;
  String directions;

  Map<String, dynamic> toMap() => {
    'area': area,
    'town': town,
    'parish': parish,
    'district': district,
    'landmark': landmark,
    'directions': directions,
  };

  factory ManualLocation.fromMap(Map<String, dynamic>? map) {
    if (map == null) return ManualLocation();
    return ManualLocation(
      area: map['area'] ?? '',
      town: map['town'] ?? '',
      parish: map['parish'] ?? '',
      district: map['district'] ?? '',
      landmark: map['landmark'] ?? '',
      directions: map['directions'] ?? '',
    );
  }

  String toReadableString() {
    final parts = [area, town, parish, district, landmark, directions]
        .where((e) => e.trim().isNotEmpty)
        .toList();
    return parts.join(', ');
  }
}

enum ReportStatus {
  pending,
  underReview,
  assigned,
  inProgress,
  resolved,
  rejected,
}

extension ReportStatusX on ReportStatus {
  String get label {
    switch (this) {
      case ReportStatus.pending:
        return 'Pending';
      case ReportStatus.underReview:
        return 'Under Review';
      case ReportStatus.assigned:
        return 'Assigned';
      case ReportStatus.inProgress:
        return 'In Progress';
      case ReportStatus.resolved:
        return 'Resolved';
      case ReportStatus.rejected:
        return 'Rejected';
    }
  }
}

class ReportUpdate {
  ReportUpdate({
    required this.status,
    required this.description,
    required this.timestamp,
  });

  String status;
  String description;
  DateTime timestamp;

  Map<String, dynamic> toMap() => {
    'status': status,
    'description': description,
    'timestamp': timestamp.toIso8601String(),
  };

  factory ReportUpdate.fromMap(Map<String, dynamic> map) => ReportUpdate(
    status: map['status'],
    description: map['description'],
    timestamp: DateTime.parse(map['timestamp']),
  );
}

class IncidentReport {
  IncidentReport({
    required this.id,
    required this.userId,
    required this.reportType,
    required this.category,
    required this.subcategory,
    required this.title,
    required this.description,
    required this.priority,
    required this.contact,
    required this.latitude,
    required this.longitude,
    required this.locationDescription,
    required this.manualLocation,
    required this.attachmentPaths,
    required this.status,
    required this.dynamicFields,
    required this.timeline,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String userId;
  final String reportType;
  final String category;
  final String subcategory;
  final String title;
  final String description;
  final String priority;
  final String contact;
  final double? latitude;
  final double? longitude;
  final String locationDescription;
  final ManualLocation manualLocation;
  final List<String> attachmentPaths;
  String status;
  final Map<String, String> dynamicFields;
  final List<ReportUpdate> timeline;
  final DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'userId': userId,
    'reportType': reportType,
    'category': category,
    'subcategory': subcategory,
    'title': title,
    'description': description,
    'priority': priority,
    'contact': contact,
    'latitude': latitude,
    'longitude': longitude,
    'locationDescription': locationDescription,
    'manualLocation': manualLocation.toMap(),
    'attachmentPaths': attachmentPaths,
    'status': status,
    'dynamicFields': dynamicFields,
    'timeline': timeline.map((e) => e.toMap()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory IncidentReport.fromMap(Map<String, dynamic> map) => IncidentReport(
    id: map['id'],
    userId: map['userId'],
    reportType: map['reportType'],
    category: map['category'],
    subcategory: map['subcategory'],
    title: map['title'],
    description: map['description'],
    priority: map['priority'],
    contact: map['contact'] ?? '',
    latitude: map['latitude'] != null ? (map['latitude'] as num).toDouble() : null,
    longitude: map['longitude'] != null ? (map['longitude'] as num).toDouble() : null,
    locationDescription: map['locationDescription'] ?? '',
    manualLocation: ManualLocation.fromMap(
      Map<String, dynamic>.from(map['manualLocation'] ?? {}),
    ),
    attachmentPaths: List<String>.from(map['attachmentPaths'] ?? []),
    status: map['status'],
    dynamicFields: Map<String, String>.from(map['dynamicFields'] ?? {}),
    timeline: (map['timeline'] as List)
        .map((e) => ReportUpdate.fromMap(Map<String, dynamic>.from(e)))
        .toList(),
    createdAt: DateTime.parse(map['createdAt']),
    updatedAt: DateTime.parse(map['updatedAt']),
  );
}

class AppNotificationItem {
  AppNotificationItem({
    required this.id,
    required this.userId,
    required this.title,
    required this.message,
    required this.type,
    required this.read,
    required this.createdAt,
    this.reportId,
  });

  final String id;
  final String userId;
  final String title;
  final String message;
  final String type;
  final String? reportId;
  bool read;
  final DateTime createdAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'userId': userId,
    'title': title,
    'message': message,
    'type': type,
    'reportId': reportId,
    'read': read,
    'createdAt': createdAt.toIso8601String(),
  };

  factory AppNotificationItem.fromMap(Map<String, dynamic> map) => AppNotificationItem(
    id: map['id'],
    userId: map['userId'],
    title: map['title'],
    message: map['message'],
    type: map['type'],
    reportId: map['reportId'],
    read: map['read'] ?? false,
    createdAt: DateTime.parse(map['createdAt']),
  );
}

class ReportDraft {
  String reportType = reportTypes.first;
  String category = '';
  String subcategory = '';
  String priority = 'High';
  String title = '';
  String description = '';
  String contact = '';
  double? latitude;
  double? longitude;
  String locationDescription = '';
  ManualLocation manualLocation = ManualLocation();
  List<String> attachmentPaths = [];
  final Map<String, String> dynamicFields = {};
}

class CategoryGroup {
  const CategoryGroup({
    required this.name,
    required this.icon,
    required this.emergency,
    required this.subcategories,
  });

  final String name;
  final IconData icon;
  final bool emergency;
  final List<String> subcategories;
}

const reportTypes = [
  'Emergency',
  'Safety Concern',
  'Community Issue',
  'Infrastructure Problem',
  'Public Service Complaint',
  'Environmental Concern',
  'Other',
];

const categoryGroups = [
  CategoryGroup(
    name: 'Medical & Health',
    icon: Icons.medical_services,
    emergency: true,
    subcategories: [
      'Medical emergency',
      'Accident injury',
      'Unconscious person',
      'Severe bleeding',
      'Pregnancy emergency',
      'Child medical emergency',
      'Mental-health emergency',
      'Missing patient',
      'Disease outbreak',
      'Unsafe health facility',
      'Medicine shortage',
      'Public health concern',
    ],
  ),
  CategoryGroup(
    name: 'Fire & Hazard',
    icon: Icons.local_fire_department,
    emergency: true,
    subcategories: [
      'House fire',
      'Building fire',
      'Vehicle fire',
      'Bush fire',
      'Industrial fire',
      'Gas leak',
      'Chemical spill',
      'Smoke hazard',
      'Explosive hazard',
      'Dangerous materials',
    ],
  ),
  CategoryGroup(
    name: 'Crime & Security',
    icon: Icons.local_police,
    emergency: true,
    subcategories: [
      'Theft',
      'Robbery',
      'Burglary',
      'Assault',
      'Domestic violence',
      'Sexual harassment',
      'Child abuse',
      'Missing person',
      'Suspicious activity',
      'Vandalism',
      'Trespassing',
      'Armed threat',
      'Human trafficking concern',
      'Cybercrime',
      'Fraud/scam',
    ],
  ),
  CategoryGroup(
    name: 'Roads & Transport',
    icon: Icons.traffic,
    emergency: true,
    subcategories: [
      'Road accident',
      'Dangerous driving',
      'Broken traffic lights',
      'Traffic congestion',
      'Road blockage',
      'Fallen tree on road',
      'Pothole',
      'Damaged bridge',
      'Unsafe road',
      'Abandoned vehicle',
      'Vehicle breakdown causing danger',
      'Public transport problem',
    ],
  ),
  CategoryGroup(
    name: 'Electricity',
    icon: Icons.electrical_services,
    emergency: true,
    subcategories: [
      'Power outage',
      'Fallen power line',
      'Exposed electrical wire',
      'Electrical fire',
      'Damaged transformer',
      'Dangerous electrical installation',
      'Street-light failure',
    ],
  ),
  CategoryGroup(
    name: 'Water & Sanitation',
    icon: Icons.water_drop,
    emergency: false,
    subcategories: [
      'Water outage',
      'Broken water pipe',
      'Contaminated water',
      'Sewage overflow',
      'Open drainage',
      'Blocked drainage',
      'Flooding',
      'Garbage accumulation',
      'Poor sanitation',
      'Unsafe public toilet',
    ],
  ),
  CategoryGroup(
    name: 'Infrastructure',
    icon: Icons.apartment,
    emergency: false,
    subcategories: [
      'Damaged building',
      'Collapsed structure',
      'Dangerous construction',
      'Damaged road',
      'Damaged bridge',
      'Open manhole',
      'Broken street light',
      'Damaged public facility',
      'Fallen tree',
      'Public property damage',
    ],
  ),
  CategoryGroup(
    name: 'Environment & Natural Disasters',
    icon: Icons.forest,
    emergency: false,
    subcategories: [
      'Flood',
      'Landslide',
      'Storm damage',
      'Strong winds',
      'Lightning hazard',
      'Drought concern',
      'Illegal dumping',
      'Environmental pollution',
      'River blockage',
      'Wetland destruction',
      'Dangerous tree',
      'Bush burning',
    ],
  ),
  CategoryGroup(
    name: 'Education & Community',
    icon: Icons.school,
    emergency: false,
    subcategories: [
      'Unsafe school facility',
      'Bullying',
      'Child protection concern',
      'Broken classroom',
      'Unsafe dormitory',
      'School sanitation issue',
      'Water problem at school',
      'Electricity problem at school',
      'Community facility damage',
    ],
  ),
  CategoryGroup(
    name: 'Animals',
    icon: Icons.pets,
    emergency: false,
    subcategories: [
      'Dangerous animal',
      'Stray animals',
      'Injured animal',
      'Animal attack',
      'Dead animal on road',
      'Animal welfare concern',
    ],
  ),
  CategoryGroup(
    name: 'Telecommunications',
    icon: Icons.network_cell,
    emergency: false,
    subcategories: [
      'Damaged communication infrastructure',
      'Network outage',
      'Exposed communication cable',
      'Broken public communication equipment',
    ],
  ),
  CategoryGroup(
    name: 'Public & Commercial Safety',
    icon: Icons.storefront,
    emergency: false,
    subcategories: [
      'Unsafe business premises',
      'Food safety concern',
      'Price/scam complaint',
      'Dangerous product',
      'Public disturbance',
      'Illegal dumping by business',
      'Unsafe market conditions',
    ],
  ),
  CategoryGroup(
    name: 'Other',
    icon: Icons.more_horiz,
    emergency: false,
    subcategories: ['Other community issue'],
  ),
];

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.report_gmailerrorred, size: 60, color: Color(0xFFE15712)),
              SizedBox(height: 12),
              Text('ReportLink', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
              SizedBox(height: 12),
              CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.onContinue});

  final Future<void> Function() onContinue;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final compact = width < 600;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Flex(
                direction: compact ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Icon(
                      Icons.shield_moon,
                      size: compact ? 120 : 180,
                      color: const Color(0xFF2FA0E1),
                    ),
                  ),
                  const SizedBox(width: 20, height: 20),
                  Expanded(
                    flex: 2,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment:
                      compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Emergency reporting. Community safety. Fast action.',
                          textAlign: compact ? TextAlign.center : TextAlign.left,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'ReportLink helps you report emergencies and community issues quickly with location details, evidence, and status tracking.',
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: onContinue,
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Get Started'),
                        ),
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.appState});
  final AppState appState;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool isLogin = true;
  bool loading = false;

  final loginEmailPhone = TextEditingController();
  final loginPassword = TextEditingController();

  final regName = TextEditingController();
  final regPhone = TextEditingController();
  final regEmail = TextEditingController();
  final regPassword = TextEditingController();
  final regConfirm = TextEditingController();
  final regLocation = TextEditingController();
  final regProfileInfo = TextEditingController();

  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    loginEmailPhone.dispose();
    loginPassword.dispose();
    regName.dispose();
    regPhone.dispose();
    regEmail.dispose();
    regPassword.dispose();
    regConfirm.dispose();
    regLocation.dispose();
    regProfileInfo.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => loading = true);
    String? error;
    if (isLogin) {
      error = await widget.appState.login(
        emailOrPhone: loginEmailPhone.text,
        password: loginPassword.text,
      );
    } else {
      error = await widget.appState.register(
        fullName: regName.text,
        phone: regPhone.text,
        email: regEmail.text,
        password: regPassword.text,
        location: regLocation.text,
        profileInfo: regProfileInfo.text,
      );
    }
    if (!mounted) return;
    if (!context.mounted) return;
    setState(() => loading = false);

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final maxW = width > 900 ? 800.0 : 560.0;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ReportLink',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 24)),
                        const SizedBox(height: 8),
                        Text(
                          isLogin
                              ? 'Sign in to continue reporting and tracking incidents.'
                              : 'Create a local account to start reporting incidents.',
                        ),
                        const SizedBox(height: 18),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: true, label: Text('Login')),
                            ButtonSegment(value: false, label: Text('Register')),
                          ],
                          selected: {isLogin},
                          onSelectionChanged: (v) => setState(() => isLogin = v.first),
                        ),
                        const SizedBox(height: 16),
                        if (isLogin) ...[
                          TextFormField(
                            controller: loginEmailPhone,
                            decoration:
                            const InputDecoration(labelText: 'Email or Phone number'),
                            validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Enter email or phone' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: loginPassword,
                            decoration: const InputDecoration(labelText: 'Password'),
                            obscureText: true,
                            validator: (v) =>
                            (v == null || v.length < 6) ? 'Password is required' : null,
                          ),
                        ] else ...[
                          TextFormField(
                            controller: regName,
                            decoration: const InputDecoration(labelText: 'Full name'),
                            validator: (v) =>
                            (v == null || v.trim().length < 3) ? 'Enter full name' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: regPhone,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(labelText: 'Phone number'),
                            validator: (v) => (v == null || v.trim().length < 8)
                                ? 'Enter valid phone number'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: regEmail,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(labelText: 'Email address'),
                            validator: (v) =>
                            (v == null || !v.contains('@')) ? 'Enter valid email' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: regPassword,
                            decoration: const InputDecoration(labelText: 'Password'),
                            obscureText: true,
                            validator: (v) =>
                            (v == null || v.length < 8) ? 'At least 8 characters' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: regConfirm,
                            decoration: const InputDecoration(labelText: 'Confirm password'),
                            obscureText: true,
                            validator: (v) => v != regPassword.text
                                ? 'Password confirmation does not match'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: regLocation,
                            decoration: const InputDecoration(
                                labelText: 'Location (optional)', hintText: 'District/Town'),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: regProfileInfo,
                            minLines: 2,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: 'Profile information (optional)',
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: loading ? null : _submit,
                            child: Text(loading
                                ? 'Please wait...'
                                : (isLogin ? 'Login' : 'Create Account')),
                          ),
                        )
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.appState});
  final AppState appState;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final user = widget.appState.currentUser!;
    final isWide = MediaQuery.of(context).size.width >= 900;
    final destinations = [
      const NavDestinationData('Dashboard', Icons.dashboard),
      const NavDestinationData('My Reports', Icons.assignment),
      const NavDestinationData('Profile', Icons.person),
      if (user.isAdmin) const NavDestinationData('Admin', Icons.admin_panel_settings),
      const NavDestinationData('Settings', Icons.settings),
    ];

    final pages = [
      DashboardPage(appState: widget.appState, onQuickReport: _openReportFlow),
      MyReportsPage(appState: widget.appState, allowAdminScope: user.isAdmin),
      ProfilePage(appState: widget.appState),
      if (user.isAdmin) AdminPage(appState: widget.appState),
      SettingsPage(appState: widget.appState),
    ];

    final body = IndexedStack(index: _index, children: pages);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ReportLink'),
        actions: [
          IconButton(
            tooltip: 'Quick emergency report',
            onPressed: _openReportFlow,
            icon: const Icon(Icons.warning_amber_rounded),
          ),
          Stack(
            children: [
              IconButton(
                tooltip: 'Notifications',
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => NotificationsPage(appState: widget.appState),
                    ),
                  );
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.notifications),
              ),
              if (widget.appState.unreadNotificationCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: CircleAvatar(
                    radius: 8,
                    backgroundColor: const Color(0xFFE15712),
                    child: Text(
                      widget.appState.unreadNotificationCount > 99
                          ? '99+'
                          : '${widget.appState.unreadNotificationCount}',
                      style: const TextStyle(fontSize: 9, color: Colors.white),
                    ),
                  ),
                )
            ],
          ),
          Stack(
            children: [
              IconButton(
                tooltip: 'Messages',
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MessagesScreen(
                        userId: user.id,
                        userName: user.fullName,
                      ),
                    ),
                  );
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.chat_bubble_outline),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: isWide
            ? Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (v) => setState(() => _index = v),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final item in destinations)
                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    label: Text(item.label),
                  )
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1280),
                  child: body,
                ),
              ),
            ),
          ],
        )
            : body,
      ),
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (v) => setState(() => _index = v),
        destinations: [
          for (final item in destinations)
            NavigationDestination(icon: Icon(item.icon), label: item.label)
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openReportFlow,
        icon: const Icon(Icons.add_alert),
        label: const Text('Report'),
      ),
    );
  }

  Future<void> _openReportFlow() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReportFlowScreen(appState: widget.appState)),
    );
    if (!context.mounted) return;
    setState(() {});
  }
}

class NavDestinationData {
  const NavDestinationData(this.label, this.icon);
  final String label;
  final IconData icon;
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.appState,
    required this.onQuickReport,
  });

  final AppState appState;
  final VoidCallback onQuickReport;

  @override
  Widget build(BuildContext context) {
    final reports = appState.myReports;
    final stats = appState.statusStats(all: appState.currentUser?.isAdmin ?? false);
    final width = MediaQuery.of(context).size.width;
    final columns = width >= 1200 ? 4 : width >= 800 ? 3 : 2;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                runSpacing: 12,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 220, maxWidth: 700),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Quick Emergency Report',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                        SizedBox(height: 4),
                        Text('Start fast, review details, then confirm submission.'),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: onQuickReport,
                    icon: const Icon(Icons.warning_amber),
                    label: const Text('Report Incident'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Your Dashboard', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: columns,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.8,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: [
              _StatCard(label: 'Total Reports', value: '${stats['Total'] ?? 0}', icon: Icons.list),
              _StatCard(
                  label: 'Pending', value: '${stats['Pending'] ?? 0}', icon: Icons.pending_actions),
              _StatCard(
                  label: 'In Progress',
                  value: '${stats['In Progress'] ?? 0}',
                  icon: Icons.engineering),
              _StatCard(
                  label: 'Resolved', value: '${stats['Resolved'] ?? 0}', icon: Icons.verified),
              _StatCard(
                  label: 'Critical', value: '${stats['Critical'] ?? 0}', icon: Icons.priority_high),
              _StatCard(
                  label: 'Unread Alerts',
                  value: '${appState.unreadNotificationCount}',
                  icon: Icons.notifications_active),
            ],
          ),
          const SizedBox(height: 16),
          Text('Recent Reports', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (reports.isEmpty)
            EmptyStateCard(
              icon: Icons.assignment_outlined,
              title: 'No reports yet',
              subtitle: "You haven't submitted any reports.",
              actionLabel: 'Report an Incident',
              onAction: onQuickReport,
            )
          else
            ...reports.take(4).map(
                  (r) => Card(
                child: ListTile(
                  title: Text('${r.id} â€¢ ${r.title}'),
                  subtitle: Text('${r.category} â€¢ ${r.subcategory}\n${r.locationDescription}'),
                  isThreeLine: true,
                  trailing: StatusChip(status: r.status),
                ),
              ),
            )
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    // Scale down on very narrow screens
    final compact = width < 400;
    final pad = compact ? 8.0 : 12.0;
    final avatarRadius = compact ? 16.0 : 20.0;
    final valueSize = compact ? 18.0 : 22.0;
    final labelSize = compact ? 10.5 : 12.0;

    return Card(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: avatarRadius,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(icon, size: avatarRadius * 1.1),
            ),
            SizedBox(width: compact ? 8 : 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: valueSize,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: labelSize),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MyReportsPage extends StatefulWidget {
  const MyReportsPage({
    super.key,
    required this.appState,
    required this.allowAdminScope,
  });

  final AppState appState;
  final bool allowAdminScope;

  @override
  State<MyReportsPage> createState() => _MyReportsPageState();
}

class _MyReportsPageState extends State<MyReportsPage> {
  final queryCtrl = TextEditingController();
  String statusFilter = 'All';
  String priorityFilter = 'All';
  String categoryFilter = 'All';
  String dateFilter = 'Any';

  @override
  void dispose() {
    queryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reports = widget.appState.myReports;
    final categories = {'All', ...reports.map((e) => e.category)}.toList();

    final query = queryCtrl.text.trim().toLowerCase();
    final filtered = reports.where((r) {
      final statusOk = statusFilter == 'All' ||
          r.status == _statusFromLabel(statusFilter)?.name ||
          (statusFilter == 'Pending' && r.status == ReportStatus.pending.name);
      final priOk = priorityFilter == 'All' || r.priority == priorityFilter;
      final catOk = categoryFilter == 'All' || r.category == categoryFilter;
      final dateOk = _dateOk(r.createdAt, dateFilter);
      final searchOk = query.isEmpty ||
          r.id.toLowerCase().contains(query) ||
          r.title.toLowerCase().contains(query) ||
          r.category.toLowerCase().contains(query) ||
          r.locationDescription.toLowerCase().contains(query) ||
          r.status.toLowerCase().contains(query);
      return statusOk && priOk && catOk && dateOk && searchOk;
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: queryCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Search reports',
                  ),
                ),
              ),
              _dropdown('Status', statusFilter,
                  ['All', 'Pending', 'Under Review', 'Assigned', 'In Progress', 'Resolved', 'Rejected'],
                      (v) => setState(() => statusFilter = v!)),
              _dropdown('Priority', priorityFilter, ['All', 'Low', 'Medium', 'High', 'Critical'],
                      (v) => setState(() => priorityFilter = v!)),
              _dropdown('Category', categoryFilter, categories,
                      (v) => setState(() => categoryFilter = v!)),
              _dropdown('Date', dateFilter, ['Any', 'Today', 'Last 7 Days', 'Last 30 Days'],
                      (v) => setState(() => dateFilter = v!)),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? EmptyStateCard(
            icon: Icons.search_off,
            title: reports.isEmpty ? 'No reports yet' : 'No search results',
            subtitle: reports.isEmpty
                ? "You haven't submitted any reports."
                : 'No reports matched your search.',
          )
              : ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final r = filtered[index];
              return Card(
                child: ListTile(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ReportDetailsScreen(
                        report: r,
                        appState: widget.appState,
                        adminMode: widget.appState.currentUser?.isAdmin ?? false,
                      ))),
                  title: Text('${r.id} â€¢ ${r.title}'),
                  subtitle: Text('${r.category} â†’ ${r.subcategory}\n${r.locationDescription}'),
                  isThreeLine: true,
                  trailing: StatusChip(status: r.status),
                ),
              );
            },
          ),
        )
      ],
    );
  }

  bool _dateOk(DateTime date, String filter) {
    final now = DateTime.now();
    if (filter == 'Any') return true;
    if (filter == 'Today') {
      return date.year == now.year && date.month == now.month && date.day == now.day;
    }
    if (filter == 'Last 7 Days') return date.isAfter(now.subtract(const Duration(days: 7)));
    if (filter == 'Last 30 Days') return date.isAfter(now.subtract(const Duration(days: 30)));
    return true;
  }

  ReportStatus? _statusFromLabel(String label) {
    for (final s in ReportStatus.values) {
      if (s.label == label) return s;
    }
    return null;
  }

  Widget _dropdown(
      String label,
      String value,
      List<String> items,
      ValueChanged<String?> onChanged,
      ) {
    return SizedBox(
      width: 180,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
        onChanged: onChanged,
      ),
    );
  }
}

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key, required this.appState});
  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final items = appState.myNotifications;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Text('Notifications', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              TextButton.icon(
                onPressed: items.isEmpty ? null : appState.markAllNotificationsRead,
                icon: const Icon(Icons.done_all),
                label: const Text('Mark all read'),
              )
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const EmptyStateCard(
            icon: Icons.notifications_none,
            title: 'No Notifications',
            subtitle: "You're all caught up.",
          )
              : ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final n = items[index];
              return Card(
                child: ListTile(
                  onTap: () async {
                    await appState.markNotificationRead(n.id);
                    if (!context.mounted) return;
                    final userId = appState.currentUser?.id ?? '';
                    final report = n.reportId == null
                        ? null
                        : appState.myReports.firstWhereOrNull((r) => r.id == n.reportId);
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => NotificationDetailScreen(
                        notificationId: n.id,
                        title: n.title,
                        message: n.message,
                        createdAt: n.createdAt,
                        userId: userId,
                        reportId: n.reportId,
                        onOpenReport: report == null
                            ? null
                            : () {
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => ReportDetailsScreen(
                                    report: report,
                                    appState: appState,
                                    adminMode: appState.currentUser?.isAdmin ?? false,
                                  ),
                                ));
                              },
                      ),
                    ));
                  },
                  leading: Icon(
                    n.read ? Icons.mark_email_read : Icons.mark_email_unread,
                    color: n.read ? null : Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(n.title),
                  subtitle: Text('${n.message}\n${formatDateTime(n.createdAt)}'),
                  isThreeLine: true,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.appState});
  final AppState appState;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool editing = false;
  late final TextEditingController fullName;
  late final TextEditingController phone;
  late final TextEditingController location;
  late final TextEditingController info;

  @override
  void initState() {
    super.initState();
    final user = widget.appState.currentUser!;
    fullName = TextEditingController(text: user.fullName);
    phone = TextEditingController(text: user.phone);
    location = TextEditingController(text: user.location);
    info = TextEditingController(text: user.profileInfo);
  }

  @override
  void dispose() {
    fullName.dispose();
    phone.dispose();
    location.dispose();
    info.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.appState.currentUser!;
    final reportsCount = widget.appState.reportsCountForCurrentUser();
    final resolvedCount = widget.appState.resolvedCountForCurrentUser();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 38,
                      child: Text(user.fullName.isNotEmpty ? user.fullName[0].toUpperCase() : 'U'),
                    ),
                    const SizedBox(height: 10),
                    Text(user.fullName,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
                    Text(user.email),
                    if (user.isAdmin)
                      const Padding(
                        padding: EdgeInsets.only(top: 8.0),
                        child: Chip(label: Text('Administrator')),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _smallMetric('Reports', '$reportsCount'),
                    _smallMetric('Resolved', '$resolvedCount'),
                    _smallMetric('Created', formatDate(user.createdAt)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('Profile Details',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setState(() => editing = !editing),
                          child: Text(editing ? 'Cancel' : 'Edit'),
                        )
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: fullName,
                      enabled: editing,
                      decoration: const InputDecoration(labelText: 'Full Name'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: phone,
                      enabled: editing,
                      decoration: const InputDecoration(labelText: 'Phone'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: location,
                      enabled: editing,
                      decoration: const InputDecoration(labelText: 'Location'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: info,
                      enabled: editing,
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Profile Info'),
                    ),
                    if (editing) ...[
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () async {
                          final err = await widget.appState.updateProfile(
                            fullName: fullName.text,
                            phone: phone.text,
                            location: location.text,
                            profileInfo: info.text,
                          );
                          if (!context.mounted) return;
                          if (err != null) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text(err)));
                          } else {
                            setState(() => editing = false);
                          }
                        },
                        child: const Text('Save Profile Changes'),
                      )
                    ]
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            ChangePasswordCard(appState: widget.appState),
            const SizedBox(height: 12),
            AccountActionsCard(appState: widget.appState),
          ],
        ),
      ),
    );
  }

  Widget _smallMetric(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          Text(label),
        ],
      ),
    );
  }
}

class ChangePasswordCard extends StatefulWidget {
  const ChangePasswordCard({super.key, required this.appState});
  final AppState appState;

  @override
  State<ChangePasswordCard> createState() => _ChangePasswordCardState();
}

class _ChangePasswordCardState extends State<ChangePasswordCard> {
  final currentCtrl = TextEditingController();
  final newCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();

  @override
  void dispose() {
    currentCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Change Password', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            const SizedBox(height: 8),
            TextField(
              controller: currentCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm new password'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                if (newCtrl.text.length < 8) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('New password too short.')));
                  return;
                }
                if (newCtrl.text != confirmCtrl.text) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Password confirmation does not match.')));
                  return;
                }
                final err = await widget.appState.changePassword(
                  currentPassword: currentCtrl.text,
                  newPassword: newCtrl.text,
                );
                if (!context.mounted) return;
                if (err != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                } else {
                  currentCtrl.clear();
                  newCtrl.clear();
                  confirmCtrl.clear();
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Password updated successfully.')));
                }
              },
              child: const Text('Update Password'),
            )
          ],
        ),
      ),
    );
  }
}

class AccountActionsCard extends StatelessWidget {
  const AccountActionsCard({super.key, required this.appState});
  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Account Management',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => appState.logout(),
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final ok = await showConfirm(context,
                        title: 'Clear My Local Data',
                        message:
                        'This will remove your reports and notifications from this device.');
                    if (ok) await appState.clearCurrentUserDataOnly();
                  },
                  icon: const Icon(Icons.cleaning_services),
                  label: const Text('Clear My Data'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final ok = await showConfirm(context,
                        title: 'Delete Account',
                        message:
                        'This will permanently delete your local account, reports and notifications.');
                    if (ok) await appState.deleteCurrentAccount();
                  },
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Delete Account'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.appState});
  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final user = appState.currentUser!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Settings', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                value: appState.settings.darkMode,
                onChanged: (v) => appState.updateSettings(darkMode: v),
                title: const Text('Dark mode'),
                subtitle: const Text('Use dark appearance across ReportLink'),
              ),
            ),
            Card(
              child: SwitchListTile(
                value: appState.settings.notificationsEnabled,
                onChanged: (v) => appState.updateSettings(notifications: v),
                title: const Text('Notifications'),
                subtitle: const Text('Store and show local notification history'),
              ),
            ),
            Card(
              child: ListTile(
                title: const Text('Language'),
                subtitle: Text('Current: ${appState.settings.language}'),
                trailing: DropdownButton<String>(
                  value: appState.settings.language,
                  items: const ['English', 'Swahili', 'French', 'Arabic']
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) appState.updateSettings(language: v);
                  },
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.location_on),
                title: const Text('Location permissions information'),
                subtitle: const Text(
                    'Location is requested only when creating reports. Manual location entry is always available.'),
              ),
            ),
            Card(
              child: ListTile(
                title: const Text('Privacy information'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showInfoDialog(
                  context,
                  'Privacy',
                  'ReportLink stores your data locally on your device for this offline-first version.',
                ),
              ),
            ),
            Card(
              child: ListTile(
                title: const Text('Terms information'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showInfoDialog(
                  context,
                  'Terms',
                  'Use ReportLink responsibly. False emergency reports may violate local laws.',
                ),
              ),
            ),
            Card(
              child: ListTile(
                title: const Text('About ReportLink'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showInfoDialog(
                  context,
                  'About',
                  'ReportLink is built for emergency and community incident reporting with local persistence.',
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Administrator Access',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 8),
                    if (!user.isAdmin)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: () => _showAdminKeyPrompt(context, create: false),
                            child: const Text('Enable Admin Using Key'),
                          ),
                        ],
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: () => _showAdminKeyPrompt(context, create: true),
                            child: const Text('Create/Rotate Admin Key'),
                          ),
                          OutlinedButton(
                            onPressed: appState.disableCurrentUserAdmin,
                            child: const Text('Disable My Admin Mode'),
                          ),
                        ],
                      )
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                leading: const Icon(Icons.delete_sweep),
                title: const Text('Clear all local app data'),
                subtitle: const Text('Removes users, reports, notifications, session and onboarding state.'),
                onTap: () async {
                  final ok = await showConfirm(context,
                      title: 'Clear all app data',
                      message: 'This action cannot be undone.');
                  if (ok) await appState.clearAllLocalData();
                },
              ),
            )
          ],
        ),
      ),
    );
  }

  Future<void> _showAdminKeyPrompt(BuildContext context, {required bool create}) async {
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(create ? 'Create Admin Key' : 'Enter Admin Key'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: create ? 'New key/passphrase' : 'Admin key/passphrase',
            ),
            validator: (v) => (v == null || v.trim().length < 8)
                ? 'Enter at least 8 characters.'
                : null,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(context, true);
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    if (ok != true || !context.mounted) return;
    final msg = create
        ? await appState.setAdminKeyAndPromoteCurrentUser(ctrl.text)
        : await appState.promoteCurrentUserWithAdminKey(ctrl.text);
    if (!context.mounted) return;
    if (msg != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(create ? 'Admin key saved.' : 'Administrator mode enabled.')),
      );
    }
  }
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.appState});
  final AppState appState;

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final queryCtrl = TextEditingController();
  String statusFilter = 'All';

  @override
  void dispose() {
    queryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reports = widget.appState.myReports;
    final stats = widget.appState.statusStats(all: true);
    final filtered = reports.where((r) {
      final q = queryCtrl.text.trim().toLowerCase();
      final matchesQuery = q.isEmpty ||
          r.id.toLowerCase().contains(q) ||
          r.title.toLowerCase().contains(q) ||
          r.category.toLowerCase().contains(q) ||
          r.locationDescription.toLowerCase().contains(q);
      final statusOk = statusFilter == 'All' ||
          r.status == ReportStatus.values.firstWhere((e) => e.label == statusFilter).name;
      return matchesQuery && statusOk;
    }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metricChip('Total', '${stats['Total'] ?? 0}'),
              _metricChip('Pending', '${stats['Pending'] ?? 0}'),
              _metricChip('Under Review', '${stats['Under Review'] ?? 0}'),
              _metricChip('Assigned', '${stats['Assigned'] ?? 0}'),
              _metricChip('In Progress', '${stats['In Progress'] ?? 0}'),
              _metricChip('Resolved', '${stats['Resolved'] ?? 0}'),
              _metricChip('Critical', '${stats['Critical'] ?? 0}'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: queryCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Search all reports',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  initialValue: statusFilter,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: const [
                    'All',
                    'Pending',
                    'Under Review',
                    'Assigned',
                    'In Progress',
                    'Resolved',
                    'Rejected'
                  ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                  onChanged: (v) => setState(() => statusFilter = v ?? 'All'),
                ),
              )
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const EmptyStateCard(
            icon: Icons.inbox_outlined,
            title: 'No Reports',
            subtitle: 'No reports available for the selected filters.',
          )
              : ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: filtered.length,
            itemBuilder: (_, i) {
              final r = filtered[i];
              return Card(
                child: ListTile(
                  title: Text('${r.id} â€¢ ${r.title}'),
                  subtitle: Text('${r.category} â€¢ ${r.priority}\n${r.locationDescription}'),
                  isThreeLine: true,
                  trailing: StatusChip(status: r.status),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ReportDetailsScreen(
                      report: r,
                      appState: widget.appState,
                      adminMode: true,
                    ),
                  )),
                ),
              );
            },
          ),
        )
      ],
    );
  }

  Widget _metricChip(String label, String value) {
    return Chip(
      label: Text('$label: $value'),
      side: BorderSide.none,
    );
  }
}

class ReportDetailsScreen extends StatelessWidget {
  const ReportDetailsScreen({
    super.key,
    required this.report,
    required this.appState,
    required this.adminMode,
  });

  final IncidentReport report;
  final AppState appState;
  final bool adminMode;

  @override
  Widget build(BuildContext context) {
    final owner = appState.currentUser?.isAdmin == true
        ? appState.myReports.firstWhereOrNull((r) => r.id == report.id)
        : report;
    final item = owner ?? report;

    return Scaffold(
      appBar: AppBar(title: Text(item.id)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.title,
                            style:
                            const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          StatusChip(status: item.status),
                          Chip(label: Text(item.priority)),
                          Chip(label: Text(item.reportType)),
                        ]),
                        const SizedBox(height: 8),
                        Text(item.description),
                        const Divider(height: 24),
                        _row('Category', '${item.category} â†’ ${item.subcategory}'),
                        _row('Location', item.locationDescription.isEmpty ? '-' : item.locationDescription),
                        _row('Coordinates',
                            '${item.latitude?.toStringAsFixed(5) ?? '-'}, ${item.longitude?.toStringAsFixed(5) ?? '-'}'),
                        _row('Manual location', item.manualLocation.toReadableString().isEmpty ? '-' : item.manualLocation.toReadableString()),
                        _row('Contact', item.contact.isEmpty ? '-' : item.contact),
                        _row('Submitted', formatDateTime(item.createdAt)),
                        _row('Updated', formatDateTime(item.updatedAt)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (item.dynamicFields.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Additional Information',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                          const SizedBox(height: 8),
                          ...item.dynamicFields.entries
                              .map((e) => _row(e.key, e.value.isEmpty ? '-' : e.value))
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Report Timeline',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                        const SizedBox(height: 8),
                        ...item.timeline.map((t) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.circle, size: 12),
                          title: Text('${statusLabelFromName(t.status)} â€¢ ${formatDateTime(t.timestamp)}'),
                          subtitle: Text(t.description),
                        )),
                      ],
                    ),
                  ),
                ),
                if (adminMode) ...[
                  const SizedBox(height: 10),
                  AdminStatusUpdateCard(report: item, appState: appState),
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 130, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(child: Text(v)),
      ],
    ),
  );
}

class AdminStatusUpdateCard extends StatefulWidget {
  const AdminStatusUpdateCard({super.key, required this.report, required this.appState});
  final IncidentReport report;
  final AppState appState;

  @override
  State<AdminStatusUpdateCard> createState() => _AdminStatusUpdateCardState();
}

class _AdminStatusUpdateCardState extends State<AdminStatusUpdateCard> {
  late ReportStatus status;
  final note = TextEditingController();

  @override
  void initState() {
    super.initState();
    status = ReportStatus.values
        .firstWhere((s) => s.name == widget.report.status, orElse: () => ReportStatus.pending);
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Admin Report Management',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            const SizedBox(height: 8),
            DropdownButtonFormField<ReportStatus>(
              initialValue: status,
              decoration: const InputDecoration(labelText: 'Update status'),
              items: ReportStatus.values
                  .map((s) => DropdownMenuItem(value: s, child: Text(s.label)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => status = v);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: note,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Resolution / update note'),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () async {
                final err = await widget.appState.updateReportStatus(
                  reportId: widget.report.id,
                  status: status,
                  note: note.text,
                );
                if (!context.mounted) return;
                if (err != null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                } else {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Report status updated.')));
                }
              },
              child: const Text('Apply Status Update'),
            )
          ],
        ),
      ),
    );
  }
}

class ReportFlowScreen extends StatefulWidget {
  const ReportFlowScreen({super.key, required this.appState});
  final AppState appState;

  @override
  State<ReportFlowScreen> createState() => _ReportFlowScreenState();
}

class _ReportFlowScreenState extends State<ReportFlowScreen> {
  final draft = ReportDraft();
  int step = 0;

  final formKey = GlobalKey<FormState>();
  final searchCategoryCtrl = TextEditingController();
  final titleCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  final contactCtrl = TextEditingController();
  final locationDescriptionCtrl = TextEditingController();

  final areaCtrl = TextEditingController();
  final townCtrl = TextEditingController();
  final parishCtrl = TextEditingController();
  final districtCtrl = TextEditingController();
  final landmarkCtrl = TextEditingController();
  final directionsCtrl = TextEditingController();

  final dynamicControllers = <String, TextEditingController>{};

  bool locating = false;
  String? locationError;

  @override
  void initState() {
    super.initState();
    final user = widget.appState.currentUser!;
    contactCtrl.text = '${user.phone} / ${user.email}';
    locationDescriptionCtrl.text = user.location;
  }

  @override
  void dispose() {
    searchCategoryCtrl.dispose();
    titleCtrl.dispose();
    descCtrl.dispose();
    contactCtrl.dispose();
    locationDescriptionCtrl.dispose();
    areaCtrl.dispose();
    townCtrl.dispose();
    parishCtrl.dispose();
    districtCtrl.dispose();
    landmarkCtrl.dispose();
    directionsCtrl.dispose();
    for (final c in dynamicControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<CategoryGroup> get _filteredCategories {
    final q = searchCategoryCtrl.text.trim().toLowerCase();
    var list = categoryGroups.where((c) {
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.subcategories.any((s) => s.toLowerCase().contains(q));
    }).toList();
    list.sort((a, b) {
      if (a.emergency == b.emergency) return a.name.compareTo(b.name);
      return a.emergency ? -1 : 1;
    });
    return list;
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: source, imageQuality: 70);
    if (file == null) return;
    setState(() => draft.attachmentPaths.add(file.path));
  }

  Future<void> _detectLocation() async {
    setState(() {
      locating = true;
      locationError = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          locationError =
          "We couldn't determine your current location. Please enable location services or enter your location manually.";
          locating = false;
        });
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          locationError =
          "We couldn't determine your current location. Please enable location services or enter your location manually.";
          locating = false;
        });
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      draft.latitude = pos.latitude;
      draft.longitude = pos.longitude;

      try {
        final places =
            await Geocoding().placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (places.isNotEmpty) {
          final p = places.first;
          final desc = [
            p.street,
            p.locality,
            p.subAdministrativeArea,
            p.administrativeArea,
            p.country
          ].whereType<String>().where((e) => e.trim().isNotEmpty).join(', ');
          locationDescriptionCtrl.text = desc;
        }
      } catch (_) {}
    } catch (_) {
      locationError =
      "We couldn't determine your current location. Please enable location services or enter your location manually.";
    }

    setState(() {
      locating = false;
    });
  }

  List<String> _dynamicFieldKeysForSubcategory(String sub) {
    final s = sub.toLowerCase();
    if (s.contains('road accident')) {
      return [
        'Number of people affected',
        'Vehicles involved',
        'Injuries observed',
        'Is road blocked?',
      ];
    }
    if (s.contains('fire')) {
      return [
        'Fire type (building/vehicle/open area)',
        'Are people trapped?',
        'Visible flames intensity',
        'Smoke level',
        'Nearby hazards',
      ];
    }
    if (s.contains('water') || s.contains('sewage') || s.contains('drainage')) {
      return [
        'Water source / system',
        'Problem type',
        'Area affected',
        'How long has this lasted?',
      ];
    }
    if (s.contains('crime') || s.contains('assault') || s.contains('robbery')) {
      return [
        'Suspect details (if safe)',
        'Number of people involved',
        'Immediate danger level',
      ];
    }
    return ['Additional details'];
  }

  bool _validateStep() {
    if (step == 0) {
      if (draft.category.isEmpty || draft.subcategory.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select category and subcategory.')),
        );
        return false;
      }
      return true;
    }
    if (step == 1) {
      if (!(formKey.currentState?.validate() ?? false)) return false;
      draft.title = titleCtrl.text.trim();
      draft.description = descCtrl.text.trim();
      draft.contact = contactCtrl.text.trim();
      draft.locationDescription = locationDescriptionCtrl.text.trim();
      draft.manualLocation = ManualLocation(
        area: areaCtrl.text.trim(),
        town: townCtrl.text.trim(),
        parish: parishCtrl.text.trim(),
        district: districtCtrl.text.trim(),
        landmark: landmarkCtrl.text.trim(),
        directions: directionsCtrl.text.trim(),
      );
      for (final e in dynamicControllers.entries) {
        draft.dynamicFields[e.key] = e.value.text.trim();
      }

      if (draft.locationDescription.isEmpty && draft.manualLocation.toReadableString().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Provide location details or manual location information.'),
        ));
        return false;
      }
      return true;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final large = width > 920;
    final categoryColumns = width >= 1200
        ? 6
        : width >= 900
        ? 4
        : width >= 700
        ? 3
        : 2;

    return Scaffold(
      appBar: AppBar(title: const Text('Create Report')),
      body: SafeArea(
        child: Form(
          key: formKey,
          child: Stepper(
            currentStep: step,
            type: large ? StepperType.horizontal : StepperType.vertical,
            onStepCancel: () {
              if (step == 0) {
                Navigator.of(context).maybePop();
              } else {
                setState(() => step -= 1);
              }
            },
            onStepContinue: () async {
              if (!_validateStep()) return;
              if (step < 2) {
                setState(() => step += 1);
              } else {
                await _submit();
              }
            },
            controlsBuilder: (context, details) {
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: details.onStepContinue,
                    child: Text(step == 2 ? 'Submit Report' : 'Continue'),
                  ),
                  OutlinedButton(
                    onPressed: details.onStepCancel,
                    child: Text(step == 0 ? 'Back' : 'Previous'),
                  ),
                ],
              );
            },
            steps: [
              Step(
                title: const Text('Type & Category'),
                isActive: step >= 0,
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: draft.reportType,
                        decoration: const InputDecoration(labelText: 'Report type'),
                        items: reportTypes
                            .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                            .toList(),
                        onChanged: (v) => setState(() => draft.reportType = v ?? reportTypes.first),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: searchCategoryCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          labelText: 'Search categories/subcategories',
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('Emergency categories are prioritized at the top.'),
                      const SizedBox(height: 10),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: categoryColumns,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          childAspectRatio: 1.4,
                        ),
                        itemCount: _filteredCategories.length,
                        itemBuilder: (context, i) {
                          final c = _filteredCategories[i];
                          final selected = draft.category == c.name;
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => setState(() {
                              draft.category = c.name;
                              draft.subcategory = c.subcategories.first;
                              dynamicControllers.clear();
                            }),
                            child: Ink(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: selected
                                      ? const Color(0xFFE15712)
                                      : Theme.of(context).dividerColor,
                                  width: selected ? 2 : 1,
                                ),
                              ),
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(c.icon,
                                      color: c.emergency
                                          ? const Color(0xFFE15712)
                                          : Theme.of(context).colorScheme.primary),
                                  const SizedBox(height: 6),
                                  Text(
                                    c.name,
                                    maxLines: 2,
                                    textAlign: TextAlign.center,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      if (draft.category.isNotEmpty)
                        DropdownButtonFormField<String>(
                          initialValue: draft.subcategory.isEmpty ? null : draft.subcategory,
                          decoration: const InputDecoration(labelText: 'Subcategory'),
                          items: categoryGroups
                              .firstWhere((c) => c.name == draft.category)
                              .subcategories
                              .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                              .toList(),
                          onChanged: (v) => setState(() {
                            draft.subcategory = v ?? '';
                            dynamicControllers.clear();
                          }),
                        ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        initialValue: draft.priority,
                        decoration: const InputDecoration(labelText: 'Priority'),
                        items: const ['Low', 'Medium', 'High', 'Critical']
                            .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                            .toList(),
                        onChanged: (v) => setState(() => draft.priority = v ?? 'High'),
                      ),
                    ],
                  ),
                ),
              ),
              Step(
                title: const Text('Details & Location'),
                isActive: step >= 1,
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: titleCtrl,
                        decoration: const InputDecoration(labelText: 'Title'),
                        validator: (v) => (v == null || v.trim().length < 4)
                            ? 'Provide a clear title.'
                            : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: descCtrl,
                        minLines: 3,
                        maxLines: 5,
                        decoration: const InputDecoration(labelText: 'Description'),
                        validator: (v) => (v == null || v.trim().length < 10)
                            ? 'Provide detailed description.'
                            : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: contactCtrl,
                        decoration: const InputDecoration(labelText: 'Contact information'),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Contact information is required.'
                            : null,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: locating ? null : _detectLocation,
                            icon: const Icon(Icons.my_location),
                            label: Text(locating ? 'Locating...' : 'Use Current Location'),
                          ),
                          const SizedBox(width: 8),
                          if (draft.latitude != null && draft.longitude != null)
                            Flexible(
                              child: Text(
                                '${draft.latitude!.toStringAsFixed(5)}, ${draft.longitude!.toStringAsFixed(5)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                      if (locationError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(locationError!, style: const TextStyle(color: Colors.red)),
                        ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: locationDescriptionCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Location description',
                          hintText: 'Street, area, district, landmarks',
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('Manual Location Entry'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _smallField('Area', areaCtrl),
                          _smallField('Village/Town', townCtrl),
                          _smallField('Parish', parishCtrl),
                          _smallField('District', districtCtrl),
                          _smallField('Landmark', landmarkCtrl),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: directionsCtrl,
                        minLines: 2,
                        maxLines: 3,
                        decoration: const InputDecoration(labelText: 'Additional directions'),
                      ),
                      const SizedBox(height: 12),
                      const Text('Attach Media (optional)'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _pickImage(ImageSource.camera),
                            icon: const Icon(Icons.photo_camera),
                            label: const Text('Camera'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _pickImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library),
                            label: const Text('Gallery'),
                          ),
                        ],
                      ),
                      if (draft.attachmentPaths.isNotEmpty)
                        Column(
                          children: draft.attachmentPaths
                              .map((p) => Card(
                            child: ListTile(
                              title: Text(p.split('/').last),
                              subtitle: Text(p),
                              trailing: IconButton(
                                onPressed: () => setState(() => draft.attachmentPaths.remove(p)),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ),
                          ))
                              .toList(),
                        ),
                      const SizedBox(height: 10),
                      _dynamicFieldsSection(),
                    ],
                  ),
                ),
              ),
              Step(
                title: const Text('Review & Submit'),
                isActive: step >= 2,
                content: _reviewWidget(),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _smallField(String label, TextEditingController ctrl) {
    return SizedBox(
      width: 220,
      child: TextField(
        controller: ctrl,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _dynamicFieldsSection() {
    if (draft.subcategory.isEmpty) return const SizedBox.shrink();
    final keys = _dynamicFieldKeysForSubcategory(draft.subcategory);
    for (final k in keys) {
      dynamicControllers.putIfAbsent(k, () => TextEditingController());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Incident-specific details'),
        const SizedBox(height: 8),
        ...keys.map((k) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: dynamicControllers[k],
            decoration: InputDecoration(labelText: k),
          ),
        )),
      ],
    );
  }

  Widget _reviewWidget() {
    draft.title = titleCtrl.text.trim();
    draft.description = descCtrl.text.trim();
    draft.contact = contactCtrl.text.trim();
    draft.locationDescription = locationDescriptionCtrl.text.trim();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _reviewRow('Report type', draft.reportType),
            _reviewRow('Category', '${draft.category} â†’ ${draft.subcategory}'),
            _reviewRow('Priority', draft.priority),
            _reviewRow('Title', draft.title),
            _reviewRow('Description', draft.description),
            _reviewRow('Location', draft.locationDescription),
            _reviewRow(
                'Coordinates',
                '${draft.latitude?.toStringAsFixed(5) ?? '-'}, '
                    '${draft.longitude?.toStringAsFixed(5) ?? '-'}'),
            _reviewRow('Manual location', draft.manualLocation.toReadableString()),
            _reviewRow('Contact', draft.contact),
            _reviewRow('Attachments', '${draft.attachmentPaths.length} file(s)'),
            const Divider(),
            const Text('Confirm submission', style: TextStyle(fontWeight: FontWeight.w700)),
            const Text(
                'After you submit, your report is stored locally and appears in tracking and notifications.'),
          ],
        ),
      ),
    );
  }

  Widget _reviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(value.isEmpty ? '-' : value)),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_validateStep()) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirm Submission'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Emergency type: ${draft.subcategory}'),
            Text('Description: ${draft.description}'),
            Text('Priority: ${draft.priority}'),
            Text('Location: ${draft.locationDescription.isEmpty ? draft.manualLocation.toReadableString() : draft.locationDescription}'),
            Text('Contact: ${draft.contact}'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Edit')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Submit')),
        ],
      ),
    );

    if (confirmed != true) return;

    final reportId = await widget.appState.submitReport(draft);
    if (!mounted) return;
    if (!context.mounted) return;

    if (reportId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Failed to submit report.')));
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ReportSuccessScreen(reportId: reportId, appState: widget.appState),
      ),
    );
  }
}

class ReportSuccessScreen extends StatelessWidget {
  const ReportSuccessScreen({super.key, required this.reportId, required this.appState});
  final String reportId;
  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green, size: 70),
                      const SizedBox(height: 12),
                      const Text('Report Submitted Successfully',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 24),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      Text(reportId,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          FilledButton(
                            onPressed: () {
                              final report = appState.myReports.firstWhereOrNull((r) => r.id == reportId);
                              if (report != null) {
                                Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => ReportDetailsScreen(
                                      report: report,
                                      appState: appState,
                                      adminMode: appState.currentUser?.isAdmin ?? false,
                                    )));
                              }
                            },
                            child: const Text('View Report'),
                          ),
                          OutlinedButton(
                            onPressed: () {
                              final report = appState.myReports.firstWhereOrNull((r) => r.id == reportId);
                              if (report != null) {
                                Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => ReportDetailsScreen(
                                      report: report,
                                      appState: appState,
                                      adminMode: appState.currentUser?.isAdmin ?? false,
                                    )));
                              }
                            },
                            child: const Text('Track Report'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Return Home'),
                          ),
                        ],
                      )
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyStateCard extends StatelessWidget {
  const EmptyStateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
              const SizedBox(height: 6),
              Text(subtitle, textAlign: TextAlign.center),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 12),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ]
            ],
          ),
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final s = statusLabelFromName(status);
    final color = switch (status) {
      'pending' => Colors.orange,
      'underReview' => Colors.blue,
      'assigned' => Colors.indigo,
      'inProgress' => Colors.deepPurple,
      'resolved' => Colors.green,
      'rejected' => Colors.red,
      _ => Colors.grey,
    };
    return Chip(
      label: Text(s),
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.2)),
      labelStyle: TextStyle(color: color.shade700),
    );
  }
}

String statusLabelFromName(String name) {
  final match = ReportStatus.values.firstWhereOrNull((e) => e.name == name);
  return match?.label ?? name;
}

String formatDate(DateTime d) {
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String formatDateTime(DateTime d) {
  final h = d.hour.toString().padLeft(2, '0');
  final m = d.minute.toString().padLeft(2, '0');
  return '${formatDate(d)} $h:$m';
}

Future<void> showInfoDialog(BuildContext context, String title, String message) async {
  await showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
}

Future<bool> showConfirm(
    BuildContext context, {
      required String title,
      required String message,
    }) async {
  final v = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
      ],
    ),
  );
  return v ?? false;
}

extension FirstWhereOrNullExt<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T element) test) {
    for (final i in this) {
      if (test(i)) return i;
    }
    return null;
  }
}












