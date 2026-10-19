"""Scan-Relay 本地服务：连接手机 App 与 Excel 加载项，同时托管加载项页面。

一键启动（推荐）:
    python relay.py
    - http://<局域网IP>:8765  手机接入（WebSocket + 浏览器扫码页）
    - https://localhost:4443  Excel 加载项页面（manifest 的 SourceLocation）

开发模式（只起 API，前端用 webpack-dev-server）:
    uvicorn relay:app --host 0.0.0.0 --port 8765
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import socket
import subprocess
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("relay")

PORT = int(os.environ.get("RELAY_PORT", "8765"))
UI_PORT = int(os.environ.get("RELAY_UI_PORT", "4443"))  # 默认 4443：3000 等常落入 Hyper-V/WinNAT 动态保留段导致 bind 10013
ADDIN_DIST = Path(__file__).resolve().parent.parent / "addin" / "dist"

app = FastAPI(title="Scan-Relay")


def detect_lan_ip() -> str:
    """自动探测本机局域网 IP（对外地址覆盖环境变量 RELAY_HOST）。"""
    override = os.environ.get("RELAY_HOST")
    if override:
        return override
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def detect_lan_ips() -> list[str]:
    """全部候选本机 IPv4，主地址（默认路由，跟随 USB/蓝牙共享）排第一。

    多网卡场景（局域网 + USB网络共享 + 虚拟网卡并存）时，手机不一定能走
    默认路由到达电脑，因此把所有可达地址都交给客户端展示/兜底。
    """
    override = os.environ.get("RELAY_HOST")
    if override:
        return [override]
    primary = detect_lan_ip()
    found: dict[str, None] = {}  # 保序去重
    if primary not in ("127.0.0.1", "0.0.0.0"):
        found[primary] = None
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip.startswith(("127.", "169.254.", "0.")):
                continue
            found[ip] = None
    except OSError:
        pass
    return list(found)


class Session:
    def __init__(self, token: str) -> None:
        self.token = token
        self.addins: set[WebSocket] = set()
        self.phones: set[WebSocket] = set()
        self.config: dict[str, Any] | None = None  # 加载项下发的表单/模式配置
        self.lock = asyncio.Lock()

    @property
    def phone_count(self) -> int:
        return len(self.phones)


SESSIONS: dict[str, Session] = {}

# 优雅停机（/shutdown -> 停 uvicorn 线程 -> 唤醒 main() 循环）
SERVERS: list[Any] = []
SERVER_THREADS: list[threading.Thread] = []
SHUTDOWN = threading.Event()


def get_session(token: str) -> Session:
    if token not in SESSIONS:
        SESSIONS[token] = Session(token)
    return SESSIONS[token]


async def send_json(ws: WebSocket, message: dict[str, Any]) -> None:
    try:
        await ws.send_text(json.dumps(message, ensure_ascii=False))
    except Exception:  # 连接可能已断开
        pass


async def broadcast(targets: set[WebSocket], message: dict[str, Any]) -> None:
    await asyncio.gather(*(send_json(ws, message) for ws in targets))


# ---------------------------------------------------------------- HTTP 路由

@app.get("/")
async def index() -> JSONResponse:
    ips = detect_lan_ips()
    return JSONResponse(
        {
            "service": "scan-relay",
            "lan_ip": ips[0],
            "ips": ips,
            "port": PORT,
            "sessions": len(SESSIONS),
            "pair": f"http://{ips[0]}:{PORT}/pair (POST 或由加载项调用 GET)",
        }
    )


@app.get("/pair")
async def pair(reuse: str | None = Query(default=None)) -> JSONResponse:
    """创建（或复用）一个配对会话，返回配对信息（含全部候选地址）。"""
    token = reuse if (reuse and reuse in SESSIONS) else secrets.token_urlsafe(9)
    session = get_session(token)
    ips = detect_lan_ips()
    lan_ip = ips[0]
    return JSONResponse(
        {
            "token": token,
            "ws_url": f"ws://{lan_ip}:{PORT}/ws?token={token}&role=phone",
            "page_url": f"http://{lan_ip}:{PORT}/scan?token={token}",
            "ips": ips,
        }
    )


@app.get("/scan")
async def scan_page(token: str) -> HTMLResponse:
    """浏览器版扫码测试页（正式版用 Flutter App，此页用于链路验证）。"""
    return HTMLResponse(SCAN_PAGE.replace("__TOKEN__", token).replace("__PORT__", str(PORT)))


@app.get("/version")
async def version() -> JSONResponse:
    """服务版本/构建信息（供排查用）。"""
    return JSONResponse({"service": "scan-relay", "mode": "dev-api"})


@app.get("/healthz")
async def healthz() -> JSONResponse:
    """健康检查（供加载项探测服务是否在运行）。"""
    return JSONResponse({"ok": True})


@app.get("/shutdown")
async def shutdown(request: Request) -> JSONResponse:
    """停止服务。仅允许本机回环调用——服务本身监听 0.0.0.0（手机要连），
    不能让局域网里任何设备都能把它停掉。桌面「停止 Scan-Relay 服务」快捷方式
    与 scanrelay://stop 都走这里。"""
    client = request.client.host if request.client else ""
    if client not in ("127.0.0.1", "::1"):
        return JSONResponse({"ok": False, "error": "forbidden: loopback only"}, status_code=403)
    log.info("收到停止请求（来自 %s）", client)
    threading.Thread(target=stop_servers, daemon=True).start()
    return JSONResponse({"ok": True, "stopping": True})


