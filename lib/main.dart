import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:portal_log/heartbeat_log_entry.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Heartbeat Device Log Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const LogPage(),
    );
  }
}

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  List<HeartbeatLogEntry> _logs = [];
  String _searchText = '';
  final TextEditingController _searchController = TextEditingController();
  String? _error;
  String? _loadedFileName;

  bool _sortAscending = true; // sort theo genTime

  // Pagination
  int _rowsPerPage = 50;
  int _currentPage = 0; // 0-based
  final List<int> _pageSizeOptions = [20, 50, 100, 200];

  // Loading state
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchText = _searchController.text;
        _currentPage = 0; // reset page khi search
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _setLoadingForShortAction(Future<void> Function() action) async {
    setState(() {
      _isLoading = true;
    });
    try {
      await action();
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  // ========== Import JSON từ local (bytes) ==========

  Future<void> _pickAndLoadFile() async {
    setState(() {
      _error = null;
      _loadedFileName = null;
      _logs = [];
      _currentPage = 0;
      _isLoading = true;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true, // Web/desktop: dùng bytes
      );

      if (result == null || result.files.isEmpty) {
        // user cancel
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
      final decoded = jsonDecode(content);

      if (decoded is! List) {
        setState(() {
          _error = 'Format JSON không đúng (không phải List).';
        });
        return;
      }

      // Tìm object {type: "table", name: "heartbeat_device_log", data: [...]}
      Map<String, dynamic>? tableObj;
      for (final e in decoded) {
        if (e is Map<String, dynamic> &&
            e['type'] == 'table' &&
            e['name'] == 'heartbeat_device_log') {
          tableObj = e;
          break;
        }
      }

      if (tableObj == null || tableObj['data'] == null) {
        setState(() {
          _error = 'Không tìm thấy bảng heartbeat_device_log trong file.';
        });
        return;
      }

      final rawData = tableObj['data'];
      if (rawData is! List) {
        setState(() {
          _error = 'Trường data trong JSON không phải List.';
        });
        return;
      }

      final logs = <HeartbeatLogEntry>[];
      for (final item in rawData) {
        if (item is Map<String, dynamic>) {
          try {
            logs.add(HeartbeatLogEntry.fromJson(item));
          } catch (_) {
            // bỏ qua record lỗi
          }
        }
      }

      setState(() {
        _logs = logs;
        _loadedFileName = file.name;
        _currentPage = 0;
      });
    } catch (e) {
      setState(() {
        _error = 'Lỗi khi đọc file: $e';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  Widget _buildHighlightedMessage(String message, TextStyle? cellStyle) {
    final baseStyle = cellStyle ?? DefaultTextStyle.of(context).style;

    if (_searchText.isEmpty) {
      return SelectableText(message, style: baseStyle);
    }

    final lowerMessage = message.toLowerCase();
    final lowerQuery = _searchText.toLowerCase();

    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final index = lowerMessage.indexOf(lowerQuery, start);
      if (index < 0) {
        if (start < message.length) {
          spans.add(TextSpan(text: message.substring(start)));
        }
        break;
      }

      if (index > start) {
        spans.add(TextSpan(text: message.substring(start, index)));
      }

      spans.add(
        TextSpan(
          text: message.substring(index, index + _searchText.length),
          style: baseStyle.copyWith(backgroundColor: Colors.yellow),
        ),
      );

      start = index + _searchText.length;
    }

    return SelectableText.rich(TextSpan(style: baseStyle, children: spans));
  }

  @override
  Widget build(BuildContext context) {
    // Filter theo message
    final filteredLogs = _logs.where((log) {
      if (_searchText.isEmpty) return true;
      return log.message.toLowerCase().contains(_searchText.toLowerCase());
    }).toList();

    // Sort theo genTime
    filteredLogs.sort((a, b) {
      final cmp = a.genTime.compareTo(b.genTime);
      return _sortAscending ? cmp : -cmp;
    });

    final total = filteredLogs.length;

    // Paging
    final pageCount = total == 0 ? 1 : (total / _rowsPerPage).ceil();
    final currentPage = total == 0
        ? 0
        : _currentPage.clamp(0, pageCount - 1); // tránh out-of-range

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
      pageLogs = filteredLogs.sublist(startIndex, endIndex);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Heartbeat Device Log Viewer')),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top controls
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _pickAndLoadFile,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Chọn file JSON'),
                    ),
                    if (_loadedFileName != null)
                      Text(
                        'Đã load: $_loadedFileName (${_logs.length} dòng)',
                        style: const TextStyle(fontStyle: FontStyle.italic),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: 'Search theo message',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 8),

                // Table + pagination
                Expanded(
                  child: _buildPagedTable(
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

          // Loading overlay
          if (_isLoading)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.08),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _changePage(int newPage) async {
    await _setLoadingForShortAction(() async {
      setState(() {
        _currentPage = newPage;
      });
      await Future.delayed(const Duration(milliseconds: 150));
    });
  }

  Future<void> _changeRowsPerPage(int newSize) async {
    await _setLoadingForShortAction(() async {
      setState(() {
        _rowsPerPage = newSize;
        _currentPage = 0;
      });
      await Future.delayed(const Duration(milliseconds: 150));
    });
  }

  Future<void> _toggleSort() async {
    await _setLoadingForShortAction(() async {
      setState(() {
        _sortAscending = !_sortAscending;
        _currentPage = 0;
      });
      await Future.delayed(const Duration(milliseconds: 150));
    });
  }

  Widget _buildPagedTable({
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

    final theme = Theme.of(context);
    final cellStyle =
        theme.textTheme.bodyMedium; // style dùng chung cho các cell

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ========== CARD TABLE ==========
        Expanded(
          child: Card(
            elevation: 3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---- HEADER ----
                  Container(
                    color: theme.colorScheme.primary.withOpacity(0.08),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // ID
                        Expanded(
                          flex: 1,
                          child: Text(
                            'ID',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),

                        // created_at
                        Expanded(
                          flex: 2,
                          child: Text(
                            'created_at',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        // gen_time (sortable)
                        Expanded(
                          flex: 2,
                          child: InkWell(
                            onTap: _isLoading ? null : _toggleSort,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'gen_time',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  _sortAscending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  size: 16,
                                ),
                              ],
                            ),
                          ),
                        ),
                        // message
                        Expanded(
                          flex: 12,
                          child: Text(
                            'message',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // ---- ROWS ----
                  Expanded(
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: pageLogs.length,
                        itemBuilder: (context, index) {
                          final log = pageLogs[index];
                          final globalIndex = startIndex + index;
                          final isEven = globalIndex.isEven;

                          final rowColor = isEven
                              ? theme.colorScheme.surface
                              : theme.colorScheme.surfaceVariant.withOpacity(
                                  0.2,
                                );

                          return Container(
                            color: rowColor,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 1,
                                  child: SelectableText(
                                    log.id.toString(),
                                    style: cellStyle,
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: SelectableText(
                                    log.createdAt,
                                    style: cellStyle,
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: SelectableText(
                                    log.genTimeFormatted,
                                    style: cellStyle,
                                  ),
                                ),

                                Expanded(
                                  flex: 12,
                                  child: _buildHighlightedMessage(
                                    log.message,
                                    cellStyle,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 8),

        // ========== THANH PAGINATION + PAGE SIZE ==========
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Info + dropdown chọn page size
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
                  items: _pageSizeOptions
                      .map(
                        (v) =>
                            DropdownMenuItem<int>(value: v, child: Text('$v')),
                      )
                      .toList(),
                  onChanged: _isLoading
                      ? null
                      : (value) {
                          if (value == null || value == _rowsPerPage) return;
                          _changeRowsPerPage(value);
                        },
                ),
              ],
            ),

            // Nút Prev / Next
            Row(
              children: [
                IconButton(
                  onPressed: !_isLoading && currentPage > 0
                      ? () => _changePage(currentPage - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Trang trước',
                ),
                Text('${currentPage + 1}', style: theme.textTheme.bodyMedium),
                IconButton(
                  onPressed: !_isLoading && currentPage < pageCount - 1
                      ? () => _changePage(currentPage + 1)
                      : null,
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
