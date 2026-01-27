import 'package:intl/intl.dart';

class HeartbeatLogEntry {
  final String createdAt; // cột @timestamp trong CSV
  final String userId; // cột user_id trong CSV
  final int typeData; // trong payload logs
  final String message; // trong payload logs
  final int genTime; // seconds

  HeartbeatLogEntry({
    required this.createdAt,
    required this.userId,
    required this.typeData,
    required this.message,
    required this.genTime,
  });

  DateTime get genTimeDateTime =>
      DateTime.fromMillisecondsSinceEpoch(genTime, isUtc: true).toLocal();

  String get genTimeFormatted {
    final dt = genTimeDateTime;
    return DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(dt);
  }
}