@app.post("/inject")
async def inject(request: Request) -> JSONResponse:
    """把一段本机文本（典型场景：剪贴板内容）推给所有已连接的加载项。

    与 /shutdown 一样只允许回环地址调用：服务监听 0.0.0.0 是为了让手机接入，
    但绝不能让局域网里任何设备都往你的表格里写东西。
    托盘菜单「发送剪贴板到文档」走这里 —— 手机没连也能用，也不依赖配对 token。
    """
    client = request.client.host if request.client else ""
    if client not in ("127.0.0.1", "::1"):
        return JSONResponse({"ok": False, "error": "forbidden: loopback only"}, status_code=403)

    try:
        body = await request.json()
    except Exception:
        body = {}
    value = body.get("value") if isinstance(body, dict) else None
    if not isinstance(value, str) or not value.strip():
        return JSONResponse({"ok": False, "error": "value is empty"}, status_code=400)

    addins = sum(len(s.addins) for s in SESSIONS.values())
    if addins == 0:
        return JSONResponse({"ok": False, "error": "no add-in connected", "addins": 0})

    message = {
        "type": "scan",
        "value": value,
        "symbology": "CLIPBOARD",
        "source": "clipboard",
        "ts": int(time.time() * 1000),
    }
    for session in list(SESSIONS.values()):
        await broadcast(session.addins, message)
    log.info("注入剪贴板文本（%d 字符）到 %d 个加载项", len(value), addins)
    return JSONResponse({"ok": True, "addins": addins, "chars": len(value)})


def stop_servers() -> None:
    """让两个 uvicorn 线程干净退出，最后唤醒 main() 的等待循环。"""
    time.sleep(0.3)  # 先把 /shutdown 的响应发出去
    log.info("正在停止中转服务…")
    for srv in SERVERS:
        srv.should_exit = True
    for th in SERVER_THREADS:
        th.join(timeout=3.0)
    SHUTDOWN.set()


# ---------------------------------------------------------------- 加载项页面托管（一键启动模式）

class _NoStoreStaticFiles(StaticFiles):
    """加载项静态资源一律不缓存。

    没有这条时，WebView2 会继续用缓存里的旧 main.js/taskpane.html——改完代码、
    甚至换了端口都可能拿不到新版（本机缓存里就残留着 localhost:3000 时代的资源）。
    file_response 的签名在 starlette 各版本间有过变动，故用 *args/**kwargs 兜底。
    """

    def file_response(self, *args: Any, **kwargs: Any) -> Any:
        resp = super().file_response(*args, **kwargs)
        resp.headers["Cache-Control"] = "no-store, max-age=0"
        resp.headers["Pragma"] = "no-cache"
        return resp


def create_ui_app() -> FastAPI:
    """HTTPS 的加载项页面服务：/relay/* 与手机端 API 同源，其余静态托管 dist/。"""
    ui = FastAPI(title="Scan-Relay UI")

    # /relay 前缀别名（与 webpack-dev-server 代理行为保持一致，加载项代码无需区分环境）
    @ui.get("/relay/pair")
    async def relay_pair(reuse: str | None = Query(default=None)) -> JSONResponse:
        return await pair(reuse)

    @ui.get("/relay/version")
    async def relay_version() -> JSONResponse:
        return await version()

    @ui.get("/healthz")
    async def ui_healthz() -> JSONResponse:
        # 必须在静态挂载之前注册，否则会被 StaticFiles 拦截
        return JSONResponse({"ok": True})

    @ui.websocket("/relay/ws")
    async def relay_ws(ws: WebSocket, token: str = Query(...), role: str = Query(...)) -> None:
        await ws_endpoint(ws, token=token, role=role)

    @ui.get("/")
    async def index() -> RedirectResponse:
        return RedirectResponse("/taskpane.html")

    if ADDIN_DIST.is_dir():
        ui.mount("/", _NoStoreStaticFiles(directory=str(ADDIN_DIST), html=True), name="addin")
    else:
        @ui.get("/taskpane.html")
        async def missing() -> JSONResponse:
            return JSONResponse(
                {"error": "未找到加载项构建产物", "hint": "请先在 addin/ 目录执行 npm run build"},
                status_code=503,
            )
    return ui


