import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const BarcodeLoggerApp());
}

class BarcodeLoggerApp extends StatelessWidget {
  const BarcodeLoggerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Barcode Logger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      home: const HomePage(),
    );
  }
}

class CodeRow {
  CodeRow({required this.code, this.note});

  final String code;
  final String? note;

  CodeRow copyWith({String? code, String? note}) {
    return CodeRow(code: code ?? this.code, note: note ?? this.note);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'code': code, 'note': note};
  }

  static CodeRow? fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final dynamic codeRaw = raw['code'];
    if (codeRaw is! String || codeRaw.trim().isEmpty) {
      return null;
    }
    final dynamic noteRaw = raw['note'];
    return CodeRow(code: codeRaw.trim(), note: noteRaw is String ? noteRaw : null);
  }
}

class CodeTable {
  CodeTable({
    required this.typeKey,
    required this.typeLabel,
    required this.rows,
    this.customName,
  });

  final String typeKey;
  final String typeLabel;
  final List<CodeRow> rows;
  final String? customName;

  CodeTable copyWith({String? customName}) {
    return CodeTable(
      typeKey: typeKey,
      typeLabel: typeLabel,
      rows: rows,
      customName: customName,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'typeKey': typeKey,
      'typeLabel': typeLabel,
      'customName': customName,
      'items': rows.map((CodeRow e) => e.toJson()).toList(),
    };
  }

  static CodeTable? fromJson(dynamic raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final dynamic keyRaw = raw['typeKey'];
    final dynamic labelRaw = raw['typeLabel'];
    final dynamic customNameRaw = raw['customName'];
    final dynamic itemsRaw = raw['items'];
    if (keyRaw is! String || keyRaw.trim().isEmpty) {
      return null;
    }
    if (labelRaw is! String || labelRaw.trim().isEmpty) {
      return null;
    }
    if (itemsRaw is! List) {
      return null;
    }

    final List<CodeRow> rows = <CodeRow>[];
    for (final dynamic entry in itemsRaw) {
      final CodeRow? row = CodeRow.fromJson(entry);
      if (row != null) {
        rows.add(row);
      }
    }

    return CodeTable(
      typeKey: keyRaw.trim(),
      typeLabel: labelRaw.trim(),
      customName: customNameRaw is String ? customNameRaw : null,
      rows: rows,
    );
  }
}

class SearchRowRef {
  SearchRowRef({
    required this.tableIndex,
    required this.rowIndex,
    required this.tableLabel,
    required this.code,
    required this.hasNote,
  });

