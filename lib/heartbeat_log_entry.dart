import 'package:intl/intl.dart';

class HeartbeatLogEntry {
  final String createdAt; // cột timestamp trong CSV
  final int typeData; // trong payload logs (chưa dùng nhưng giữ lại)
  final String message; // trong payload logs
  final int genTime; // seconds

  HeartbeatLogEntry({
    required this.createdAt,
    required this.typeData,
    required this.message,
    required this.genTime,
  });

  DateTime get genTimeDateTime => DateTime.fromMillisecondsSinceEpoch(
    genTime * 1000,
    isUtc: true,
  ).toLocal();

  String get genTimeFormatted {
    final dt = genTimeDateTime;
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(dt);
  }
}