def find_dev_cert() -> tuple[Path, Path] | None:
    """优先复用 office-addin-dev-certs 的受信证书。"""
    d = Path.home() / ".office-addin-dev-certs"
    crt, key = d / "localhost.crt", d / "localhost.key"
    if crt.exists() and key.exists():
        return crt, key
    return None


def _record_cert_thumbprint(thumbprint: str) -> None:
    """把根证书指纹写进注册表，供卸载器定位并删除。

    证书装在「当前用户受信根目录」，但 `.certs/` 会随安装目录一起被删 ——
    不记指纹的话，反复安装/卸载就会越积越多条废弃的 localhost 证书，
    每次启动 relay.py 又会生成一张新的、再装一条进去。

    写不进去也不影响任何功能，卸载时最多留一条证书。
    """
    try:
        import winreg

        with winreg.CreateKeyEx(
            winreg.HKEY_CURRENT_USER, r"Software\Scan-Relay", 0, winreg.KEY_SET_VALUE
        ) as key:
            winreg.SetValueEx(key, "LocalhostCertThumbprint", 0, winreg.REG_SZ, thumbprint)
        log.info("已记录证书指纹到 HKCU\\Software\\Scan-Relay")
    except Exception as exc:  # noqa: BLE001
        log.debug("记录证书指纹失败（不影响使用）: %r", exc)


def _console_text(raw: bytes) -> str:
    """解码控制台程序（certutil）的输出。

    **不能**给 subprocess 传 text=True：那会按 locale 编码解码，而 tray.py 给中转
    服务子进程设了 PYTHONUTF8=1，于是 Python 改用 UTF-8 去解 certutil 输出的
    GBK 中文 —— 读取线程会直接抛 UnicodeDecodeError。子进程本身是成功的，
    但每次全新安装的第一次启动，日志里都会多出一段谁都看不懂的 traceback。
    这里显式按系统 OEM 代码页解码。
    """
    try:
        import ctypes

        enc = f"cp{ctypes.windll.kernel32.GetOEMCP()}"
    except Exception:  # noqa: BLE001
        enc = "utf-8"
    try:
        return raw.decode(enc, "replace")
    except LookupError:
        return raw.decode("utf-8", "replace")


def ensure_selfsigned_cert() -> tuple[Path, Path]:
    """生成 localhost 自签名证书并安装到当前用户受信根目录（无需管理员）。"""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    cert_dir = Path(__file__).resolve().parent / ".certs"
    cert_dir.mkdir(exist_ok=True)
    crt, key = cert_dir / "localhost.crt", cert_dir / "localhost.key"
    if crt.exists() and key.exists():
        return crt, key

    log.info("生成 localhost 自签名证书…")
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=3650))
        .add_extension(
            x509.SubjectAlternativeName([
                x509.DNSName("localhost"),
                x509.IPAddress(__import__("ipaddress").IPv4Address("127.0.0.1")),
            ]),
            critical=False,
        )
        .sign(private_key, hashes.SHA256())
    )
    crt.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key.write_bytes(
        private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        )
    )
    # 安装到当前用户受信根存储，Excel/WebView2 即会信任
    result = subprocess.run(
        ["certutil", "-user", "-addstore", "Root", str(crt)],
        capture_output=True,
    )
    if result.returncode == 0:
        log.info("证书已加入当前用户受信根目录")
        # 记下指纹，供卸载器把这张证书从受信根里删掉。
        # `.certs/` 会跟着安装目录一起被删除，不记指纹的话，每装一次就在
        # 用户受信根里永久留下一条废弃的 localhost 证书，越积越多。
        # 只在真正装进证书存储成功后才记 —— 装失败就不用记了。
        _record_cert_thumbprint(cert.fingerprint(hashes.SHA1()).hex().upper())
    else:
        log.warning("证书自动安装失败（%s），Excel 可能提示证书错误", _console_text(result.stderr).strip())
    return crt, key


