import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'camera_error_view.dart';
import 'hid_client.dart';
import 'pair_page.dart';
import 'relay_client.dart';
import 'widgets/scan_frame.dart';

class FormFieldDef {
  FormFieldDef(this.name, this.column);
  final String name;
  final String column;
}

/// 配对后的主页面：连续扫码模式 / 表单采集模式。
/// 相机默认关闭，点「开始扫描」才启动（省电、防误扫）。
class ScanPage extends StatefulWidget {
  const ScanPage({super.key, this.wsUri, this.hidMode = false})
      : assert(wsUri != null || hidMode);

  /// 网络模式（扫码配对）的中继地址；hidMode 时为 null
  final Uri? wsUri;

  /// 蓝牙 HID 键盘模式：不联网，扫码结果以键盘输入直接敲进电脑
  final bool hidMode;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> with WidgetsBindingObserver {
  final _client = RelayClient();
  late final MobileScannerController _camera = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    detectionTimeoutMs: 400,
  );
  final _manualController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  List<FormFieldDef>? _formFields;
  final Map<String, TextEditingController> _formInputs = {};

  bool _connected = false;
  bool _scanning = false;
  bool _torchOn = false;
  int _sentCount = 0;
  String _lastValue = '';
  DateTime? _lastTime;

  /// 蓝牙 HID 模式：电脑是否已连上
  bool _hidActive = false;
  Timer? _hidPoll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.hidMode) {
      _startHidPoll();
    } else {
      _client.onDisconnected = _scheduleReconnect;
      _sub = _client.messages.listen(_onMessage);
      _connect();
    }
  }

  void _startHidPoll() {
    _hidPoll = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      HidClient.isActive().then((ok) {
        if (mounted && ok != _hidActive) setState(() => _hidActive = ok);
      });
    });
    HidClient.isActive().then((ok) {
      if (mounted && ok != _hidActive) setState(() => _hidActive = ok);
    });
  }

  Future<void> _connect() async {
    setState(() => _connected = false);
    final ok = await _client.connect(widget.wsUri!);
    if (!mounted) return;
    setState(() {
      _connected = ok;
      _reconnectAttempts = 0;
    });
    if (!ok) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    setState(() => _connected = false);
    _reconnectTimer?.cancel();
    _reconnectAttempts = (_reconnectAttempts + 1).clamp(0, 6);
    final delay = Duration(seconds: (1 << _reconnectAttempts).clamp(1, 30));
    _reconnectTimer = Timer(delay, _connect);
  }

  void _onMessage(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'form_config':
        final fields = (msg['fields'] as List<dynamic>? ?? [])
            .map((f) => FormFieldDef(
                  (f['name'] ?? '').toString(),
                  (f['column'] ?? '').toString(),
                ))
            .where((f) => f.name.isNotEmpty)
            .toList();
        setState(() {
          _formFields = fields.isEmpty ? null : fields;
          _scanning = false; // 表单模式不需要相机
          _formInputs
            ..clear()
            ..addAll({
              for (final f in fields) f.name: TextEditingController(),
            });
        });
      case 'clear_config':
        setState(() {
          _formFields = null;
          _formInputs.clear();
          _scanning = false;
        });
    }
  }

  Future<void> _sendScan(String value) async {
    if (value.isEmpty) return;
    final now = DateTime.now();
    if (value == _lastValue &&
        _lastTime != null &&
        now.difference(_lastTime!) < const Duration(milliseconds: 1200)) {
      return; // 相同值 1.2 秒内去重
    }
    _lastValue = value;
    _lastTime = now;
    if (widget.hidMode) {
      // HID 键盘协议只能发送按键，中文等字符无对应键码 —— 只发送可打印 ASCII 部分
      final ascii = String.fromCharCodes(
          value.codeUnits.where((c) => c >= 0x20 && c <= 0x7E));
      if (ascii.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('本条不含数字/字母/符号，蓝牙键盘模式无法输入，已跳过；中文请改用网络模式'),
          ),
        );
        return;
      }
      if (ascii.length != value.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已忽略中文等无法输入的字符，只发送了数字/字母部分')),
        );
      }
      final ok = await HidClient.typeText(ascii);
      if (!mounted) return;
      if (ok) {
        setState(() => _sentCount++);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(HidClient.lastError.isNotEmpty
                ? HidClient.lastError
                : '发送失败：电脑未连接'),
          ),
        );
      }
      return;
    }
    _client.send({'type': 'scan', 'value': value, 'symbology': 'camera', 'ts': now.millisecondsSinceEpoch});
    setState(() => _sentCount++);
  }

  void _onDetect(BarcodeCapture capture) {
    if (!_scanning || _formFields != null) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw != null) _sendScan(raw);
  }

  void _submitForm() {
    final fields = _formFields;
    if (fields == null) return;
    final data = <String, String>{};
    for (final f in fields) {
      final v = _formInputs[f.name]?.text.trim() ?? '';
      if (v.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请填写「${f.name}」')),
        );
        return;
      }
      data[f.name] = v;
    }
    _client.send({
      'type': 'form_submit',
      'fields': data,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    for (final c in _formInputs.values) {
      c.clear();
    }
    setState(() => _sentCount++);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已提交 ✓'), duration: Duration(seconds: 1)),
    );
  }

  void _toggleScan() {
    setState(() {
      _scanning = !_scanning;
      if (!_scanning) _torchOn = false;
    });
  }

  void _toggleTorch() {
    _camera.toggleTorch();
    setState(() => _torchOn = !_torchOn);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _scanning) {
      _camera.start().catchError((_) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hidPoll?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _client.dispose();
    _camera.dispose();
    _manualController.dispose();
    if (widget.hidMode) HidClient.stop();
    for (final c in _formInputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- 布局

  bool get _online => widget.hidMode ? _hidActive : _connected;

  Widget _chip(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE1E4EA)),
      ),
      child: child,
    );
  }

  Widget _buildChips() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Row(
        children: [
          _chip(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle,
                  size: 9, color: _online ? const Color(0xFF2DA44E) : const Color(0xFFD4A72C)),
              const SizedBox(width: 6),
              Text(
                  _online
                      ? '已连接'
                      : (widget.hidMode ? '电脑未连接' : '重连中…'),
                  style: const TextStyle(fontSize: 12)),
            ],
          )),
          const SizedBox(width: 8),
          _chip(Text('已发送 $_sentCount',
              style: TextStyle(fontSize: 12, color: scheme.primary))),
          if (_lastValue.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: _chip(Text(
                '最近 $_lastValue',
                style: const TextStyle(fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScannerArea() {
    if (!_scanning) {
      // 待机面板：相机未启动
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.photo_camera_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text('相机未启动', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '点「开始扫描」后才打开相机\n平时不占用摄像头，省电防误扫',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: MobileScanner(
            controller: _camera,
            onDetect: _onDetect,
            errorBuilder: (context, error) => CameraErrorView(
              exception: error,
              onRetry: () => _camera.start(),
            ),
          ),
        ),
        const Positioned.fill(child: ScanFrameOverlay()),
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text('扫描中 · 对准条码自动发送',
                  style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualController,
                    decoration: const InputDecoration(
                      hintText: '手动输入 / 扫码枪回车',
                      isDense: true,
                      prefixIcon: Icon(Icons.keyboard_alt_outlined, size: 20),
                    ),
                    onSubmitted: (v) {
                      _sendScan(v.trim());
                      _manualController.clear();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: () {
                    _sendScan(_manualController.text.trim());
                    _manualController.clear();
                  },
                  icon: const Icon(Icons.send),
                  tooltip: '发送',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _toggleScan,
                    style: _scanning
                        ? FilledButton.styleFrom(
                            backgroundColor: scheme.error,
                            foregroundColor: scheme.onError,
                          )
                        : null,
                    icon: Icon(
                        _scanning ? Icons.stop_circle_outlined : Icons.qr_code_scanner),
                    label: Text(_scanning ? '停止扫描' : '开始扫描'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: _scanning ? _toggleTorch : null,
                  icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
                  tooltip: '闪光灯',
                ),
              ],
            ),
            if (!_scanning) ...[
              const SizedBox(height: 8),
              Text(
                widget.hidMode
                    ? '数据以键盘方式敲进电脑，每条自动回车换行；保持本页在前台'
                    : '手动输入随时可用；相机只在扫描期间开启',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey.shade500),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildForm(List<FormFieldDef> fields) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.assignment_outlined,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('表单采集',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${fields.length} 个字段',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.grey.shade600)),
                ],
              ),
              const SizedBox(height: 14),
              for (final f in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextField(
                    controller: _formInputs[f.name],
                    decoration: InputDecoration(
                      labelText: f.name,
                      suffixText: '列 ${f.column}',
                      suffixStyle: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                      isDense: true,
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: _submitForm,
                icon: const Icon(Icons.playlist_add_check),
                label: const Text('提交本行'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final formFields = _formFields;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(widget.hidMode ? Icons.bluetooth : Icons.circle,
                size: widget.hidMode ? 18 : 12,
                color: _online ? const Color(0xFF2DA44E) : const Color(0xFFD4A72C)),
            const SizedBox(width: 6),
            Text(_online
                ? (widget.hidMode ? '蓝牙已连接' : '已连接')
                : (widget.hidMode ? '电脑未连接' : '重连中…')),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const PairPage()),
                (_) => false,
              );
            },
            icon: const Icon(Icons.logout),
            tooltip: '重新配对',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildChips(),
          Expanded(
            child: formFields == null
                ? _buildScannerArea()
                : _buildForm(formFields),
          ),
          if (formFields == null) _buildControls(),
        ],
      ),
    );
  }
}
