import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:portal_log/heartbeat_log_entry.dart';
import 'package:printing/printing.dart';

void main() {
  runApp(const MyApp());
}

// ================== PARSER ISOLATE ==================
/// Hàm chạy trong Isolate để parse CSV.
/// Input: toàn bộ nội dung CSV (String)
/// Output:
/// {
///   "error": String? (nếu có),
///   "logs": [
///      {"createdAt": ..., "typeData": ..., "message": ..., "genTime": ...},
///      ...
///   ]
/// }
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

    int timestampIndex = header.indexWhere(
      (h) => h.toLowerCase() == '@timestamp' || h.toLowerCase() == 'timestamp',
    );
    int requestBodyIndex = header.indexWhere(
      (h) => h.toLowerCase() == 'request_body',
    );

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

      if (row.length <= math.max(timestampIndex, requestBodyIndex)) {
        continue;
      }

      final timestampRaw = row[timestampIndex]?.toString() ?? '';
      final requestBodyRaw = row[requestBodyIndex]?.toString() ?? '';

      if (requestBodyRaw.isEmpty) continue;

      try {
        // chuẩn hoá double-quote
        final normalizedJson = requestBodyRaw.replaceAll('""', '"');
        final decoded = jsonDecode(normalizedJson);

        if (decoded is! Map<String, dynamic>) continue;
        final logsList = decoded['logs'];
        if (logsList is! List) continue;

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

          logs.add({
            'createdAt': timestampRaw,
            'typeData': typeData,
            'message': message,
            'genTime': genTime,
          });
        }
      } catch (_) {
        // ignore 1 row lỗi
        continue;
      }
    }

    return {'error': null, 'logs': logs};
  } catch (e) {
    return {'error': 'Lỗi parse CSV: $e', 'logs': <Map<String, dynamic>>[]};
  }
}

// ================== APP ==================

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Coffee-ish color scheme
    const seed = Color(0xFF6F4E37); // coffee brown
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'Heartbeat Device Log Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: colorScheme.surfaceContainerHighest.withAlpha(
          40,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: colorScheme.primaryContainer,
          foregroundColor: colorScheme.onPrimaryContainer,
          elevation: 4,
          shadowColor: Colors.black26,
          centerTitle: true,
          surfaceTintColor: Colors.transparent,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
          ),
        ),
      ),
      home: const LogPage(),
    );
  }
}

