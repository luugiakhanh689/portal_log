import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:csv/csv.dart';

int _indexOfAny(List<String> header, List<String> keys) {
  final lowerKeys = keys.map((e) => e.toLowerCase()).toSet();
  return header.indexWhere((h) => lowerKeys.contains(h.toLowerCase()));
}

String _pickUserIdFromJson(Map<String, dynamic> decoded) {
  final v =
      decoded['user_id'] ??
      decoded['userId'] ??
      decoded['uid'] ??
      decoded['user'] ??
      decoded['userID'] ??
      decoded['accountId'];
  return v?.toString() ?? '';
}

Map<String, dynamic> parseCsvInIsolate(String content) {
  final converter = const CsvToListConverter(
    eol: '\n',
    shouldParseNumbers: false,
  );

  try {
    final rows = converter.convert(content);

    if (rows.isEmpty) {
      return {'error': 'File CSV rỗng.', 'logs': <Map<String, dynamic>>[]};
    }

    final header = rows.first.map((e) => e.toString().trim()).toList();

    final timestampIndex = _indexOfAny(header, ['@timestamp', 'timestamp']);
    final requestBodyIndex = _indexOfAny(header, [
      'request_body',
      'requestBody',
    ]);
    final userIdIndex = _indexOfAny(header, ['user_id', 'userId', 'userid']);

    if (timestampIndex == -1 || requestBodyIndex == -1) {
      return {
        'error':
            'Không tìm thấy cột "timestamp/@timestamp" hoặc "request_body" trong header CSV.',
        'logs': <Map<String, dynamic>>[],
      };
    }

    final logs = <Map<String, dynamic>>[];

    for (int i = 1; i < rows.length; i++) {
      final row = rows[i];

      final requiredMax = math.max(timestampIndex, requestBodyIndex);
      if (row.length <= requiredMax) continue;

      final timestampRaw = row[timestampIndex]?.toString() ?? '';
      final requestBodyRaw = row[requestBodyIndex]?.toString() ?? '';

      final userIdFromCsv = (userIdIndex != -1 && row.length > userIdIndex)
          ? (row[userIdIndex]?.toString() ?? '')
          : '';

      if (requestBodyRaw.isEmpty) continue;

      try {
        final normalizedJson = requestBodyRaw.replaceAll('""', '"');
        final decoded = jsonDecode(normalizedJson);

        if (decoded is! Map<String, dynamic>) continue;

        final logsList = decoded['logs'];
        if (logsList is! List) continue;

        final userIdFromJson = _pickUserIdFromJson(decoded);
        final baseUserId = userIdFromCsv.isNotEmpty
            ? userIdFromCsv
            : userIdFromJson;

        for (final item in logsList) {
          if (item is! Map<String, dynamic>) continue;

          final genTimeRaw = item['genTime'];
          final messageRaw = item['message'];
          final typeDataRaw = item['typeData'];

          if (genTimeRaw == null || messageRaw == null) continue;

          final genTime = int.tryParse(genTimeRaw.toString());
          if (genTime == null) continue;

          final typeData = int.tryParse(typeDataRaw?.toString() ?? '0') ?? 0;
          final message = messageRaw.toString();

          final itemUserId =
              item['user_id']?.toString() ??
              item['userId']?.toString() ??
              baseUserId;

          final itemError = item['error']?.toString(); // optional

          logs.add({
            'createdAt': timestampRaw,
            'userId': itemUserId,
            'typeData': typeData,
            'message': message,
            'genTime': genTime,
            'error': itemError,
          });
        }
      } catch (_) {
        continue;
      }
    }

    return {'error': null, 'logs': logs};
  } catch (e) {
    return {'error': 'Lỗi parse CSV: $e', 'logs': <Map<String, dynamic>>[]};
  }
}