  final int tableIndex;
  final int rowIndex;
  final String tableLabel;
  final String code;
  final bool hasNote;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _settingsReminderStep = 'reminder_step';
  static const String _settingsDecodeIntervalMs = 'decode_interval_ms';
  static const String _settingsHoldToScanEnabled = 'hold_to_scan_enabled';
  static const String _settingsHoldStopAfterOne = 'hold_stop_after_one';

  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 400,
  );
  final List<CodeTable> _tables = <CodeTable>[];

  int _sessionScanCount = 0;
  int _reminderStep = 10;
  int _decodeIntervalMs = 1200;
  bool _isLoading = true;
  bool _scanLocked = false;
  bool _manualScanEnabled = true;
  bool _isScannerRunning = true;
  bool _isDetectionActive = true;
  bool _holdToScanEnabled = true;
  bool _holdStopAfterOne = false;
  bool _holdPressed = false;
  bool _holdConsumedThisPress = false;
  String _distanceHint = '未检测到编码';
  double _qrSizeEma = 0;
  double _linearSizeEma = 0;
  String _pendingDistanceHint = '';
  int _pendingDistanceHintCount = 0;
  Timer? _distanceHintClearTimer;

  File? _storageFile;
  String? _lastScannedCode;
  DateTime _lastScannedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _bannerHideTimer;

  @override
  void initState() {
    super.initState();
    _scannerController.addListener(_onScannerControllerChanged);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _scannerController.removeListener(_onScannerControllerChanged);
    _bannerHideTimer?.cancel();
    _distanceHintClearTimer?.cancel();
    _scannerController.dispose();
    super.dispose();
  }

  void _onScannerControllerChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  bool get _isTorchOn => _scannerController.value.torchState == TorchState.on;

  Future<void> _initialize() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int savedReminder = prefs.getInt(_settingsReminderStep) ?? 10;
    final int savedDecodeInterval = prefs.getInt(_settingsDecodeIntervalMs) ?? 1200;
    final bool savedHoldToScanEnabled = prefs.getBool(_settingsHoldToScanEnabled) ?? true;
    final bool savedHoldStopAfterOne = prefs.getBool(_settingsHoldStopAfterOne) ?? false;

    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File('${dir.path}/scan_items.json');

    if (await file.exists()) {
      final String raw = await file.readAsString();
      final List<CodeTable> imported = _parseTables(raw);
      _tables
        ..clear()
        ..addAll(imported);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _reminderStep = savedReminder < 1 ? 10 : savedReminder;
      _decodeIntervalMs = savedDecodeInterval.clamp(1000, 2000);
      _holdToScanEnabled = savedHoldToScanEnabled;
      _holdStopAfterOne = savedHoldStopAfterOne;
      _storageFile = file;
      _isLoading = false;
    });

    await _syncScannerState(showMessage: false);
  }

  List<CodeTable> _parseTables(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return <CodeTable>[];
    }

    final List<CodeTable> out = <CodeTable>[];

    final dynamic tablesRaw = decoded['tables'];
    if (tablesRaw is List) {
      for (final dynamic entry in tablesRaw) {
        final CodeTable? table = CodeTable.fromJson(entry);
        if (table != null && table.rows.isNotEmpty) {
          out.add(table);
        }
      }
      return out;
    }

    final dynamic itemsRaw = decoded['items'];
    if (itemsRaw is List) {
      for (final dynamic entry in itemsRaw) {
        if (entry is! Map<String, dynamic>) {
          continue;
        }
        final String code = ((entry['code'] as String?) ?? '').trim();
        if (code.isEmpty) {
          continue;
        }
        final String? note = entry['note'] is String ? entry['note'] as String : null;
        int repeat = 1;
        final dynamic q = entry['quantity'];
        if (q is int && q > 1) {
          repeat = q;
        }
        for (int i = 0; i < repeat; i++) {
          _appendToTypedTable(out, CodeRow(code: code, note: note));
        }
      }
    }
    return out;
  }

  String _encodeJson() {
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'updatedAt': DateTime.now().toIso8601String(),
      'tables': _tables.map((CodeTable t) => t.toJson()).toList(),
    });
  }

  Future<void> _saveToDisk() async {
    final File? file = _storageFile;
    if (file == null) {
      return;
    }

    final String content = _encodeJson();
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showTopBanner(String message) {
    if (!mounted) {
      return;
    }

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: const Text('知道了'),
          ),
        ],
      ),
    );

    _bannerHideTimer?.cancel();
    _bannerHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
      }
    });
  }

  void _showSuccessHint(String code) {
    if (!mounted) {
      return;
    }
    final String shortCode = code.length > 24 ? '${code.substring(0, 24)}...' : code;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
        content: Row(
          children: <Widget>[
            const Icon(Icons.check_circle, color: Colors.lightGreenAccent),
            const SizedBox(width: 8),
            Expanded(child: Text('扫描成功：$shortCode')),
          ],
        ),
      ),
    );
  }

  Future<void> _setReminderStep(int value) async {
    final int normalized = value < 1 ? 1 : value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_settingsReminderStep, normalized);
    if (!mounted) {
      return;
    }

    setState(() {
      _reminderStep = normalized;
    });
  }

  Future<void> _setDecodeIntervalMs(int value) async {
    final int clamped = value.clamp(1000, 2000);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_settingsDecodeIntervalMs, clamped);
    if (!mounted) {
      return;
    }
    setState(() {
      _decodeIntervalMs = clamped;
    });
  }

  Future<void> _setHoldToScanEnabled(bool enabled) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_settingsHoldToScanEnabled, enabled);
    if (!mounted) {
      return;
    }

    setState(() {
      _holdToScanEnabled = enabled;
      _holdPressed = false;
      _holdConsumedThisPress = false;
      if (!enabled) {
        // Exiting hold-to-scan mode should resume continuous scanning.
        _manualScanEnabled = true;
      }
    });
    await _syncScannerState(showMessage: false);
  }

  Future<void> _setHoldStopAfterOne(bool enabled) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_settingsHoldStopAfterOne, enabled);
    if (!mounted) {
      return;
    }
    setState(() {
      _holdStopAfterOne = enabled;
      _holdConsumedThisPress = false;
    });
    await _syncScannerState(showMessage: false);
  }

  Future<void> _setScannerRunning(bool running, {bool showMessage = true}) async {
    if (!_isScannerRunning && !running) {
      return;
    }
    if (_isScannerRunning && running) {
      return;
    }

    try {
      if (running) {
        // Build the preview widget first, then start camera to avoid black preview after resume.
        if (mounted) {
          setState(() {
            _isScannerRunning = true;
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await _scannerController.start();
      } else {
        await _scannerController.stop();
        if (mounted) {
          setState(() {
            _isScannerRunning = false;
          });
        }
      }
    } catch (e) {
      if (running && mounted) {
        setState(() {
          _isScannerRunning = false;
        });
      }
      if (showMessage) {
        _showSnack('切换扫描状态失败: $e');
      }
    }
  }

  Future<void> _syncScannerState({bool showMessage = true}) async {
    final bool shouldRunCamera = _manualScanEnabled;
    final bool holdCanDetect = !_holdToScanEnabled || (_holdPressed && !_holdConsumedThisPress);
    final bool shouldDetect = _manualScanEnabled && holdCanDetect;
    await _setScannerRunning(shouldRunCamera, showMessage: showMessage);
    if (mounted) {
      setState(() {
        _isDetectionActive = shouldDetect;
      });
    }
  }

  Future<void> _toggleScanner() async {
    setState(() {
      _manualScanEnabled = !_manualScanEnabled;
      if (!_manualScanEnabled) {
        _holdPressed = false;
      }
    });
    await _syncScannerState();
  }

  Future<void> _toggleTorch() async {
    if (!_isScannerRunning) {
      _showSnack('相机未开启，无法切换闪光灯');
      return;
    }
    try {
      await _scannerController.toggleTorch();
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      _showSnack('切换闪光灯失败: $e');
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          return SettingsPage(
            reminderStep: _reminderStep,
            decodeIntervalMs: _decodeIntervalMs,
            holdToScanEnabled: _holdToScanEnabled,
            holdStopAfterOne: _holdStopAfterOne,
            onReminderStepChanged: _setReminderStep,
            onDecodeIntervalChanged: _setDecodeIntervalMs,
            onHoldToScanChanged: _setHoldToScanEnabled,
            onHoldStopAfterOneChanged: _setHoldStopAfterOne,
            onExportPressed: _exportExcelToChosenDirectory,
          );
        },
      ),
    );
  }

  Future<void> _onHoldScanStart() async {
    if (!_holdToScanEnabled || !_manualScanEnabled) {
      return;
    }
    setState(() {
      _holdPressed = true;
      _holdConsumedThisPress = false;
    });
    await _syncScannerState(showMessage: false);
  }

  Future<void> _onHoldScanEnd() async {
    if (!_holdToScanEnabled) {
      return;
    }
    setState(() {
      _holdPressed = false;
      _holdConsumedThisPress = false;
    });
    await _syncScannerState(showMessage: false);
  }

  Future<void> _handleDetectedCode(String code) async {
    final DateTime now = DateTime.now();
    final int effectiveDebounceMs = _holdPressed
        ? (_decodeIntervalMs ~/ 3).clamp(250, 700)
        : _decodeIntervalMs;
    if (_lastScannedCode == code &&
        now.difference(_lastScannedAt) < Duration(milliseconds: effectiveDebounceMs)) {
      return;
    }
    if (_scanLocked) {
      return;
    }

    _lastScannedCode = code;
    _lastScannedAt = now;
    _scanLocked = true;

    try {
      final bool duplicated = _tables.any(
        (CodeTable table) => table.rows.any((CodeRow row) => row.code == code),
      );
      if (duplicated) {
        final bool shouldAdd = await _showDuplicateDialog(code);
        if (!shouldAdd || !mounted) {
          return;
        }
      }

      int touchedTableIndex = -1;
      int touchedTableCount = 0;
      String touchedTableLabel = '';
      setState(() {
        touchedTableIndex = _appendToTypedTable(_tables, CodeRow(code: code, note: null));
        touchedTableCount = _tables[touchedTableIndex].rows.length;
        touchedTableLabel = _tables[touchedTableIndex].typeLabel;
        _sessionScanCount += 1;
      });
      await _saveToDisk();
      _showSuccessHint(code);

      if (_holdToScanEnabled && _holdPressed && _holdStopAfterOne) {
        setState(() {
          _holdConsumedThisPress = true;
        });
        await _syncScannerState(showMessage: false);
      }

      if (touchedTableCount > 0 && touchedTableCount % _reminderStep == 0) {
        final String msg =
            '${touchedTableIndex + 1}号表 $touchedTableLabel 已记录 $touchedTableCount 条，请核对是否漏扫。';
        _showTopBanner(msg);
        await _showReminderDialog(msg);
      }
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      _scanLocked = false;
    }
  }

  void _updateDistanceHint(Barcode barcode) {
    final Size s = barcode.size;
    if (s.isEmpty) {
      return;
    }

    final double major = math.max(s.width.abs(), s.height.abs());
    final bool isQr = barcode.format == BarcodeFormat.qrCode;
    final bool isLinear = _isLinearFormat(barcode.format);

    if (isQr) {
      _qrSizeEma = _qrSizeEma == 0 ? major : (_qrSizeEma * 0.85 + major * 0.15);
    } else if (isLinear) {
      _linearSizeEma = _linearSizeEma == 0 ? major : (_linearSizeEma * 0.85 + major * 0.15);
    }

    final double baseline = isQr
        ? (_qrSizeEma == 0 ? 0.30 : _qrSizeEma)
        : (_linearSizeEma == 0 ? 0.42 : _linearSizeEma);

    final double nearThreshold = isQr
        ? (baseline * 1.55).clamp(0.42, 0.88)
        : (baseline * 1.45).clamp(0.55, 0.93);
    final double farThreshold = isQr
        ? (baseline * 0.55).clamp(0.06, 0.30)
        : (baseline * 0.60).clamp(0.12, 0.45);

    String hint = '已识别，距离合适';
    if (major > nearThreshold) {
      hint = '已识别，建议后移';
    } else if (major < farThreshold) {
      hint = '已识别，建议靠近';
    }

    if (_pendingDistanceHint == hint) {
      _pendingDistanceHintCount += 1;
    } else {
      _pendingDistanceHint = hint;
      _pendingDistanceHintCount = 1;
    }

    if (!mounted || _pendingDistanceHintCount < 3 || hint == _distanceHint) {
      return;
    }
    setState(() {
      _distanceHint = hint;
    });
    _distanceHintClearTimer?.cancel();
    _distanceHintClearTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _distanceHint = '未检测到编码';
        _pendingDistanceHint = '';
        _pendingDistanceHintCount = 0;
      });
    });
  }

  bool _isLinearFormat(BarcodeFormat format) {
    return format == BarcodeFormat.code128 ||
        format == BarcodeFormat.code39 ||
        format == BarcodeFormat.code93 ||
        format == BarcodeFormat.codabar ||
        format == BarcodeFormat.ean8 ||
        format == BarcodeFormat.ean13 ||
        format == BarcodeFormat.itf2of5 ||
        format == BarcodeFormat.itf2of5WithChecksum ||
        format == BarcodeFormat.itf14 ||
        format == BarcodeFormat.upcA ||
        format == BarcodeFormat.upcE ||
        format == BarcodeFormat.pdf417;
  }

  Future<void> _showReminderDialog(String message) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('核对提醒'),
          content: Text(message),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('已核对'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _showDuplicateDialog(String code) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('检测到重复编码'),
          content: Text('编码 "$code" 已存在，是否仍然新增一行记录？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('忽略'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('继续新增'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<bool> _showYesNoDialog({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmText),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<bool> _confirmDeleteTwice(String code) async {
    final bool stepOne = await _showYesNoDialog(
      title: '确认删除',
      message: '确定删除编码 "$code" 这一行吗？',
      confirmText: '继续',
    );
    if (!stepOne) {
      return false;
    }
    return _showYesNoDialog(
      title: '二次确认',
      message: '删除后无法恢复，请再次确认删除。',
      confirmText: '确认删除',
    );
  }

  String _ymd(DateTime date) {
    final String y = date.year.toString().padLeft(4, '0');
    final String m = date.month.toString().padLeft(2, '0');
    final String d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _sanitizeFileName(String input) {
    final String cleaned = input.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'sheet' : cleaned;
  }

  String _defaultTableFileBase(int index, CodeTable table) {
    final String name = _tableDisplayName(index, table).trim();
    if (name.isEmpty) {
      return 'table_${index + 1}';
    }
    return name;
  }

  String _tableDisplayName(int index, CodeTable table) {
    final String n = (table.customName ?? '').trim();
    if (n.isNotEmpty) {
      return n;
    }
    return '表${index + 1}';
  }

  Future<void> _editTableName(int tableIndex) async {
    if (tableIndex < 0 || tableIndex >= _tables.length) {
      return;
    }
    final CodeTable table = _tables[tableIndex];
    final TextEditingController controller = TextEditingController(
      text: _tableDisplayName(tableIndex, table),
    );
    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('编辑表名'),
          content: TextField(
            controller: controller,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            decoration: const InputDecoration(hintText: '请输入表名'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (newName == null) {
      return;
    }
    final String cleaned = newName.trim();
    setState(() {
      _tables[tableIndex] = table.copyWith(customName: cleaned.isEmpty ? null : cleaned);
    });
    await _saveToDisk();
  }

  Future<void> _exportExcelToChosenDirectory() async {
    if (_tables.isEmpty) {
      _showSnack('暂无可导出数据');
      return;
    }

    final List<bool> selected = <bool>[
      for (int i = 0; i < _tables.length; i++) false,
    ];
    final List<TextEditingController> controllers = <TextEditingController>[
      for (int i = 0; i < _tables.length; i++)
        TextEditingController(text: _defaultTableFileBase(i, _tables[i])),
    ];

    try {
      final bool? shouldExport = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return StatefulBuilder(
            builder: (BuildContext context, void Function(void Function()) setDialogState) {
              return AlertDialog(
                title: const Text('导出 Excel'),
                content: SizedBox(
                  width: 560,
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _tables.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (BuildContext context, int i) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Checkbox(
                                value: selected[i],
                                onChanged: (bool? v) {
                                  setDialogState(() {
                                    selected[i] = v ?? false;
                                  });
                                },
                              ),
                              Expanded(child: Text('表 ${i + 1}: ${_tables[i].typeLabel}')),
                            ],
                          ),
                      TextField(
                        controller: controllers[i],
                        enabled: selected[i],
                        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                          labelText: '文件名（不含日期与扩展名）',
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('选择目录并导出'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (shouldExport != true) {
        return;
      }
      if (!selected.any((bool v) => v)) {
        _showSnack('请至少选择一个表');
        return;
      }

      final String? dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择导出目录',
      );
      if (dirPath == null || dirPath.isEmpty) {
        return;
      }

      final String datePart = _ymd(DateTime.now());
      int success = 0;
      final List<String> failed = <String>[];
      final CellStyle centeredStyle = CellStyle(
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
      );
      final CellStyle centeredYellowStyle = CellStyle(
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
        backgroundColorHex: ExcelColor.yellow100,
      );

      for (int i = 0; i < _tables.length; i++) {
        if (!selected[i]) {
          continue;
        }
        final CodeTable table = _tables[i];
        final String base = _sanitizeFileName(
          controllers[i].text.trim().isEmpty ? _defaultTableFileBase(i, table) : controllers[i].text,
        );
        final String fileName = '${base}_$datePart.xlsx';
        final String targetPath = '$dirPath${Platform.pathSeparator}$fileName';

        try {
          final Excel excel = Excel.createExcel();
          final String sheetName = 'Sheet1';
          final Sheet sheet = excel[sheetName];
          sheet.appendRow(<CellValue>[
            TextCellValue('数量行'),
            TextCellValue('编码'),
            TextCellValue('备注'),
          ]);
          for (int col = 0; col < 3; col++) {
            final Data cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0));
            cell.cellStyle = centeredStyle;
          }
          for (int rowIndex = 0; rowIndex < table.rows.length; rowIndex++) {
            final CodeRow row = table.rows[rowIndex];
            sheet.appendRow(<CellValue>[
              IntCellValue(rowIndex + 1),
              TextCellValue(row.code),
              TextCellValue((row.note ?? '').trim()),
            ]);
            final bool hasNote = (row.note ?? '').trim().isNotEmpty;
            final CellStyle style = hasNote ? centeredYellowStyle : centeredStyle;
            for (int col = 0; col < 3; col++) {
              final Data cell = sheet.cell(
                CellIndex.indexByColumnRow(columnIndex: col, rowIndex: rowIndex + 1),
              );
              cell.cellStyle = style;
            }
          }
          final List<int>? bytes = excel.encode();
          if (bytes == null) {
            throw Exception('excel encode failed');
          }
          await File(targetPath).writeAsBytes(bytes, flush: true);
          success += 1;
        } catch (_) {
          failed.add(fileName);
        }
      }

      final int selectedCount = selected.where((bool v) => v).length;
      if (success == selectedCount) {
        _showSnack('导出成功：$success 个 Excel 文件');
      } else {
        _showSnack('导出完成：成功 $success，失败 ${failed.length}');
      }
    } finally {
      for (final TextEditingController c in controllers) {
        c.dispose();
      }
    }
  }

  Future<void> _editNote(int tableIndex, int rowIndex) async {
    if (tableIndex < 0 ||
        tableIndex >= _tables.length ||
        rowIndex < 0 ||
        rowIndex >= _tables[tableIndex].rows.length) {
      return;
    }
    final CodeRow current = _tables[tableIndex].rows[rowIndex];
    final TextEditingController controller = TextEditingController(text: current.note ?? '');

    final String? newNote = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('编辑备注'),
          content: TextField(
            controller: controller,
            maxLines: 3,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            decoration: const InputDecoration(hintText: '备注可留空'),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('保存')),
          ],
        );
      },
    );

    if (newNote == null) {
      return;
    }

    final String trimmed = newNote.trim();
    setState(() {
      _tables[tableIndex].rows[rowIndex] = CodeRow(
        code: current.code,
        note: trimmed.isEmpty ? null : trimmed,
      );
    });
    await _saveToDisk();
  }

  Future<void> _deleteRow(int tableIndex, int rowIndex) async {
    if (tableIndex < 0 ||
        tableIndex >= _tables.length ||
        rowIndex < 0 ||
        rowIndex >= _tables[tableIndex].rows.length) {
      return;
    }
    final String code = _tables[tableIndex].rows[rowIndex].code;
    final bool ok = await _confirmDeleteTwice(code);
    if (!ok) {
      return;
    }

    setState(() {
      _tables[tableIndex].rows.removeAt(rowIndex);
      _removeEmptyTables();
    });
    await _saveToDisk();
  }

  List<SearchRowRef> _searchRows(String query) {
    final String q = query.trim().toLowerCase();
    final List<SearchRowRef> out = <SearchRowRef>[];
    for (int t = 0; t < _tables.length; t++) {
      final CodeTable table = _tables[t];
      for (int r = 0; r < table.rows.length; r++) {
        final CodeRow row = table.rows[r];
        final bool matched = q.isEmpty || row.code.toLowerCase().contains(q);
        if (!matched) {
          continue;
        }
        out.add(
          SearchRowRef(
            tableIndex: t,
            rowIndex: r,
            tableLabel: table.typeLabel,
            code: row.code,
            hasNote: (row.note ?? '').trim().isNotEmpty,
          ),
        );
      }
    }
    return out;
  }

  Future<void> _openSearchDialog() async {
    final TextEditingController controller = TextEditingController();
    List<SearchRowRef> results = _searchRows('');

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) setDialogState) {
            Future<void> refreshResults() async {
              setDialogState(() {
                results = _searchRows(controller.text);
              });
            }

            return AlertDialog(
              title: const Text('搜索编码'),
              content: SizedBox(
                width: 560,
                height: 420,
                child: Column(
                  children: <Widget>[
                    TextField(
                      controller: controller,
                      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                      decoration: const InputDecoration(
                        hintText: '输入关键字模糊搜索编码',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (String value) {
                        setDialogState(() {
                          results = _searchRows(value);
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: results.isEmpty
                          ? const Center(child: Text('没有匹配结果'))
                          : ListView.builder(
                              itemCount: results.length,
                              itemBuilder: (BuildContext context, int index) {
                                final SearchRowRef row = results[index];
                                return Container(
                                  color: row.hasNote ? Colors.yellow.shade100 : null,
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              row.code,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              row.tableLabel,
                                              style: Theme.of(context).textTheme.bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: () async {
                                          await _editNote(row.tableIndex, row.rowIndex);
                                          await refreshResults();
                                        },
                                        tooltip: row.hasNote ? '编辑备注' : '添加备注',
                                        icon: Icon(
                                          row.hasNote
                                              ? Icons.sticky_note_2_outlined
                                              : Icons.note_add_outlined,
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: () async {
                                          await _deleteRow(row.tableIndex, row.rowIndex);
                                          await refreshResults();
                                        },
                                        tooltip: '删除',
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  int _appendToTypedTable(List<CodeTable> tables, CodeRow row) {
    final (String key, String label) = _classifyCode(row.code);
    final int existing = tables.indexWhere((CodeTable t) => t.typeKey == key);
    if (existing >= 0) {
      tables[existing].rows.add(row);
      return existing;
    }
    tables.add(CodeTable(typeKey: key, typeLabel: label, rows: <CodeRow>[row]));
    return tables.length - 1;
  }

  void _removeEmptyTables() {
    _tables.removeWhere((CodeTable table) => table.rows.isEmpty);
  }

  (String, String) _classifyCode(String code) {
    final String normalized = code.trim();
    final StringBuffer signature = StringBuffer();
    for (int i = 0; i < normalized.length; i++) {
      final String ch = normalized[i];
      if (_isAsciiLetter(ch)) {
        signature.write('A');
      } else if (_isAsciiDigit(ch)) {
        signature.write('N');
      } else {
        signature.write('S');
      }
    }

    final String key = signature.toString();
    return (key, '结构 $key');
  }

  bool _isAsciiLetter(String ch) {
    final int u = ch.codeUnitAt(0);
    return (u >= 65 && u <= 90) || (u >= 97 && u <= 122);
  }

  bool _isAsciiDigit(String ch) {
    final int u = ch.codeUnitAt(0);
    return u >= 48 && u <= 57;
  }

  String _formatIntervalShort(int ms) {
    if (ms % 1000 == 0) {
      return '${ms ~/ 1000}秒';
    }
    return '${(ms / 1000).toStringAsFixed(1)}秒';
  }

  Widget _buildCameraPreview() {
    final int totalRows = _tables.fold<int>(0, (int sum, CodeTable t) => sum + t.rows.length);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double panelHeight = math.min(148, math.max(110, constraints.maxHeight * 0.15));
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: panelHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        if (_isScannerRunning)
                          MobileScanner(
                            controller: _scannerController,
                            onDetect: (BarcodeCapture capture) {
                              if (!_isDetectionActive) {
                                return;
                              }
                              for (final Barcode barcode in capture.barcodes) {
                                final String? raw = barcode.rawValue?.trim();
                                if (raw != null && raw.isNotEmpty) {
                                  _updateDistanceHint(barcode);
                                  unawaited(_handleDetectedCode(raw));
                                  break;
                                }
                              }
                            },
                          )
                        else
                          Container(color: Colors.black38),
                        if (!_isDetectionActive)
                          Container(
                            color: Colors.black26,
                            alignment: Alignment.center,
                            child: const Text(
                              '扫描已暂停',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        Positioned(
                          top: 6,
                          left: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _distanceHint,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: panelHeight,
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints infoConstraints) {
                          final double panelWidth = infoConstraints.maxWidth;
                          final double fs = (panelWidth / 18).clamp(12, 18).toDouble();
                          final double gap = (panelWidth / 34).clamp(6, 12).toDouble();
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Wrap(
                              spacing: gap,
                              runSpacing: 8,
                              children: <Widget>[
                                Text('已扫 $_sessionScanCount',
                                    style: TextStyle(fontSize: fs, fontWeight: FontWeight.w600)),
                                Text('总行数 $totalRows',
                                    style: TextStyle(fontSize: fs, fontWeight: FontWeight.w600)),
                                Text('表数 ${_tables.length}',
                                    style: TextStyle(fontSize: fs, fontWeight: FontWeight.w600)),
                                Text('步长 $_reminderStep', style: TextStyle(fontSize: fs - 1)),
                                Text('频率 ${_formatIntervalShort(_decodeIntervalMs)}',
                                    style: TextStyle(fontSize: fs - 1)),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _buildPerfLevelText() {
    double score = 0;
    if (_manualScanEnabled) {
      score += 0.35;
    }
    if (_isScannerRunning) {
      score += 0.25;
    }
    if (_isDetectionActive) {
      score += 0.25;
    }
    score += ((2000 - _decodeIntervalMs) / 1000) * 0.15;
    if (_isTorchOn) {
      score += 0.12;
    }
    if (score >= 0.75) {
      return '高';
    }
    if (score >= 0.45) {
      return '中';
    }
    return '低';
  }

  Future<void> _openPerformanceDialog() async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('性能消耗'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('预估负载：${_buildPerfLevelText()}'),
              Text('相机运行：${_isScannerRunning ? '是' : '否'}'),
              Text('解码启用：${_isDetectionActive ? '是' : '否'}'),
              Text('按住扫描：${_holdToScanEnabled ? '启用' : '关闭'}'),
              Text('解码频率：${_formatIntervalShort(_decodeIntervalMs)}'),
              Text('闪光灯：${_isTorchOn ? '开启' : '关闭'}'),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTableHeader() {
    return Container(
      color: Colors.black12,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: const Row(
        children: <Widget>[
          SizedBox(width: 56, child: Text('行')),
          Expanded(child: Text('编码')),
          SizedBox(width: 82, child: Text('操作')),
        ],
      ),
    );
  }

  Widget _buildTableRow(int tableIndex, int rowIndex, CodeRow row) {
    final String noteText = (row.note ?? '').trim();
    final bool hasNote = noteText.isNotEmpty;

    return Container(
      color: hasNote ? Colors.yellow.shade100 : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(width: 56, child: Text('${rowIndex + 1}')),
          Expanded(
            child: Text(
              row.code,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          SizedBox(
            width: 82,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                IconButton(
                  onPressed: () => _editNote(tableIndex, rowIndex),
                  tooltip: hasNote ? '编辑备注' : '添加备注',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(hasNote ? Icons.sticky_note_2_outlined : Icons.note_add_outlined),
                ),
                IconButton(
                  onPressed: () => _deleteRow(tableIndex, rowIndex),
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecords() {
    if (_tables.isEmpty) {
      return const Center(child: Text('暂无记录，扫描后会自动在下方生成分类表。'));
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 80),
      itemCount: _tables.length,
      itemBuilder: (BuildContext context, int tableIndex) {
        final CodeTable table = _tables[tableIndex];
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ExpansionTile(
            initiallyExpanded: true,
            title: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _tableDisplayName(tableIndex, table),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '编辑表名',
                  onPressed: () => _editTableName(tableIndex),
                  icon: const Icon(Icons.edit_note),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            subtitle: Text('${table.rows.length}行  键 ${table.typeKey}'),
            children: <Widget>[
              _buildTableHeader(),
              for (int rowIndex = 0; rowIndex < table.rows.length; rowIndex++)
                _buildTableRow(tableIndex, rowIndex, table.rows[rowIndex]),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHoldToScanFab() {
    if (!_holdToScanEnabled) {
      return const SizedBox.shrink();
    }

    final bool disabledByMainToggle = !_manualScanEnabled;
    final Color activeColor = Colors.orange;
    final Color idleColor = disabledByMainToggle ? Colors.grey : Colors.blue;

    return Listener(
      onPointerDown: (_) => unawaited(_onHoldScanStart()),
      onPointerUp: (_) => unawaited(_onHoldScanEnd()),
      onPointerCancel: (_) => unawaited(_onHoldScanEnd()),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(28),
        color: _holdPressed ? activeColor : idleColor,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                _holdPressed ? Icons.center_focus_strong : (disabledByMainToggle ? Icons.pause : Icons.touch_app),
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Text(
                _holdPressed ? '正在扫描' : (disabledByMainToggle ? '主开关暂停' : '按住扫描'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Barcode Logger'),
        actions: <Widget>[
          IconButton(
            onPressed: _toggleScanner,
            tooltip: _manualScanEnabled ? '暂停扫描' : '继续扫描',
            icon: Icon(_manualScanEnabled ? Icons.pause_circle_outline : Icons.play_circle_outline),
          ),
          IconButton(
            onPressed: _openPerformanceDialog,
            tooltip: '性能消耗',
            icon: const Icon(Icons.monitor_heart_outlined),
          ),
          IconButton(
            onPressed: _openSearchDialog,
            tooltip: '搜索编码',
            icon: const Icon(Icons.search),
          ),
          IconButton(
            onPressed: _toggleTorch,
            tooltip: _isTorchOn ? '关闭闪光灯' : '打开闪光灯',
            icon: Icon(_isTorchOn ? Icons.flash_on : Icons.flash_off),
          ),
          IconButton(onPressed: _openSettings, tooltip: '设置', icon: const Icon(Icons.settings)),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _buildHoldToScanFab(),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: <Widget>[
                    _buildCameraPreview(),
                    Expanded(child: _buildRecords()),
                  ],
                ),
              ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.reminderStep,
    required this.decodeIntervalMs,
    required this.holdToScanEnabled,
    required this.holdStopAfterOne,
    required this.onReminderStepChanged,
    required this.onDecodeIntervalChanged,
    required this.onHoldToScanChanged,
    required this.onHoldStopAfterOneChanged,
    required this.onExportPressed,
  });

  final int reminderStep;
  final int decodeIntervalMs;
  final bool holdToScanEnabled;
  final bool holdStopAfterOne;
  final Future<void> Function(int value) onReminderStepChanged;
  final Future<void> Function(int value) onDecodeIntervalChanged;
  final Future<void> Function(bool enabled) onHoldToScanChanged;
  final Future<void> Function(bool enabled) onHoldStopAfterOneChanged;
  final Future<void> Function() onExportPressed;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late int _reminderStep;
  late int _decodeIntervalMs;
  late bool _holdToScanEnabled;
  late bool _holdStopAfterOne;

  @override
  void initState() {
    super.initState();
    _reminderStep = widget.reminderStep;
    _decodeIntervalMs = widget.decodeIntervalMs;
    _holdToScanEnabled = widget.holdToScanEnabled;
    _holdStopAfterOne = widget.holdStopAfterOne;
  }

  Future<void> _changeReminderStep(int value) async {
    final int next = math.max(1, value);
    setState(() {
      _reminderStep = next;
    });
    await widget.onReminderStepChanged(next);
  }

  Future<void> _changeDecodeInterval(int value) async {
    final int next = value.clamp(1000, 2000);
    setState(() {
      _decodeIntervalMs = next;
    });
    await widget.onDecodeIntervalChanged(next);
  }

  Future<void> _changeHoldToScan(bool enabled) async {
    setState(() {
      _holdToScanEnabled = enabled;
    });
    await widget.onHoldToScanChanged(enabled);
  }

  Future<void> _changeHoldStopAfterOne(bool enabled) async {
    setState(() {
      _holdStopAfterOne = enabled;
    });
    await widget.onHoldStopAfterOneChanged(enabled);
  }

  String _formatIntervalShort(int ms) {
    if (ms % 1000 == 0) {
      return '${ms ~/ 1000}秒';
    }
    return '${(ms / 1000).toStringAsFixed(1)}秒';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('提醒步长', style: TextStyle(fontWeight: FontWeight.w600)),
                  Row(
                    children: <Widget>[
                      IconButton(
                        onPressed: () => unawaited(_changeReminderStep(_reminderStep - 1)),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$_reminderStep', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      IconButton(
                        onPressed: () => unawaited(_changeReminderStep(_reminderStep + 1)),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('解码频率 ${_formatIntervalShort(_decodeIntervalMs)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Slider(
                    value: _decodeIntervalMs.toDouble(),
                    min: 1000,
                    max: 2000,
                    divisions: 20,
                    label: _formatIntervalShort(_decodeIntervalMs),
                    onChanged: (double value) {
                      setState(() {
                        _decodeIntervalMs = value.round();
                      });
                    },
                    onChangeEnd: (double value) => unawaited(_changeDecodeInterval(value.round())),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用按住扫描'),
                    value: _holdToScanEnabled,
                    onChanged: (bool value) => unawaited(_changeHoldToScan(value)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('按住扫描命中一次后暂停'),
                    subtitle: const Text('命中一条后需抬起再按下继续扫描'),
                    value: _holdStopAfterOne,
                    onChanged: _holdToScanEnabled
                        ? (bool value) => unawaited(_changeHoldStopAfterOne(value))
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => unawaited(widget.onExportPressed()),
            icon: const Icon(Icons.upload_file),
            label: const Text('导出 Excel'),
          ),
        ],
      ),
    );
  }
}