def _port_busy(port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", port))
        return False
    except OSError:
        return True
    finally:
        s.close()


def main() -> None:
    """一键启动：手机接入 API(8765) + 加载项页面 HTTPS(4443)。"""
    import uvicorn

    if not ADDIN_DIST.is_dir():
        log.error("未找到 %s，请先在 addin/ 目录执行: npm install && npm run build", ADDIN_DIST)
        return
    busy = [p for p in (PORT, UI_PORT) if _port_busy(p)]
    if busy:
        log.error(
            "端口 %s 已被占用。若之前开着 npm start 开发服务器，请先关闭它；"
            "若中转服务已在运行则无需重复启动。"
            "（若 netstat 看不到占用者，可能是 Hyper-V/WinNAT 动态保留段，"
            "用 netsh int ipv4 show excludedportrange protocol=tcp 查看；重启可换段，"
            "或改用 RELAY_UI_PORT=<其它端口> 启动并同步更新 manifest）", busy,
        )
        return

    cert = find_dev_cert()
    if cert is None:
        cert = ensure_selfsigned_cert()

    lan_ip = detect_lan_ip()
    banner = f"""
============================================================
  Scan-Relay 服务已启动（后台运行，不显示窗口）
------------------------------------------------------------
  加载项页面       : https://localhost:{UI_PORT}/taskpane.html（Excel / Word / PowerPoint）
  手机接入地址     : ws://{lan_ip}:{PORT}/ws
  浏览器扫码测试页 : http://{lan_ip}:{PORT}/scan?token=<token>
  停止方式         : 任务栏托盘图标右键 →「退出」（也可 scanrelay://stop）
  本机停止接口     : http://127.0.0.1:{PORT}/shutdown（仅回环地址可调用）
  运行日志         : %LOCALAPPDATA%\\Scan-Relay\\relay.log
============================================================"""
    print(banner, flush=True)  # stdout 重定向到文件时是块缓冲，不 flush 会让 banner 滞后很久

    # PID 记录：/shutdown 失效时的兜底（tray.py 的 stop_relay 读它来 taskkill）
    local_appdata = os.environ.get("LOCALAPPDATA")
    state_dir = (Path(local_appdata) if local_appdata else Path.home() / ".scan-relay") / "Scan-Relay"
    pid_path: Path | None = None
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        pid_path = state_dir / "relay.pid"
        pid_path.write_text(str(os.getpid()), encoding="ascii")
        log.info("PID 文件: %s (pid=%d)", pid_path, os.getpid())
    except OSError as exc:
        log.warning("写入 PID 文件失败: %s", exc)

    servers = [
        uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=PORT, log_level="warning")),
        uvicorn.Server(uvicorn.Config(
            create_ui_app(), host="0.0.0.0", port=UI_PORT,
            ssl_certfile=str(cert[0]), ssl_keyfile=str(cert[1]), log_level="warning",
        )),
    ]
    SERVERS.extend(servers)
    for s in servers:
        th = threading.Thread(target=s.run, daemon=True)
        SERVER_THREADS.append(th)
        th.start()

    try:
        # 正常退出路径：/shutdown 触发 SHUTDOWN；Ctrl+C 走异常分支
        while not SHUTDOWN.wait(1.0):
            pass
        print("\n已停止", flush=True)
    except KeyboardInterrupt:
        print("\n已停止", flush=True)
    finally:
        for s in SERVERS:
            s.should_exit = True
        if pid_path is not None:
            try:
                pid_path.unlink(missing_ok=True)
            except OSError:
                pass


# ---------------------------------------------------------------- WebSocket

