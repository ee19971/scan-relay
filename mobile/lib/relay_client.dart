import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 与中转服务的 WebSocket 连接封装（自动重连由上层驱动）。
class RelayClient {
  WebSocketChannel? _channel;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();

  /// 收到的服务端消息
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// 连接断开回调（上层在此触发重连）
  VoidCallback? onDisconnected;

  bool connected = false;

  /// 连接 ws://host:port/ws?token=..&role=phone
  Future<bool> connect(Uri wsUri) async {
    disconnect();
    try {
      final channel = WebSocketChannel.connect(wsUri);
      _channel = channel;
      connected = true;
      channel.stream.listen(
        (data) {
          try {
            _messages.add(jsonDecode(data as String) as Map<String, dynamic>);
          } catch (_) {
            // 忽略非 JSON 消息
          }
        },
        onDone: _handleLoss,
        onError: (_) => _handleLoss(),
        cancelOnError: true,
      );
      return true;
    } catch (_) {
      connected = false;
      return false;
    }
  }

  void _handleLoss() {
    if (!connected) return;
    connected = false;
    onDisconnected?.call();
  }

  void send(Map<String, dynamic> message) {
    if (connected) {
      _channel?.sink.add(jsonEncode(message));
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
    connected = false;
  }

  void dispose() {
    disconnect();
    _messages.close();
  }
}

/// 由配对页 URL（http://ip:port/scan?token=xxx）推导 WebSocket 地址。
Uri? wsUriFromPairUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  final token = uri.queryParameters['token'];
  if (token == null || token.isEmpty) return null;
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : (scheme == 'wss' ? 443 : 80),
    path: '/ws',
    queryParameters: {'token': token, 'role': 'phone'},
  );
}
