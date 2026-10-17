import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import 'camera_error_view.dart';
import 'hid_client.dart';
import 'hid_page.dart';
import 'relay_client.dart';
import 'scan_page.dart';
import 'widgets/scan_frame.dart';

/// 配对页：点按钮启动相机扫描二维码，或手动输入地址。
class PairPage extends StatefulWidget {
  const PairPage({super.key});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  /// null = 尚未请求过权限；相机组件只在授权成功且用户点按钮后才挂载
  PermissionStatus? _permission;
  bool _cameraActive = false;
  bool _handling = false;
  bool? _hidSupported; // null = 尚未检查完
  final _manualController = TextEditingController();
  late final MobileScannerController _camera = MobileScannerController();

  @override
  void initState() {
    super.initState();
    // 权限在用户点「开始扫描」时才按需请求（_permission 由 _startCamera 维护）
    HidClient.isSupported().then((ok) {
      if (mounted) setState(() => _hidSupported = ok);
    });
  }

  /// 用户点「开始扫描」：按需请求权限，成功后启动相机
  Future<void> _startCamera() async {
    setState(() => _permission = null);
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _permission = status;
      if (status.isGranted) _cameraActive = true;
    });
  }

  void _stopCamera() {
    setState(() => _cameraActive = false);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handling) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    final wsUri = wsUriFromPairUrl(raw);
    if (wsUri == null) return; // 不是配对码，继续扫
    _handling = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ScanPage(wsUri: wsUri)),
    );
  }

  void _manualConnect() {
    final text = _manualController.text.trim();
    if (text.isEmpty) return;
    final wsUri = wsUriFromPairUrl(text) ??
        Uri.tryParse(text.replaceAll(RegExp(r'^http'), 'ws'));
    if (wsUri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址格式不正确')),
      );
      return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ScanPage(wsUri: wsUri)),
    );
  }

  // ---------------------------------------------------------------- 布局

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3F51B5), Color(0xFF5C6BC0)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.qr_code_scanner,
                color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Scan-Relay',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('扫码配对 · 数据实时写入 Excel',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.white70)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLanding() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.qr_code_scanner,
                  size: 48,
                  color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 18),
            Text('扫描电脑上的配对二维码',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('点下方按钮才会打开相机\n（二维码在 Excel 任务窗格里）',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey.shade600)),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _startCamera,
              icon: const Icon(Icons.photo_camera),
              label: const Text('开始扫描配对码'),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _hidSupported == true
                  ? () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const HidPairPage()),
                      )
                  : null,
              icon: const Icon(Icons.bluetooth),
              label: const Text('蓝牙键盘模式（无需网络）'),
            ),
            if (_hidSupported == false) ...[
              const SizedBox(height: 8),
              Text(
                '蓝牙键盘模式需要 Android 9+ 的安卓手机',
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

  Widget _buildCameraArea() {
    final permission = _permission;
    if (permission == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!permission.isGranted) {
      final permanently = permission.isPermanentlyDenied;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(permanently ? '相机权限已被永久拒绝' : '需要相机权限才能扫码配对'),
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                      onPressed: _startCamera, child: const Text('重试授权')),
                  const SizedBox(width: 12),
                  FilledButton(
                      onPressed: openAppSettings, child: const Text('打开系统设置')),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: MobileScanner(
            controller: _camera,
            onDetect: _onDetect,
            errorBuilder: (context, error) =>
                CameraErrorView(exception: error, onRetry: _startCamera),
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
              child: const Text('对准 Excel 任务窗格中的配对二维码',
                  style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            child: IconButton(
              onPressed: _stopCamera,
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: '停止扫描',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildManualCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('连不上？手动输入地址',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: Colors.grey.shade700)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualController,
                    decoration: const InputDecoration(
                      hintText: 'http://192.168.x.x:8765/scan?token=...',
                      isDense: true,
                    ),
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _manualConnect(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _manualConnect,
                  icon: const Icon(Icons.login),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('地址看电脑窗格：无 WiFi 时用 USB 网络共享地址',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey.shade500)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _manualController.dispose();
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _cameraActive ? _buildCameraArea() : _buildLanding(),
            ),
            _buildManualCard(),
          ],
        ),
      ),
    );
  }
}
