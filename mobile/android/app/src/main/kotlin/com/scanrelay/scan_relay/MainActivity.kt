package com.scanrelay.scan_relay

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/**
 * 蓝牙 HID 键盘模式（C 方案）。
 *
 * 手机通过系统 BluetoothHidDevice API 伪装成蓝牙键盘，扫码结果以键盘
 * 按键形式直接敲进电脑（无需同一网络、电脑零安装）。仅 Android 9+。
 *
 * MethodChannel "scanrelay/hid" 暴露给 Dart：
 *   isSupported / isEnabled / hasPermissions / ensurePermissions /
 *   enableBluetooth / start / stop / isStarted / isActive /
 *   discoverable / deviceName / typeText
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "scanrelay/hid"
        const val TAG = "ScanRelayHid"
        const val REQ_PERM = 0xB1
        const val REQ_ENABLE = 0xB2
        const val REQ_DISCOVER = 0xB3

        /** HID boot keyboard：Shift 修饰位 */
        const val SHIFT = 0x02
    }

    private val handler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { it.run() }
    private val typeLock = Any()

    private var channel: MethodChannel? = null
    private var hidProxy: BluetoothHidDevice? = null
    private var hostDevice: BluetoothDevice? = null
    private var appRegistered = false

    private var permResult: MethodChannel.Result? = null
    private var enableResult: MethodChannel.Result? = null
    private var discoverResult: MethodChannel.Result? = null
    private var startResult: MethodChannel.Result? = null

    /** 标准引导键盘报告描述符（无 Report ID，8 字节输入报告） */
    private val hidDescriptor = intArrayOf(
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07,
        0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0
    ).map { it.toByte() }.toByteArray()

    // ---------------------------------------------------------------- 生命周期

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(Build.VERSION.SDK_INT >= 28 && adapter() != null)
                "isEnabled" -> result.success(adapter()?.isEnabled == true)
                "hasPermissions" -> result.success(hasPermissions())
                "ensurePermissions" -> ensurePermissions(result)
                "enableBluetooth" -> enableBluetooth(result)
                "start" -> startHid(result)
                "stop" -> result.success(stopHid())
                "isStarted" -> result.success(hidProxy != null)
                "isActive" -> result.success(isActive())
                "discoverable" -> discoverable(call.argument<Int>("seconds") ?: 300, result)
                "deviceName" -> result.success(deviceName())
                "typeText" -> typeText(
                    call.argument<String>("text") ?: "",
                    call.argument<String>("ending") ?: "enter",
                    result
                )
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        stopHid()
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == REQ_PERM) {
            val granted =
                grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            permResult?.success(granted)
            permResult = null
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            REQ_ENABLE -> {
                enableResult?.success(
                    resultCode == Activity.RESULT_OK || adapter()?.isEnabled == true
                )
                enableResult = null
            }
            REQ_DISCOVER -> {
                discoverResult?.success(resultCode > 0)
                discoverResult = null
            }
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    // ---------------------------------------------------------------- 蓝牙基础

    private fun adapter(): BluetoothAdapter? =
        getSystemService(BluetoothManager::class.java)?.adapter

    private fun neededPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.BLUETOOTH, Manifest.permission.BLUETOOTH_ADMIN)

    private fun hasPermissions(): Boolean = neededPermissions().all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun ensurePermissions(result: MethodChannel.Result) {
        val missing = neededPermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        if (permResult != null) {
            result.error("BUSY", "已有授权请求进行中", null)
            return
        }
        permResult = result
        requestPermissions(missing.toTypedArray(), REQ_PERM)
    }

    private fun enableBluetooth(result: MethodChannel.Result) {
        val ad = adapter()
        if (ad == null) {
            result.success(false)
            return
        }
        if (ad.isEnabled) {
            result.success(true)
            return
        }
        if (enableResult != null) {
            result.error("BUSY", "已有开启蓝牙请求进行中", null)
            return
        }
        try {
            startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), REQ_ENABLE)
            enableResult = result
        } catch (ignored: ActivityNotFoundException) {
            result.success(false)
        }
    }

    private fun discoverable(seconds: Int, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 28) {
            result.error("UNSUPPORTED", "需要 Android 9.0 及以上", null)
            return
        }
        if (discoverResult != null) {
            result.error("BUSY", "已有可发现请求进行中", null)
            return
        }
        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
            .putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, seconds)
        try {
            startActivityForResult(intent, REQ_DISCOVER)
            discoverResult = result
        } catch (ignored: ActivityNotFoundException) {
            result.success(false)
        }
    }

    private fun deviceName(): String = try {
        adapter()?.name ?: ""
    } catch (ignored: SecurityException) {
        ""
    }

    // ---------------------------------------------------------------- HID 服务

    private fun sdpSettings() = BluetoothHidDeviceAppSdpSettings(
        "ScanRelay Keyboard",
        "Scan-Relay barcode keyboard",
        "com.scanrelay.scan_relay",
        BluetoothHidDevice.SUBCLASS1_KEYBOARD,
        hidDescriptor
    )

    private val proxyListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile?) {
            val pending = startResult
            startResult = null
            if (proxy !is BluetoothHidDevice) {
                pending?.error("PROXY", "获取蓝牙 HID 代理失败", null)
                return
            }
            hidProxy = proxy
            val ok = try {
                proxy.registerApp(sdpSettings(), null, null, mainExecutor, hidCallback)
            } catch (ignored: SecurityException) {
                false
            }
            Log.i(TAG, "registerApp returned $ok")
            if (ok) {
                appRegistered = true
                pending?.success(true)
            } else {
                hidProxy = null
                appRegistered = false
                try {
                    adapter()?.closeProfileProxy(BluetoothProfile.HID_DEVICE, proxy)
                } catch (ignored: Exception) {
                }
                pending?.error("REGISTER_FAILED", "HID 应用注册失败（可能已被其他应用占用）", null)
            }
        }

        override fun onServiceDisconnected(profile: Int) {
            hidProxy = null
            appRegistered = false
            hostDevice = null
        }
    }

    private fun startHid(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 28) {
            result.error("UNSUPPORTED", "需要 Android 9.0 及以上", null)
            return
        }
        if (hidProxy != null) {
            result.success(true)
            return
        }
        val ad = adapter()
        if (ad == null) {
            result.error("NO_BT", "本机没有蓝牙", null)
            return
        }
        if (!hasPermissions()) {
            result.error("NO_PERMISSION", "请先授予蓝牙权限", null)
            return
        }
        if (startResult != null) {
            result.error("BUSY", "正在启动蓝牙键盘服务", null)
            return
        }
        startResult = result
        val ok = ad.getProfileProxy(this, proxyListener, BluetoothProfile.HID_DEVICE)
        if (!ok) {
            startResult = null
            result.error("PROXY", "无法连接蓝牙 HID 服务", null)
        }
    }

    private fun stopHid(): Boolean {
        try {
            hidProxy?.unregisterApp()
        } catch (ignored: Exception) {
        }
        try {
            adapter()?.closeProfileProxy(BluetoothProfile.HID_DEVICE, hidProxy)
        } catch (ignored: Exception) {
        }
        hidProxy = null
        appRegistered = false
        hostDevice = null
        return true
    }

    // 注意：AOSP HidDeviceService 会在注册/注销时回调 onAppStatusChanged(null, …)，
    // 设备参数必须声明为可空，否则 Kotlin 非空校验抛 NPE 会把蓝牙系统进程打崩（连锁重启）。
    private val hidCallback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
            Log.i(TAG, "onAppStatusChanged device=$pluggedDevice registered=$registered")
            handler.post {
                appRegistered = registered
                hostDevice = if (registered) pluggedDevice else null
            }
        }

        override fun onConnectionStateChanged(device: BluetoothDevice?, state: Int) {
            Log.i(TAG, "onConnectionStateChanged device=$device state=$state")
            handler.post {
                when (state) {
                    BluetoothProfile.STATE_CONNECTED -> hostDevice = device
                    BluetoothProfile.STATE_DISCONNECTED ->
                        if (device != null && hostDevice == device) hostDevice = null
                }
            }
        }

        override fun onGetReport(device: BluetoothDevice?, type: Byte, id: Byte, errorCode: Int) {
            if (device == null) return
            val h = hidProxy ?: return
            try {
                when (type) {
                    BluetoothHidDevice.REPORT_TYPE_INPUT ->
                        h.replyReport(device, type, id, ByteArray(8))
                    BluetoothHidDevice.REPORT_TYPE_OUTPUT ->
                        h.replyReport(device, type, id, ByteArray(1))
                    else ->
                        h.reportError(device, BluetoothHidDevice.ERROR_RSP_UNSUPPORTED_REQ)
                }
            } catch (ignored: Exception) {
            }
        }
    }

    private fun isActive(): Boolean {
        val h = hidProxy ?: return false
        return try {
            h.getDevicesMatchingConnectionStates(intArrayOf(BluetoothProfile.STATE_CONNECTED))
                .isNotEmpty() || (appRegistered && hostDevice != null)
        } catch (ignored: SecurityException) {
            false
        }
    }

    private fun currentHost(hid: BluetoothHidDevice): BluetoothDevice? {
        try {
            val list =
                hid.getDevicesMatchingConnectionStates(intArrayOf(BluetoothProfile.STATE_CONNECTED))
            if (list.isNotEmpty()) return list[0]
        } catch (ignored: SecurityException) {
        }
        return hostDevice
    }

    // ---------------------------------------------------------------- 打字

    private fun typeText(text: String, ending: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 28) {
            result.error("UNSUPPORTED", "需要 Android 9.0 及以上", null)
            return
        }
        val hid = hidProxy
        if (hid == null || !appRegistered) {
            result.error("NOT_STARTED", "蓝牙键盘服务未启动", null)
            return
        }
        val device = currentHost(hid)
        if (device == null) {
            result.error("NOT_CONNECTED", "电脑还没有连上手机，请先完成蓝牙配对", null)
            return
        }
        // HID 键盘协议只能发送按键，中文等字符无对应键码 —— 自动跳过，只输入可映射部分
        val printable = text.filter { keyFor(it) != null }
        if (printable.isEmpty()) {
            result.error("UNSUPPORTED", "蓝牙键盘无法输入该内容（协议仅支持数字/字母/符号）", null)
            return
        }
        Thread {
            var failure: String? = null
            synchronized(typeLock) {
                try {
                    for (ch in text) {
                        val key = keyFor(ch) ?: continue
                        if (!tap(hid, device, key.first, key.second)) {
                            failure = "发送失败：电脑连接已断开"
                            break
                        }
                        Thread.sleep(24)
                    }
                    if (failure == null && ending != "none" && ending.isNotEmpty()) {
                        val key = if (ending == "tab") 43 else 40
                        if (!tap(hid, device, 0, key)) {
                            failure = "发送失败：电脑连接已断开"
                        }
                    }
                } catch (ignored: InterruptedException) {
                    failure = "已中断"
                } catch (ignored: SecurityException) {
                    failure = "缺少蓝牙权限"
                }
            }
            val err = failure
            handler.post {
                if (err == null) result.success(true)
                else result.error("TYPE_FAILED", err, null)
            }
        }.start()
    }

    /** 按下→抬起一个按键；返回 false 表示连接已断 */
    private fun tap(
        hid: BluetoothHidDevice,
        device: BluetoothDevice,
        mods: Int,
        key: Int
    ): Boolean {
        val down = byteArrayOf(mods.toByte(), 0, key.toByte(), 0, 0, 0, 0, 0)
        if (!hid.sendReport(device, 0, down)) return false
        Thread.sleep(28)
        if (!hid.sendReport(device, 0, ByteArray(8))) return false
        return true
    }

    /** ASCII → (修饰键, HID keycode)；不认识的字符跳过 */
    private fun keyFor(ch: Char): Pair<Int, Int>? = when (ch) {
        in 'a'..'z' -> 0 to (ch - 'a' + 4)
        in 'A'..'Z' -> SHIFT to (ch - 'A' + 4)
        in '1'..'9' -> 0 to (ch - '1' + 30)
        '0' -> 0 to 39
        ' ' -> 0 to 44
        '\t' -> 0 to 43
        '\n', '\r' -> 0 to 40
        '!' -> SHIFT to 30
        '@' -> SHIFT to 31
        '#' -> SHIFT to 32
        '$' -> SHIFT to 33
        '%' -> SHIFT to 34
        '^' -> SHIFT to 35
        '&' -> SHIFT to 36
        '*' -> SHIFT to 37
        '(' -> SHIFT to 38
        ')' -> SHIFT to 39
        '-' -> 0 to 45
        '_' -> SHIFT to 45
        '=' -> 0 to 46
        '+' -> SHIFT to 46
        '[' -> 0 to 47
        '{' -> SHIFT to 47
        ']' -> 0 to 48
        '}' -> SHIFT to 48
        '\\' -> 0 to 49
        '|' -> SHIFT to 49
        ';' -> 0 to 51
        ':' -> SHIFT to 51
        '\'' -> 0 to 52
        '"' -> SHIFT to 52
        '`' -> 0 to 53
        '~' -> SHIFT to 53
        ',' -> 0 to 54
        '<' -> SHIFT to 54
        '.' -> 0 to 55
        '>' -> SHIFT to 55
        '/' -> 0 to 56
        '?' -> SHIFT to 56
        else -> null
    }
}
