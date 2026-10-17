import 'dart:async';

import 'package:flutter/material.dart';

import 'hid_client.dart';
import 'scan_page.dart';

/// 蓝牙键盘模式配对页：引导完成「授权 → 启动服务 → 可被发现 → 电脑连接」。
/// 连接建立后进入扫描页（hidMode），扫码结果直接敲进电脑。
class HidPairPage extends StatefulWidget {
  const HidPairPage({super.key});

  @override
  State<HidPairPage> createState() => _HidPairPageState();
}

class _HidPairPageState extends State<HidPairPage> {
  bool? _supported; // null = 检查中
  bool _perms = false;
  bool _adapterOn = false;
  bool _started = false;
  bool _discoverable = false;
  bool _connected = false;
  bool _busy = false;
  String _deviceName = '';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final supported = await HidClient.isSupported();
    if (!mounted) return;
    setState(() => _supported = supported);
    if (!supported) return;
    await _refresh();
    final name = await HidClient.deviceName();
    final active = await HidClient.isActive();
    if (!mounted) return;
    setState(() {
      _deviceName = name;
      _connected = active;
    });
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      final ok = await HidClient.isActive();
      if (mounted && ok != _connected) setState(() => _connected = ok);
    });
  }

  Future<void> _refresh() async {
    final on = await HidClient.isEnabled();
    final perms = await HidClient.hasPermissions();
    final started = await HidClient.isStarted();
    if (!mounted) return;
    setState(() {
      _adapterOn = on;
      _perms = perms;
      _started = started;
    });
  }

  Future<void> _run(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    bool ok = false;
    try {
      ok = await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!ok && mounted && HidClient.lastError.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(HidClient.lastError)));
    }
    await _refresh();
    if (ok && !_discoverable && mounted) setState(() {});
  }

  Future<bool> _grantAndEnable() async {
    if (!await HidClient.ensurePermissions()) return false;
    return HidClient.enableBluetooth();
  }

  Future<bool> _startService() => HidClient.start();

  Future<bool> _makeDiscoverable() async {
    final ok = await HidClient.discoverable(seconds: 300);
    if (ok) setState(() => _discoverable = true);
    return ok;
  }

  void _enterScan() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage(hidMode: true)),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------- 布局

  Widget _step({
    required int index,
    required String title,
    required String desc,
    required bool done,
    bool actionable = true,
    VoidCallback? onPressed,
    String actionLabel = '去完成',
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? const Color(0xFF2DA44E) : scheme.primaryContainer,
            ),
            child: done
                ? const Icon(Icons.check, size: 16, color: Colors.white)
                : Text('$index',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                Text(desc,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey.shade600, height: 1.4)),
              ],
            ),
          ),
          if (!done && actionable)
            TextButton(
              onPressed: _busy ? null : onPressed,
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }

  Widget _statusCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.bluetooth,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('连接步骤',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_started)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (_connected
                              ? const Color(0xFF2DA44E)
                              : const Color(0xFFD4A72C))
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _connected ? '电脑已连接' : '等待电脑连接…',
                      style: TextStyle(
                          fontSize: 12,
                          color: _connected
                              ? const Color(0xFF2DA44E)
                              : const Color(0xFF9A7218)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _step(
              index: 1,
              title: '蓝牙权限与开关',
              desc: _perms && _adapterOn
                  ? '权限已授予，蓝牙已打开'
                  : '需要授予附近设备权限并打开蓝牙',
              done: _perms && _adapterOn,
              onPressed: () => _run(_grantAndEnable),
              actionLabel: '授权并开启',
            ),
            _step(
              index: 2,
              title: '启动键盘服务',
              desc: _started ? '已在手机上注册蓝牙键盘（HID）' : '注册后电脑才能把手机当键盘',
              done: _started,
              actionable: _perms && _adapterOn,
              onPressed: () => _run(_startService),
              actionLabel: '启动',
            ),
            _step(
              index: 3,
              title: '可被电脑发现（5 分钟）',
              desc: _connected
                  ? '已连接，无需再点'
                  : '点后在系统弹窗里确认"允许被发现"',
              done: _discoverable || _connected,
              actionable: _started,
              onPressed: () => _run(_makeDiscoverable),
              actionLabel: '开启可发现',
            ),
            _step(
              index: 4,
              title: '在电脑上完成配对',
              desc: _connected
                  ? '已连接 ✓ 下面点按钮进入扫描页'
                  : '按下方"电脑端操作"添加设备并确认配对',
              done: _connected,
              actionable: false,
            ),
            const SizedBox(height: 8),
            if (_connected)
              FilledButton.icon(
                onPressed: _enterScan,
                icon: const Icon(Icons.bluetooth_connected),
                label: const Text('进入扫描页'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _instructionsCard() {
    final name = _deviceName.isEmpty ? '（本机蓝牙名）' : _deviceName;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.computer,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('电脑端操作',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '1. 打开 设置 → 蓝牙和其他设备 → 添加设备 → 蓝牙\n'
              '2. 选择「$name」→ 双端确认配对\n'
              '3. 把 Excel 光标停在要写入的单元格\n'
              '4. 回手机进入扫描页，扫码即敲进 Excel',
              style: TextStyle(
                  fontSize: 13, height: 1.7, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .secondaryContainer
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '· 无需同一 WiFi，靠蓝牙直连；电脑不用装任何软件\n'
                    '· 每条数据敲完自动回车，Excel 光标自动移到下一行\n'
                    '· 请保持本页或扫描页在前台，退出即断开\n'
                    '· 表单采集模式需要网络配对，蓝牙模式仅连续扫码',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.7,
                        color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unsupportedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_disabled,
                size: 56, color: Colors.grey),
            const SizedBox(height: 14),
            Text('本机不支持蓝牙键盘模式',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '需要 Android 9.0 及以上、带蓝牙的安卓手机\niPhone 不支持该模式（可用扫码配对）',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supported = _supported;
    return Scaffold(
      appBar: AppBar(title: const Text('蓝牙键盘模式')),
      body: supported == null
          ? const Center(child: CircularProgressIndicator())
          : !supported
              ? _unsupportedView()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                  children: [
                    _statusCard(),
                    const SizedBox(height: 12),
                    _instructionsCard(),
                  ],
                ),
    );
  }
}
