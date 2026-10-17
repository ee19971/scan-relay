import 'package:flutter/services.dart';

/// 蓝牙 HID 键盘通道（Android only，C 方案）。
///
/// 手机伪装成蓝牙键盘，把扫码结果以键盘输入的方式直接"敲"进电脑：
/// 无需同一 WiFi/热点，电脑端零安装（标准蓝牙键盘，免驱）。
/// iOS 无对应系统能力，相关方法一律返回 false。
class HidClient {
  HidClient._();

  static const MethodChannel _ch = MethodChannel('scanrelay/hid');

  /// 最近一次失败的原因（供 UI 提示），成功时清空。
  static String lastError = '';

  /// 调用通道；平台异常不抛出，转为 false + [lastError]。
  static Future<bool> _call(String method, [Map<String, dynamic>? args]) async {
    try {
      final ok = await _ch.invokeMethod<bool>(method, args);
      lastError = '';
      return ok ?? false;
    } on PlatformException catch (e) {
      lastError = e.message?.isNotEmpty == true ? e.message! : e.code;
      return false;
    } on MissingPluginException {
      lastError = '本机不支持蓝牙键盘模式（仅 Android 9+）';
      return false;
    }
  }

  /// 是否支持：Android 9+ 且有蓝牙适配器。
  static Future<bool> isSupported() => _call('isSupported');

  /// 蓝牙是否已打开。
  static Future<bool> isEnabled() => _call('isEnabled');

  /// 运行时权限（Android 12+ 为 BLUETOOTH_CONNECT）是否已授予。
  static Future<bool> hasPermissions() => _call('hasPermissions');

  /// 请求运行时权限，返回是否全部授予。
  static Future<bool> ensurePermissions() => _call('ensurePermissions');

  /// 弹系统对话框打开蓝牙（已开直接 true）。
  static Future<bool> enableBluetooth() => _call('enableBluetooth');

  /// 注册 HID 键盘服务（幂等）。
  static Future<bool> start() => _call('start');

  /// 注销 HID 服务并断开。
  static Future<bool> stop() => _call('stop');

  /// HID 服务是否已注册。
  static Future<bool> isStarted() => _call('isStarted');

  /// 电脑（主机）是否已连上手机。
  static Future<bool> isActive() => _call('isActive');

  /// 开启"可被发现"（系统弹窗），通常 300 秒。
  static Future<bool> discoverable({int seconds = 300}) =>
      _call('discoverable', {'seconds': seconds});

  /// 本机蓝牙名称（电脑配对时看到的名字）。
  static Future<String> deviceName() async {
    try {
      return await _ch.invokeMethod<String>('deviceName') ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 把 [text] 以键盘按键敲进电脑，[ending] 为
  /// 'enter'（回车，Excel 换行）| 'tab' | 'none'。
  /// 失败返回 false，原因在 [lastError]。
  static Future<bool> typeText(String text, {String ending = 'enter'}) =>
      _call('typeText', {'text': text, 'ending': ending});
}
