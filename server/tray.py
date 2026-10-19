"""Scan-Relay 托盘程序：中转服务的外壳与统一入口。

用户视角的三条路径都由本程序承接：

  * 双击桌面/开始菜单「Scan-Relay」图标
        -> 通知区域出现图标 + 拉起中转服务 + 弹「中转服务已启动」
  * 通知区域图标右键
        -> 打开加载页面 / 发送剪贴板到文档 / 重启中转服务 / 查看日志 / 退出
  * scanrelay://start | stop（任务窗格里的「一键启动服务器」按钮）
        -> 只起停服务，不额外常驻托盘

三条刻意的约束（按已确认的需求）：
  1. **不做开机自启**：不写 Startup、不注册登录任务，图标常驻由用户手动启动。
  2. 中转服务（relay.py）以**无可见窗口**方式拉起为子进程，因此「停掉它」的正路是
     托盘右键「退出」或 scanrelay://stop —— 没有窗口可供误关。
     （历史上关掉那个隐藏窗口会把服务打死在后台，任务窗格随之加载不出来。）
  3. 托盘程序本身也用 pythonw 启动（无控制台），所以**子进程必须走 python.exe**：
     pythonw 下 sys.stdout/sys.stderr 是 None，relay.py 的 banner 和日志会凭空消失。

技术约束：pystray 在 Windows 上必须跑在主线程，所以主线程只负责事件循环，
服务启动与健康轮询都放进 `run(setup=...)` 的 setup 线程与独立后台线程里。
"""

from __future__ import annotations

import ctypes
import json
import logging
import os
import subprocess
import sys
import threading
import time
import webbrowser
from ctypes import wintypes
from datetime import datetime
from http.client import HTTPConnection
from pathlib import Path

