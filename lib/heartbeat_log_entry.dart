import 'package:intl/intl.dart';

class HeartbeatLogEntry {
  final int id;
  final String createdAt;
  final String userId;
  final String message;
  final int genTime; // timestamp (seconds)

  HeartbeatLogEntry({
    required this.id,
    required this.createdAt,
    required this.userId,
    required this.message,
    required this.genTime,
  });

  // Convert gen_time (seconds) -> string datetime
  String get genTimeFormatted {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      genTime * 1000,
      isUtc: true,
    ).toLocal(); // bỏ .toLocal() nếu muốn giữ UTC
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(dt);
  }

  factory HeartbeatLogEntry.fromJson(Map<String, dynamic> json) {
    return HeartbeatLogEntry(
      id: int.parse(json['id'] as String),
      createdAt: json['created_at'] as String,
      userId: json['user_id'] as String,
      message: json['message'] as String,
      genTime: int.parse(json['gen_time'] as String),
    );
  }
}