@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket, token: str = Query(...), role: str = Query(...)) -> None:
    if role not in ("phone", "addin"):
        await ws.close(code=4000, reason="role must be phone|addin")
        return
    session = get_session(token)
    await ws.accept()
    peers = session.phones if role == "phone" else session.addins
    peers.add(ws)
    log.info("connect role=%s token=%s (phones=%d addins=%d)", role, token, len(session.phones), len(session.addins))

    if role == "phone":
        # 手机上线：通知加载项，并把当前配置推给手机
        await broadcast(session.addins, {"type": "peer_status", "phones": session.phone_count})
        if session.config:
            await send_json(ws, session.config)
    else:
        await send_json(ws, {"type": "peer_status", "phones": session.phone_count})
        if session.config:
            await send_json(ws, session.config)

    try:
        while True:
            raw = await ws.receive_text()
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                await send_json(ws, {"type": "error", "message": "invalid json"})
                continue

            mtype = message.get("type", "")

            if role == "phone":
                # 手机 -> 加载项（扫码结果 / 表单提交）
                if mtype in ("scan", "form_submit", "status"):
                    message.setdefault("ts", None)
                    await broadcast(session.addins, message)
            else:
                # 加载项 -> 手机（表单配置、清空配置等）
                if mtype == "form_config":
                    session.config = {"type": "form_config", "fields": message.get("fields", [])}
                    await broadcast(session.phones, session.config)
                elif mtype == "clear_config":
                    session.config = None
                    await broadcast(session.phones, {"type": "clear_config"})
                elif mtype == "ping":
                    await send_json(ws, {"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        peers.discard(ws)
        log.info("disconnect role=%s token=%s (phones=%d)", role, token, len(session.phones))
        if role == "phone":
            await broadcast(session.addins, {"type": "peer_status", "phones": session.phone_count})
        # 会话空置则回收
        if not session.addins and not session.phones:
            SESSIONS.pop(token, None)


# ---------------------------------------------------------------- 浏览器测试页（极简扫码器）

SCAN_PAGE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>扫码测试页</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 0; background: #111; color: #eee; }
  header { padding: 10px 14px; background: #1d1f24; display: flex; justify-content: space-between; align-items: center; }
  #status { font-size: 13px; color: #9ad; }
  #preview { width: 100%; min-height: 260px; background: #000; display: block; }
  #log { padding: 8px 14px; font-size: 12px; max-height: 30vh; overflow: auto; }
  .item { border-bottom: 1px solid #333; padding: 4px 0; }
  input, button { font-size: 15px; padding: 8px; border-radius: 6px; border: 1px solid #444; background: #222; color: #eee; }
  #manual { padding: 10px 14px; display: flex; gap: 8px; }
  #manual input { flex: 1; }
</style>
</head>
<body>
<header><b>Scan 测试页</b><span id="status">连接中…</span></header>
<video id="preview" muted playsinline></video>
<div id="manual">
  <input id="manualInput" placeholder="或手动输入条码后发送">
  <button id="manualBtn">发送</button>
</div>
<div id="log"></div>
<script src="https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.min.js"></script>
<script>
const TOKEN = "__TOKEN__";
const ws = new WebSocket(`ws://${location.hostname}:__PORT__/ws?token=${TOKEN}&role=phone`);
const statusEl = document.getElementById("status");
const logEl = document.getElementById("log");

ws.onopen = () => { statusEl.textContent = "已连接 ✓"; sendStatus("online"); };
ws.onclose = () => { statusEl.textContent = "已断开"; };
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.type === "form_config") log("[配置] 字段: " + m.fields.map(f => f.name).join(", "));
};
function log(line) {
  const div = document.createElement("div");
  div.className = "item";
  div.textContent = new Date().toLocaleTimeString() + "  " + line;
  logEl.prepend(div);
}
function send(obj) {
  if (ws.readyState === WebSocket.OPEN) { ws.send(JSON.stringify(obj)); return true; }
  log("[错误] WebSocket 未连接"); return false;
}
function sendStatus(s) { send({ type: "status", state: s }); }
function sendScan(value) {
  if (!value) return;
  if (send({ type: "scan", value, symbology: "QR", ts: Date.now() })) log("[已发送] " + value);
}

document.getElementById("manualBtn").onclick = () => {
  const el = document.getElementById("manualInput");
  sendScan(el.value.trim()); el.value = "";
};
document.getElementById("manualInput").addEventListener("keydown", e => {
  if (e.key === "Enter") document.getElementById("manualBtn").click();
});

// 摄像头扫码（jsQR）
(async () => {
  const video = document.getElementById("preview");
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: "environment" } }
    });
    video.srcObject = stream;
    await video.play();
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    let lastValue = "", lastTime = 0;
    setInterval(() => {
      if (video.readyState !== video.HAVE_ENOUGH_DATA) return;
      canvas.width = video.videoWidth; canvas.height = video.videoHeight;
      ctx.drawImage(video, 0, 0);
      const code = jsQR(ctx.getImageData(0, 0, canvas.width, canvas.height).data, canvas.width, canvas.height);
      if (code && code.data) {
        const now = Date.now();
        // 1.2 秒内相同值去重
        if (code.data !== lastValue || now - lastTime > 1200) {
          lastValue = code.data; lastTime = now;
          sendScan(code.data);
        }
      }
    }, 250);
  } catch (e) {
    log("[提示] 摄像头不可用(" + e.message + ")，请用下方手动输入");
  }
})();
</script>
</body>
</html>"""


if __name__ == "__main__":
    main()