Future<Map<String, dynamic>> parseCsvOnWebChunked(
  String content, {
  void Function(double progress)? onProgress, // 0..1
  bool Function()? shouldCancel,
  int yieldEveryLines = 400,
}) async {
  List<String> parseCsvLine(String line) {
    // handle \r\n
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

    final out = <String>[];
    final sb = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];

      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          // escaped quote
          sb.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        out.add(sb.toString());
        sb.clear();
      } else {
        sb.write(ch);
      }
    }

    out.add(sb.toString());
    return out;
  }

  try {
    if (content.isEmpty) {
      return {'error': 'File CSV rỗng.', 'logs': <Map<String, dynamic>>[]};
    }

    final len = content.length;
    int pos = 0;
    int lineNo = 0;

    // read header
    final firstNl = content.indexOf('\n');
    if (firstNl == -1) {
      return {
        'error': 'CSV không có header hợp lệ.',
        'logs': <Map<String, dynamic>>[],
      };
    }

    final headerLine = content.substring(0, firstNl);
    pos = firstNl + 1;
    lineNo = 1;

    final header = parseCsvLine(headerLine).map((e) => e.trim()).toList();

    final timestampIndex = _indexOfAny(header, ['@timestamp', 'timestamp']);
    final requestBodyIndex = _indexOfAny(header, [
      'request_body',
      'requestBody',
    ]);
    final userIdIndex = _indexOfAny(header, ['user_id', 'userId', 'userid']);

    if (timestampIndex == -1 || requestBodyIndex == -1) {
      return {
        'error':
            'Không tìm thấy cột "timestamp/@timestamp" hoặc "request_body" trong header CSV.',
        'logs': <Map<String, dynamic>>[],
      };
    }

    final logs = <Map<String, dynamic>>[];

    int sinceLastYield = 0;

    while (pos < len) {
      if (shouldCancel?.call() == true) {
        return {'error': 'Cancelled', 'logs': <Map<String, dynamic>>[]};
      }

      final nl = content.indexOf('\n', pos);
      final end = (nl == -1) ? len : nl;
      final line = content.substring(pos, end);
      pos = (nl == -1) ? len : nl + 1;

      if (line.isEmpty) continue;

      final row = parseCsvLine(line);

      final requiredMax = math.max(timestampIndex, requestBodyIndex);
      if (row.length <= requiredMax) continue;

      final timestampRaw = row[timestampIndex].toString();
      final requestBodyRaw = row[requestBodyIndex].toString();

      final userIdFromCsv = (userIdIndex != -1 && row.length > userIdIndex)
          ? (row[userIdIndex].toString())
          : '';

      if (requestBodyRaw.isEmpty) continue;

      try {
        final normalizedJson = requestBodyRaw.replaceAll('""', '"');
        final decoded = jsonDecode(normalizedJson);

        if (decoded is! Map<String, dynamic>) continue;
        final logsList = decoded['logs'];
        if (logsList is! List) continue;

        final userIdFromJson = _pickUserIdFromJson(decoded);
        final baseUserId = userIdFromCsv.isNotEmpty
            ? userIdFromCsv
            : userIdFromJson;

        for (final item in logsList) {
          if (item is! Map<String, dynamic>) continue;

          final genTimeRaw = item['genTime'];
          final messageRaw = item['message'];
          final typeDataRaw = item['typeData'];

          if (genTimeRaw == null || messageRaw == null) continue;

          final genTime = int.tryParse(genTimeRaw.toString());
          if (genTime == null) continue;

          final typeData = int.tryParse(typeDataRaw?.toString() ?? '0') ?? 0;
          final message = messageRaw.toString();

          final itemUserId =
              item['user_id']?.toString() ??
              item['userId']?.toString() ??
              baseUserId;

          final itemError = item['error']?.toString();

          logs.add({
            'createdAt': timestampRaw,
            'userId': itemUserId,
            'typeData': typeData,
            'message': message,
            'genTime': genTime,
            'error': itemError,
          });
        }
      } catch (_) {}

      lineNo++;
      sinceLastYield++;

      if (sinceLastYield >= yieldEveryLines) {
        sinceLastYield = 0;
        onProgress?.call(pos / len);
        await Future<void>.delayed(Duration.zero);
      }
    }

    onProgress?.call(1.0);
    return {'error': null, 'logs': logs};
  } catch (e) {
    return {
      'error': 'Lỗi parse CSV (web): $e',
      'logs': <Map<String, dynamic>>[],
    };
  }
}
