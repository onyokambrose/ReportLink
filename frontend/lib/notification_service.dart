import 'dart:convert';

import 'package:http/http.dart' as http;

class NotificationComment {
  NotificationComment({
    required this.id,
    required this.sender,
    required this.body,
    required this.createdAt,
  });

  final int id;
  final String sender; // 'user' or 'admin'
  final String body;
  final DateTime createdAt;

  bool get isAdmin => sender == 'admin';
  bool get isUser => sender == 'user';
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const String _base =
      'http://localhost:8000/admin-dashboard/api/notifications';

  Future<List<NotificationComment>> fetchComments(String notificationId) async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/$notificationId/comments/'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = (map['comments'] as List? ?? []);
        return list.map((e) => NotificationComment(
              id: (e['id'] as num).toInt(),
              sender: e['sender'].toString(),
              body: e['body'].toString(),
              createdAt: DateTime.parse(e['created_at']),
            )).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<bool> postComment({
    required String notificationId,
    required String userId,
    required String body,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$_base/$notificationId/comments/post/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_id': userId, 'body': body}),
          )
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
