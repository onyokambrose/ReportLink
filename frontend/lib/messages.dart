import 'package:postgres/postgres.dart';
import 'database.dart';

class Message {
  Message({
    required this.id,
    required this.userId,
    required this.sender,
    required this.body,
    required this.read,
    required this.createdAt,
  });

  final int id;
  final String userId;
  final String sender;   // 'user' or 'admin'
  final String body;
  bool read;
  final DateTime createdAt;

  bool get isAdmin => sender == 'admin';
  bool get isUser  => sender == 'user';
}

class MessagesService {
  MessagesService._();
  static final MessagesService instance = MessagesService._();

  Future<Connection?> _conn() => Database.instance.open();

  Future<List<Message>> loadThread(String userId) async {
    final conn = await _conn();
    if (conn == null) return [];
    try {
      final rows = await conn.execute(
        Sql.named('''
          SELECT id, user_id, sender, body, read, created_at
          FROM messages
          WHERE user_id = @uid
          ORDER BY created_at ASC
        '''),
        parameters: {'uid': userId},
      );
      return rows.map((r) => Message(
        id: (r[0] as num).toInt(),
        userId: r[1] as String,
        sender: r[2] as String,
        body: r[3] as String,
        read: (r[4] ?? false) as bool,
        createdAt: r[5] as DateTime,
      )).toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> sendMessage({
    required String userId,
    required String body,
    required String sender, // 'user' or 'admin'
  }) async {
    final conn = await _conn();
    if (conn == null) return false;
    try {
      await conn.execute(
        Sql.named('''
          INSERT INTO messages (user_id, sender, body, read, created_at)
          VALUES (@uid, @sender, @body, FALSE, NOW())
        '''),
        parameters: {
          'uid': userId,
          'sender': sender,
          'body': body,
        },
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Mark all messages of a given direction as read for this user.
  Future<void> markRead({
    required String userId,
    required String fromSender, // who wrote the messages we want to mark read
  }) async {
    final conn = await _conn();
    if (conn == null) return;
    try {
      await conn.execute(
        Sql.named('''
          UPDATE messages
          SET read = TRUE
          WHERE user_id = @uid AND sender = @sender AND read = FALSE
        '''),
        parameters: {'uid': userId, 'sender': fromSender},
      );
    } catch (_) {}
  }

  Future<int> unreadFromAdmin(String userId) async {
    final conn = await _conn();
    if (conn == null) return 0;
    try {
      final rows = await conn.execute(
        Sql.named('''
          SELECT COUNT(*) FROM messages
          WHERE user_id = @uid AND sender = 'admin' AND read = FALSE
        '''),
        parameters: {'uid': userId},
      );
      return (rows.first[0] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