// ================== PAGE ==================

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  // toàn bộ logs sau khi parse CSV
  List<HeartbeatLogEntry> _allLogs = [];

  // logs sau filter + sort
  List<HeartbeatLogEntry> _filteredLogs = [];

  String _searchText = '';
  final TextEditingController _searchController = TextEditingController();
  String? _error;
  String? _loadedFileName;

  bool _sortAscending = true; // sort theo genTime

  // pagination
  int _rowsPerPage = 50;
  int _currentPage = 0; // 0-based
  final List<int> _pageSizeOptions = [20, 50, 100, 200];

  // loading state
  bool _isFileLoading = false; // khi import CSV
  bool _isTableLoading = false; // khi filter/sort/paging/search

  // filter theo gen_time
  DateTime? _fromGenDateTime;
  DateTime? _toGenDateTime;

  // debounce search
  Timer? _searchDebounce;

  // controller cho Scrollbar + ListView
  final ScrollController _tableScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchDebounce?.cancel();
    _tableScrollController.dispose();
    super.dispose();
  }

  // ================== SEARCH ==================

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    final text = _searchController.text;

    setState(() {
      _searchText = text;
      _isTableLoading = true;
    });

    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _rebuildFilteredLogs();
    });
  }

  Future<void> _withTableLoading(Future<void> Function() action) async {
    setState(() {
      _isTableLoading = true;
    });
    try {
      await action();
    } finally {
      if (!mounted) return;
      setState(() {
        _isTableLoading = false;
      });
    }
  }

  // ================== IMPORT CSV (compute) ==================

  Future<void> _pickAndLoadFile() async {
    setState(() {
      _error = null;
      _loadedFileName = null;
      _allLogs = [];
      _filteredLogs = [];
      _currentPage = 0;
      _fromGenDateTime = null;
      _toGenDateTime = null;
      _isFileLoading = true;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        setState(() {
          _error = 'Không đọc được nội dung file (bytes null).';
        });
        return;
      }

      final content = utf8.decode(bytes);

      // Parse CSV ở Isolate
      final parsed = await compute(parseCsvInIsolate, content);

      final String? error = parsed['error'] as String?;
      final List<dynamic> rawLogsDynamic = parsed['logs'] as List<dynamic>;

      final logs = rawLogsDynamic
          .cast<Map<String, dynamic>>()
          .map(
            (m) => HeartbeatLogEntry(
              createdAt: m['createdAt'] as String,
              typeData: m['typeData'] as int,
              message: m['message'] as String,
              genTime: m['genTime'] as int,
            ),
          )
          .toList();

      setState(() {
        _error = error;
        _allLogs = logs;
        _loadedFileName = file.name;
        _currentPage = 0;
      });

      _rebuildFilteredLogs();
    } catch (e) {
      setState(() {
        _error = 'Lỗi khi đọc file: $e';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isFileLoading = false;
      });
    }
  }

  // ================== EXPORT PDF (filtered logs) ==================

  Future<void> _exportFilteredToPdf() async {
    if (_filteredLogs.isEmpty) {
      setState(() {
        _error = 'Không có dữ liệu để export PDF.';
      });
      return;
    }

    // Font Unicode – giữ được ký tự →, tiếng Việt,...
    final baseFont = await PdfGoogleFonts.notoSansRegular();
    final boldFont = await PdfGoogleFonts.notoSansBold();

    final doc = pw.Document();

    final now = DateTime.now();
    final title = 'Heartbeat Device Logs';
    final subtitle =
        'Export at ${DateFormat('yyyy-MM-dd HH:mm:ss').format(now)}';
    final total = _filteredLogs.length;

    // Chuẩn bị headers và data cho TableHelper
    final headers = ['created_at', 'gen_time', 'message'];
    final data = _filteredLogs.map((log) {
      return [log.createdAt, log.genTimeFormatted, log.message];
    }).toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),

        // Dùng font Unicode
        theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),

        // Header lặp lại mỗi trang
        header: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                title,
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                subtitle,
                style: const pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.grey700,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                'Total: $total record(s)',
                style: const pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.grey700,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Divider(thickness: 0.5),
              pw.SizedBox(height: 4),
            ],
          );
        },

        footer: (context) {
          return pw.Container(
            alignment: pw.Alignment.centerRight,
            margin: const pw.EdgeInsets.only(top: 8),
            child: pw.Text(
              'Page ${context.pageNumber} / ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
          );
        },

        build: (context) {
          return [
            pw.TableHelper.fromTextArray(
              headers: headers,
              data: data,
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 9,
              ),
              cellStyle: const pw.TextStyle(fontSize: 8),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey300,
              ),
              headerAlignment: pw.Alignment.centerLeft,
              cellAlignment: pw.Alignment.topLeft,
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 3,
                vertical: 2,
              ),
              // message rộng hơn
              columnWidths: const {
                0: pw.FlexColumnWidth(2), // created_at
                1: pw.FlexColumnWidth(2), // gen_time
                2: pw.FlexColumnWidth(6), // message
              },
            ),
          ];
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (format) async => doc.save());
  }

  // ================== FILTER + SORT ==================

  void _rebuildFilteredLogs() {
    final fromEpoch = _fromGenDateTime == null
        ? null
        : _fromGenDateTime!.toUtc().millisecondsSinceEpoch ~/ 1000;
    final toEpoch = _toGenDateTime == null
        ? null
        : _toGenDateTime!.toUtc().millisecondsSinceEpoch ~/ 1000;

    final searchLower = _searchText.toLowerCase();

    List<HeartbeatLogEntry> tmp = _allLogs.where((log) {
      if (searchLower.isNotEmpty &&
          !log.message.toLowerCase().contains(searchLower)) {
        return false;
      }

      if (fromEpoch != null && log.genTime < fromEpoch) return false;
      if (toEpoch != null && log.genTime > toEpoch) return false;

      return true;
    }).toList();

    tmp.sort((a, b) {
      final cmp = a.genTime.compareTo(b.genTime);
      return _sortAscending ? cmp : -cmp;
    });

    setState(() {
      _filteredLogs = tmp;
      _currentPage = 0;
      _isTableLoading = false;
    });

    if (_tableScrollController.hasClients) {
      _tableScrollController.jumpTo(0);
    }
  }

  // ================== DATE RANGE PICKER ==================

  Future<void> _pickFromGenDateTime() async {
    if (_isFileLoading || _isTableLoading) return;

    final now = DateTime.now();
    final initial =
        _fromGenDateTime ??
        (_allLogs.isNotEmpty ? _allLogs.first.genTimeDateTime : now);

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    DateTime result;
    if (pickedTime != null) {
      result = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    } else {
      result = DateTime(pickedDate.year, pickedDate.month, pickedDate.day);
    }

    await _withTableLoading(() async {
      _fromGenDateTime = result;
      _rebuildFilteredLogs();
    });
  }

  Future<void> _pickToGenDateTime() async {
    if (_isFileLoading || _isTableLoading) return;

    final now = DateTime.now();
    final initial =
        _toGenDateTime ??
        (_allLogs.isNotEmpty ? _allLogs.last.genTimeDateTime : now);

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );

    DateTime result;
    if (pickedTime != null) {
      result = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    } else {
      result = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        23,
        59,
      );
    }

    await _withTableLoading(() async {
      _toGenDateTime = result;
      _rebuildFilteredLogs();
    });
  }

  // ================== PAGING + SORT ==================

  Future<void> _changePage(int newPage) async {
    await _withTableLoading(() async {
      setState(() {
        _currentPage = newPage;
      });
      if (_tableScrollController.hasClients) {
        _tableScrollController.jumpTo(0);
      }
      await Future.delayed(const Duration(milliseconds: 80));
    });
  }

  Future<void> _changeRowsPerPage(int newSize) async {
    await _withTableLoading(() async {
      setState(() {
        _rowsPerPage = newSize;
        _currentPage = 0;
      });
      if (_tableScrollController.hasClients) {
        _tableScrollController.jumpTo(0);
      }
      await Future.delayed(const Duration(milliseconds: 80));
    });
  }

  Future<void> _toggleSort() async {
    await _withTableLoading(() async {
      _sortAscending = !_sortAscending;
      _rebuildFilteredLogs();
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = _filteredLogs.length;
    final pageCount = total == 0 ? 1 : (total / _rowsPerPage).ceil();
    final currentPage = total == 0 ? 0 : _currentPage.clamp(0, pageCount - 1);

    final int startIndex;
    final int endIndex;
    List<HeartbeatLogEntry> pageLogs;

    if (total == 0) {
      startIndex = 0;
      endIndex = 0;
      pageLogs = <HeartbeatLogEntry>[];
    } else {
      startIndex = currentPage * _rowsPerPage;
      endIndex = math.min(startIndex + _rowsPerPage, total);
      pageLogs = _filteredLogs.sublist(startIndex, endIndex);
    }

    final dateTimeLabel = DateFormat('dd/MM/yyyy HH:mm');
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Heartbeat Device Log Viewer')),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // top controls
                Row(
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                      ),
                      onPressed: _isFileLoading || _isTableLoading
                          ? null
                          : _pickAndLoadFile,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Chọn file CSV'),
                    ),
                    const SizedBox(width: 8),
                    // Export PDF button
                    FilledButton.tonalIcon(
                      onPressed:
                          (_isFileLoading ||
                              _isTableLoading ||
                              _filteredLogs.isEmpty)
                          ? null
                          : _exportFilteredToPdf,
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('Export PDF'),
                    ),
                    const SizedBox(width: 12),
                    if (_loadedFileName != null)
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surface,
                              borderRadius: BorderRadius.circular(999),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.coffee,
                                  size: 18,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    '$_loadedFileName • ${_allLogs.length} log(s)',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontStyle: FontStyle.italic,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 12),

                // search
                TextField(
                  controller: _searchController,
                  enabled: !_isFileLoading,
                  decoration: InputDecoration(
                    labelText: 'Search theo message',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: scheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: scheme.outlineVariant),
                    ),
                    suffixIcon: _searchText.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                            },
                          )
                        : null,
                  ),
                ),

                const SizedBox(height: 8),

                // date range
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isFileLoading ? null : _pickFromGenDateTime,
                        icon: const Icon(Icons.calendar_today),
                        label: Text(
                          _fromGenDateTime == null
                              ? 'From gen_time'
                              : 'From: ${dateTimeLabel.format(_fromGenDateTime!)}',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.primary,
                          side: BorderSide(color: scheme.outlineVariant),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isFileLoading ? null : _pickToGenDateTime,
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(
                          _toGenDateTime == null
                              ? 'To gen_time'
                              : 'To: ${dateTimeLabel.format(_toGenDateTime!)}',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.primary,
                          side: BorderSide(color: scheme.outlineVariant),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Xoá filter thời gian',
                      onPressed:
                          (_fromGenDateTime == null &&
                                  _toGenDateTime == null) ||
                              _isFileLoading
                          ? null
                          : () {
                              _withTableLoading(() async {
                                _fromGenDateTime = null;
                                _toGenDateTime = null;
                                _rebuildFilteredLogs();
                              });
                            },
                      icon: const Icon(Icons.clear),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                // loading bar cho table
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _isTableLoading
                      ? const LinearProgressIndicator(key: ValueKey('loading'))
                      : const SizedBox(key: ValueKey('no_loading'), height: 4),
                ),

                const SizedBox(height: 8),

                if (_error != null)
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 8),

                // table
                Expanded(
                  child: _buildPagedTable(
                    theme: theme,
                    pageLogs: pageLogs,
                    total: total,
                    pageCount: pageCount,
                    currentPage: currentPage,
                    startIndex: startIndex,
                    endIndex: endIndex,
                  ),
                ),
              ],
            ),
          ),

          // overlay khi đang import file
          if (_isFileLoading)
            Positioned.fill(
              child: Container(
                color: Colors.black.withAlpha(8),
                child: Center(
                  child: Card(
                    elevation: 8,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 18,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(width: 16),
                          Text('Đang tải CSV...'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ================== TABLE: Header cố định + body scroll ==================

  Widget _buildPagedTable({
    required ThemeData theme,
    required List<HeartbeatLogEntry> pageLogs,
    required int total,
    required int pageCount,
    required int currentPage,
    required int startIndex,
    required int endIndex,
  }) {
    if (total == 0) {
      return const Center(
        child: Text('Không có dữ liệu (hoặc chưa chọn file).'),
      );
    }

    final cellStyle = theme.textTheme.bodyMedium;
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Card(
            color: scheme.surface,
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ===== HEADER CỐ ĐỊNH TRONG CARD =====
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      border: Border(
                        bottom: BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: 2,
                          child: Text(
                            'created_at',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: InkWell(
                            onTap: _isFileLoading ? null : _toggleSort,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'gen_time',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: scheme.onPrimary,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  _sortAscending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  size: 16,
                                  color: scheme.onPrimary,
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 12,
                          child: Text(
                            'message',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: scheme.onPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ===== BODY SCROLL =====
                  Expanded(
                    child: SelectionArea(
                      child: Scrollbar(
                        controller: _tableScrollController,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _tableScrollController,
                          itemCount: pageLogs.length,
                          itemBuilder: (context, index) {
                            final log = pageLogs[index];
                            final globalIndex = startIndex + index;
                            final isEven = globalIndex.isEven;

                            final rowColor = isEven
                                ? scheme.surface
                                : scheme.primaryContainer.withAlpha(80);

                            return Container(
                              color: rowColor,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // created_at
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      log.createdAt,
                                      style: cellStyle,
                                    ),
                                  ),
                                  // gen_time
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      log.genTimeFormatted,
                                      style: cellStyle,
                                    ),
                                  ),
                                  // message – full text, SelectionArea
                                  Expanded(
                                    flex: 12,
                                    child: Text(log.message, style: cellStyle),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 8),

        // ===== PAGINATION BAR =====
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  'Trang ${currentPage + 1} / $pageCount · '
                  'Hiển thị ${startIndex + 1}–$endIndex / $total',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 16),
                Text('Rows/page:', style: theme.textTheme.bodySmall),
                const SizedBox(width: 4),
                DropdownButton<int>(
                  value: _rowsPerPage,
                  borderRadius: BorderRadius.circular(16),
                  focusColor: scheme.primaryContainer,
                  items: _pageSizeOptions
                      .map(
                        (v) =>
                            DropdownMenuItem<int>(value: v, child: Text('$v')),
                      )
                      .toList(),
                  onChanged: _isFileLoading
                      ? null
                      : (value) {
                          if (value == null || value == _rowsPerPage) return;
                          _changeRowsPerPage(value);
                        },
                ),
              ],
            ),
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _isFileLoading || currentPage <= 0
                      ? null
                      : () => _changePage(currentPage - 1),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Trang trước',
                ),
                const SizedBox(width: 4),
                Text('${currentPage + 1}', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  onPressed: _isFileLoading || currentPage >= pageCount - 1
                      ? null
                      : () => _changePage(currentPage + 1),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Trang sau',
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
