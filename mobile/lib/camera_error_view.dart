import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

/// 相机错误兜底视图：权限被拒时给「重试授权 / 打开系统设置」入口。
class CameraErrorView extends StatelessWidget {
  const CameraErrorView({super.key, required this.exception, required this.onRetry});

  final MobileScannerException exception;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final denied = exception.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(denied ? Icons.no_photography : Icons.error_outline,
                size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              denied ? '相机权限被拒绝，无法扫码' : '相机启动失败：${exception.errorCode.name}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              denied ? '请在系统设置中允许本应用使用相机' : (exception.errorDetails?.message ?? ''),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(onPressed: onRetry, child: const Text('重试')),
                const SizedBox(width: 12),
                FilledButton(onPressed: openAppSettings, child: const Text('打开系统设置')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