# ---------------------------------------------------------------- 路径与常量
SERVER_DIR = Path(__file__).resolve().parent
ROOT_DIR = SERVER_DIR.parent
APPDATA = Path(os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local"))
STATE_DIR = APPDATA / "Scan-Relay"
LOG_FILE = STATE_DIR / "relay.log"
TRAY_LOG_FILE = STATE_DIR / "tray.log"
PID_FILE = STATE_DIR / "relay.pid"
# 托盘自己的 PID：卸载器/升级前要**先让托盘进程退出**，否则它的 pythonw.exe
# 映像被系统锁定，安装目录删不掉 —— 卸载器会「报成功」却留下半截文件。
TRAY_PID_FILE = STATE_DIR / "tray.pid"

RELAY_HOST = "127.0.0.1"
RELAY_PORT = int(os.environ.get("RELAY_PORT", "8765"))
UI_PORT = int(os.environ.get("RELAY_UI_PORT", "4443"))
PANE_URL = f"https://localhost:{UI_PORT}/taskpane.html"

MUTEX_NAME = "Local\\ScanRelay.Tray"
MAX_CLIP_CHARS = 10000  # 剪贴板可能整篇文档，注入前截断，避免灌爆表格
POLL_INTERVAL = 2.5

SERVICE_UP = False  # 由后台轮询维护；菜单标题读它，避免渲染菜单时阻塞网络
_log_lock = threading.Lock()
_tray_log = logging.getLogger("scanrelay.tray")


# ---------------------------------------------------------------- 日志
def _now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def tray_log(message: str) -> None:
    """把托盘自己的动作落盘（pythonw 下没有控制台，print 会无声丢失）。

    优先写 relay.log，这样「查看日志」只要开一个文件；但 relay.log 随时可能被
    **独占** —— 例如服务是被 `cmd /c python relay.py >> relay.log` 这样起的：
    `>>` 重定向不共享写权限，本进程连 os.open 都会被拒（本机实测）。
    写不进去就落到 tray.log，绝不能因为日志不可写就丢掉托盘的动作记录。
    本函数任何异常都不能外抛——它自己就是错误处理路径。
    """
    line = f"[{_now()}] tray: {message}\n"
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        last_err: Exception | None = None
        with _log_lock:
            for path in (LOG_FILE, TRAY_LOG_FILE):
                try:
                    with open(path, "a", encoding="utf-8", errors="replace") as fh:
                        fh.write(line)
                    return
                except OSError as exc:
                    last_err = exc
        _tray_log.warning("两个日志文件都写不进: %r", last_err)
    except Exception as exc:  # noqa: BLE001
        _tray_log.warning("写日志失败 %r", exc)


# ---------------------------------------------------------------- 中转服务通信
def _http(method: str, path: str, body: dict | None = None, timeout: float = 2.0):
    """回环直连。

    刻意不用 urllib：它会读 IE 代理设置，一旦用户配了代理，
    127.0.0.1 也会被送进代理，导致探测/停止全都莫名其妙失败。
    """
    conn = HTTPConnection(RELAY_HOST, RELAY_PORT, timeout=timeout)
    try:
        data = None
        headers = {}
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        return resp.status, resp.read().decode("utf-8", "replace")
    finally:
        conn.close()


def relay_up(timeout: float = 1.5) -> bool:
    try:
        status, _ = _http("GET", "/healthz", timeout=timeout)
        return status == 200
    except Exception:  # noqa: BLE001
        return False


def _read_pid() -> str:
    try:
        return PID_FILE.read_text(encoding="ascii").strip()
    except Exception:  # noqa: BLE001
        return ""


def _cleanup_pid() -> None:
    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:  # noqa: BLE001
        pass


def console_python() -> str:
    """拉起 relay.py 要用控制台版解释器，见模块 docstring 第 3 条。"""
    exe = sys.executable or ""
    if not exe:
        return "python"
    name = Path(exe).name.lower()
    if name == "pythonw.exe":
        sibling = Path(exe).with_name("python.exe")
        if sibling.exists():
            return str(sibling)
    return exe


def start_relay() -> bool:
    if relay_up():
        return True

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    py = console_python()
    if not (SERVER_DIR / "relay.py").exists():
        tray_log(f"relay.py 不存在: {SERVER_DIR}")
        return False

    # 强制子进程用 UTF-8 写日志：zh-CN 机器上 Python 对文件 stdout 默认用 GBK，
    # 而 banner/日志里是中文，不固定编码就会产出一坨乱码。
    env = dict(os.environ)
    env.setdefault("PYTHONIOENCODING", "utf-8")
    env.setdefault("PYTHONUTF8", "1")

    # **打日志和启动进程必须分开 try**：relay.log 可能正被别的进程独占
    # （见 tray_log 的说明），那种情况下服务照样要能起来，只是要换个输出去处。
    fh = None
    for candidate in (LOG_FILE, TRAY_LOG_FILE):
        try:
            fh = open(candidate, "a", encoding="utf-8", errors="replace")
            if candidate == LOG_FILE:
                fh.write(f"\n===== 托盘启动中转服务 {_now()} =====\n")
                fh.flush()
            else:
                fh.write(f"\n===== 托盘启动中转服务 {_now()}（relay.log 被独占，输出改到此处） =====\n")
                fh.flush()
            break
        except OSError as exc:
            tray_log(f"日志 {candidate.name} 打不开（可能被独占）: {exc!r}")
            fh = None
    if fh is None:
        tray_log("relay.log 与 tray.log 都打不开，本次服务输出将被丢弃")

    try:
        subprocess.Popen(
            [py, "relay.py"],
            cwd=str(SERVER_DIR),
            stdin=subprocess.DEVNULL,
            stdout=fh if fh is not None else subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
            env=env,
            creationflags=subprocess.CREATE_NO_WINDOW,  # 无可见窗口
        )
    except Exception as exc:  # noqa: BLE001
        tray_log(f"启动中转服务失败: {exc!r}")
        if fh is not None:
            try:
                fh.close()
            except Exception:  # noqa: BLE001
                pass
        return False
    # 子进程启动时已把该句柄 dup 为自己的一份，父进程可以关
    if fh is not None:
        try:
            fh.close()
        except Exception:  # noqa: BLE001
            pass

    tray_log(f"已请求启动中转服务（{py} relay.py）")
    for _ in range(40):  # 最多 20 s
        if relay_up():
            tray_log("中转服务已就绪")
            return True
        time.sleep(0.5)
    tray_log("中转服务 20 秒内未就绪")
    return False


def stop_relay() -> bool:
    if not relay_up():
        _cleanup_pid()
        return True

    try:
        status, _ = _http("GET", "/shutdown", timeout=3.0)
        if status != 200:
            raise RuntimeError(f"HTTP {status}")
        tray_log("已发出优雅停止请求")
    except Exception as exc:  # noqa: BLE001
        tray_log(f"优雅停止失败，转 PID 兜底: {exc!r}")

    for _ in range(20):  # 10 s
        if not relay_up():
            _cleanup_pid()
            tray_log("中转服务已停止")
            return True
        time.sleep(0.5)

    pid = _read_pid()
    if pid:
        tray_log(f"PID 兜底 taskkill /PID {pid}")
        try:
            subprocess.run(
                ["taskkill", "/PID", pid, "/T", "/F"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW,
                check=False,  # PID 早已不存在也是成功，下面用 healthz 判定
            )
            time.sleep(1.5)
        except Exception as exc:  # noqa: BLE001
            tray_log(f"taskkill 失败: {exc!r}")

    ok = not relay_up()
    _cleanup_pid()
    tray_log("停止%s" % ("成功" if ok else "失败：服务仍在应答"))
    return ok


# ---------------------------------------------------------------- 通知
def notify_standalone(title: str, message: str) -> bool:
    """没有托盘图标时（scanrelay:// 起停）用 Windows toast 提示。"""
    try:
        from winotify import Notification
    except Exception as exc:  # noqa: BLE001
        tray_log(f"winotify 不可用: {exc!r}")
        return False
    try:
        Notification(app_id="Scan-Relay", title=title, msg=message).show()
        return True
    except Exception as exc:  # noqa: BLE001
        tray_log(f"toast 发送失败: {exc!r}")
        return False


# ---------------------------------------------------------------- 剪贴板注入
def read_clipboard() -> str:
    """读取 CF_UNICODETEXT。显式设置 restype/argtypes：
    不设置的话 64 位下 HANDLE 被当成 32 位 int 截断，GlobalLock 一定崩。
    """
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32

    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.OpenClipboard.restype = wintypes.BOOL
    user32.CloseClipboard.argtypes = []
    user32.CloseClipboard.restype = wintypes.BOOL
    user32.GetClipboardData.argtypes = [wintypes.UINT]
    user32.GetClipboardData.restype = wintypes.HANDLE
    kernel32.GlobalLock.argtypes = [wintypes.HANDLE]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [wintypes.HANDLE]
    kernel32.GlobalUnlock.restype = wintypes.BOOL

    if not user32.OpenClipboard(None):
        return ""
    try:
        handle = user32.GetClipboardData(13)  # CF_UNICODETEXT
        if not handle:
            return ""
        ptr = kernel32.GlobalLock(handle)
        if not ptr:
            return ""
        try:
            return ctypes.wstring_at(ptr)
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


def send_clipboard() -> str:
    """把剪贴板文本按 scan 消息注入给所有已连接的加载项，返回给人看的结果。"""
    text = (read_clipboard() or "").replace("\r\n", "\n").strip()
    if not text:
        return "剪贴板是空的"
    truncated = False
    if len(text) > MAX_CLIP_CHARS:
        text = text[:MAX_CLIP_CHARS]
        truncated = True

    if not relay_up():
        return "中转服务未运行，先启动服务"

    try:
        status, raw = _http("POST", "/inject", body={"value": text}, timeout=5.0)
    except Exception as exc:  # noqa: BLE001
        tray_log(f"注入剪贴板失败: {exc!r}")
        return f"发送失败：{exc!r}"

    try:
        data = json.loads(raw)
    except Exception:  # noqa: BLE001
        data = {}

    if status != 200 or not data.get("ok"):
        reason = data.get("error") or raw or (f"HTTP {status}")
        if reason == "no add-in connected":
            return "没有已打开的加载项窗口\n请先在 Excel/Word/PPT 里打开「扫码录入」"
        tray_log(f"注入被拒绝: {reason}")
        return f"发送失败：{reason}"

    note = f"已发送 {len(text)} 字符到 {int(data.get('addins', 0))} 个加载项"
    if truncated:
        note += f"（已截断至 {MAX_CLIP_CHARS} 字符）"
    tray_log(note)
    return note


# ---------------------------------------------------------------- 单实例
_mutex_handle = None


def acquire_singleton() -> bool:
    """拿不到唯一实例时返回 False（已有托盘在跑）。失败也允许继续——
    单实例只是避免图标重影，不该成为启动的拦路虎。
    """
    global _mutex_handle
    try:
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateMutexW.restype = wintypes.HANDLE
        k32.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
        ctypes.set_last_error(0)
        handle = k32.CreateMutexW(None, False, MUTEX_NAME)
        if not handle:
            return True
        already = ctypes.get_last_error() == 183  # ERROR_ALREADY_EXISTS
        _mutex_handle = handle
        return not already
    except Exception as exc:  # noqa: BLE001
        tray_log(f"单实例互斥量不可用（按多实例运行）: {exc!r}")
        return True


def _pid_gone(pid: int) -> bool:
    """用 OpenProcess 探测进程是否还在：打不开即认为已不存在。

    刻意**不用 `os.kill(pid, 0)`**：在 Windows 上 Python 对任意信号值一律走
    TerminateProcess，那不是"探测"，是直接把进程杀掉。
    """
    try:
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        handle = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if handle:
            k32.CloseHandle(handle)
            return False
        return True
    except Exception:  # noqa: BLE001
        return True  # 探测不到就当作已退出，不能让卸载流程卡在这里


def quit_tray_instance(timeout: float = 10.0) -> bool:
    """结束正在运行的托盘进程，返回是否确实处理了某个进程。

    为什么必须这么做：托盘以 `pythonw.exe` 常驻，它运行期间其映像被系统以
    共享写保护锁定 —— 卸载器若只停服务不退出托盘，`DeleteFile` 会在 `pythonw.exe`
    上报 sharing violation，结果是**卸载器仍然返回成功**，却在
    `%LOCALAPPDATA%\\Programs\\Scan-Relay` 留下半截 `python\\` 和 `server\\`。

    按 `tray.pid` 精确结束，**不用 `taskkill /IM pythonw.exe`**：用户机器上可能
    还跑着别的 Python GUI 程序，全杀是不可接受的附带损害。
    PID过期（进程已死但没来得及清文件）时按"没有运行中的托盘"处理，不报错 ——
    卸载不该被一个陈旧的 pid 文件中断。
    """
    try:
        pid_text = TRAY_PID_FILE.read_text(encoding="ascii").strip()
    except OSError:
        return False
    if not pid_text.isdigit():
        return False

    pid = int(pid_text)
    if pid == os.getpid():
        return False

    if not _pid_gone(pid):
        try:
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/F", "/T"],
                capture_output=True, timeout=15,
            )
        except Exception as exc:  # noqa: BLE001
            tray_log(f"taskkill {pid} 异常: {exc!r}")
        # 等映像真正释放再返回，否则紧接着的删除照样会撞上共享冲突
        deadline = time.monotonic() + timeout
        while not _pid_gone(pid) and time.monotonic() < deadline:
            time.sleep(0.2)

    gone = _pid_gone(pid)
    try:
        TRAY_PID_FILE.unlink()
    except OSError:
        pass
    return gone


# ---------------------------------------------------------------- 托盘界面
def _load_icon_image():
    from PIL import Image

    candidates = [
        ROOT_DIR / "assets" / "icon-32.png",
        ROOT_DIR / "addin" / "assets" / "icon-32.png",
        ROOT_DIR / "catalog" / "assets" / "icon-32.png",
    ]
    for path in candidates:
        if path.exists():
            return Image.open(str(path))
    # 兜底：现场画一个蓝底条码，绝不因为缺图标起不来
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    try:
        from PIL import ImageDraw

        d = ImageDraw.Draw(img)
        d.rounded_rectangle([2, 2, 61, 61], radius=13, fill=(31, 119, 187, 255))
        for i in range(7):
            x = 12 + i * 6
            d.rectangle([x, 18, x + 3, 46], fill="white")
    except Exception:  # noqa: BLE001
        pass
    return img


def run_tray() -> int:
    if not acquire_singleton():
        # 撞上已有托盘实例时**不能只报一句「已在运行」就退出**：托盘可能还活着
        # 而服务是停着的（scanrelay://stop 只停服务、不退出托盘，任务窗格的停止
        # 就走这条路）。用户此时双击图标的意图是「把它启动起来」，只回一句已在
        # 运行会让人以为图标坏了 —— 服务则永远起不来。
        # 所以这里先探一次：服务没在跑就代为拉起。
        if relay_up():
            tray_log("已有托盘实例在运行且服务正常，本实例退出")
            notify_standalone(
                "Scan-Relay 已在运行",
                "通知区域图标可能被折叠在\n「显示隐藏的图标」里",
            )
            return 0

        tray_log("已有托盘实例在运行但服务未运行，由本实例代为启动")
        ok = start_relay()
        notify_standalone(
            "中转服务已启动" if ok else "启动失败，请查看日志",
            "Scan-Relay",
        )
        return 0 if ok else 1

    try:
        import pystray
    except Exception as exc:  # noqa: BLE001
        tray_log(f"pystray 导入失败，无法显示托盘: {exc!r}")
        return 1

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    # 记下自己的 PID，让卸载器/升级流程能按 PID 结束本进程（见 quit_tray_instance）
    try:
        TRAY_PID_FILE.write_text(str(os.getpid()), encoding="ascii")
    except OSError as exc:
        tray_log(f"写入 tray.pid 失败（卸载时可能残留文件）: {exc!r}")

    def on_open(icon, item):
        webbrowser.open(PANE_URL)
        tray_log("从托盘打开加载页面")

    def on_clipboard(icon, item):
        # 菜单回调跑在消息循环线程上，阻塞会卡住整个图标，放线程里
        def worker():
            result = send_clipboard()
            tray_log(result)
            try:
                icon.notify(result, "剪贴板 → 文档")
            except Exception:  # noqa: BLE001
                pass

        threading.Thread(target=worker, daemon=True).start()

    def on_restart(icon, item):
        def worker():
            stop_relay()
            ok = start_relay()
            try:
                icon.notify(
                    "中转服务已重新启动" if ok else "重启失败，请查看日志",
                    "Scan-Relay",
                )
            except Exception:  # noqa: BLE001
                pass

        threading.Thread(target=worker, daemon=True).start()

    def on_log(icon, item):
        # relay.log 是主日志；只有 relay.log 被独占、托盘动作落到 tray.log 时
        # 才需要开第二个窗口 —— 正常路径下 tray.log 根本不会被创建。
        try:
            LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        except Exception:  # noqa: BLE001
            pass
        opened = False
        for path in (LOG_FILE, TRAY_LOG_FILE):
            try:
                if path.exists():
                    os.startfile(str(path))
                    opened = True
            except Exception as exc:  # noqa: BLE001
                tray_log(f"打开 {path.name} 失败: {exc!r}")
        if not opened:
            tray_log("日志还不存在（服务尚未产生输出）")

    def on_quit(icon, item):
        def worker():
            tray_log("收到退出请求，正在停止中转服务…")
            stop_relay()
            try:
                icon.stop()
            except Exception:  # noqa: BLE001
                pass

        threading.Thread(target=worker, daemon=True).start()

    # 菜单里刻意**没有**会变化的状态行：pystray 的 win32 后端右键时直接拿缓存的
    # HMENU 调 TrackPopupMenuEx，菜单建好不再重建；若从后台线程 update_menu()，
    # 就有概率在菜单正显示时 DestroyMenu。实时状态改由图标提示文字（NIF_TIP）承担，
    # 那只是 NIM_MODIFY，与右键菜单互不相干，可以放心定时刷新。
    menu = pystray.Menu(
        pystray.MenuItem("打开加载页面", on_open, default=True),
        pystray.MenuItem("发送剪贴板到文档", on_clipboard),
        # 写成「启动/重启」而不是「重启」：服务没起来时走同一入口也能拉起来
        pystray.MenuItem("启动/重启中转服务", on_restart),
        pystray.MenuItem("查看日志", on_log),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("退出", on_quit),
    )

    icon = pystray.Icon("scan-relay", _load_icon_image(), "Scan-Relay", menu)

    def _set_status(up: bool) -> None:
        global SERVICE_UP
        SERVICE_UP = up
        try:
            icon.title = "Scan-Relay - %s" % ("服务运行中" if up else "服务未运行")
        except Exception as exc:  # noqa: BLE001
            tray_log(f"刷新托盘提示失败: {exc!r}")

    def poller():
        """后台健康轮询。只在状态**真的变化**时写提示文字，避免无谓的调用。"""
        last = SERVICE_UP
        while poller.running:
            time.sleep(POLL_INTERVAL)
            up = relay_up()
            if up != last:
                last = up
                _set_status(up)
                tray_log("服务状态变化 -> %s" % ("运行中" if up else "未运行"))

    poller.running = True

    def setup(icon_obj):
        # run(setup=...) 传了自定义 setup，就**必须**自己把 visible 置 True
        icon_obj.visible = True
        already = relay_up()
        ok = start_relay()
        _set_status(ok)

        if ok:
            state = "已在运行" if already else "已启动"
            tray_log(f"中转服务{state}")
            message = f"中转服务{state}\n加载项页面：{PANE_URL}"
        else:
            tray_log("中转服务启动失败")
            message = "中转服务启动失败，请点击查看日志"
        try:
            icon_obj.notify(message, "Scan-Relay")
        except Exception as exc:  # noqa: BLE001
            tray_log(f"启动通知失败: {exc!r}")

        threading.Thread(target=poller, daemon=True).start()

    try:
        icon.run(setup=setup)
    finally:
        poller.running = False
        # 正常退出时清掉自己的 PID；被 taskkill 强杀则由 quit_tray_instance 清
        try:
            TRAY_PID_FILE.unlink()
        except OSError:
            pass
    tray_log("托盘已退出")
    return 0


# ---------------------------------------------------------------- 入口
def parse_action(argv) -> str:
    """scanrelay://start -> start；scanrelay://stop -> stop；
    scanrelay://quit -> quit；无参数/其它 -> tray。

    注意先判 stop：'start' 不含 'stop'，但反过来会误伤。
    'quit' 与另外两个互不包含，放哪儿都不会互相吞掉。
    """
    joined = " ".join(argv[1:]).lower()
    if "stop" in joined:
        return "stop"
    if "quit" in joined:
        return "quit"
    if "start" in joined:
        return "start"
    return "tray"


def main(argv=None) -> int:
    argv = list(argv if argv is not None else sys.argv)
    action = parse_action(argv)
    tray_log(f"启动 action={action} argv={argv[1:]}")

    if action == "start":
        already = relay_up()
        ok = start_relay()
        notify_standalone(
            "Scan-Relay",
            "中转服务已在运行" if (already and ok) else
            ("中转服务已启动" if ok else "中转服务启动失败，请查看日志"),
        )
        return 0 if ok else 1

    if action == "stop":
        ok = stop_relay()
        notify_standalone("Scan-Relay", "中转服务已停止" if ok else "停止失败，请查看日志")
        return 0 if ok else 1

    if action == "quit":
        # 卸载器与升级流程都走这条：先停服务，再让**正在运行的托盘退出**。
        # 只停服务是不够的（见 quit_tray_instance 的说明）——
        # pythonw.exe 不退出就删不掉安装目录。
        # 这里刻意不弹通知：它只在卸载/升级时被调用，那会儿弹 toast 是噪音。
        stop_relay()
        quit_tray_instance()
        tray_log("quit 动作完成（服务已停止、托盘已退出）")
        return 0

    return run_tray()


if __name__ == "__main__":
    sys.exit(main())
