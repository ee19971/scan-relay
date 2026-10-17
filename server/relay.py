"""Scan-Relay 本地服务：连接手机 App 与 Excel 加载项，同时托管加载项页面。

一键启动（推荐）:
    python relay.py
    - http://<局域网IP>:8765  手机接入（WebSocket + 浏览器扫码页）
    - https://localhost:3000  Excel 加载项页面（manifest 的 SourceLocation）

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
UI_PORT = int(os.environ.get("RELAY_UI_PORT", "3000"))
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


# ---------------------------------------------------------------- 加载项页面托管（一键启动模式）

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

    @ui.websocket("/relay/ws")
    async def relay_ws(ws: WebSocket, token: str = Query(...), role: str = Query(...)) -> None:
        await ws_endpoint(ws, token=token, role=role)

    @ui.get("/")
    async def index() -> RedirectResponse:
        return RedirectResponse("/taskpane.html")

    if ADDIN_DIST.is_dir():
        ui.mount("/", StaticFiles(directory=str(ADDIN_DIST), html=True), name="addin")
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
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        log.info("证书已加入当前用户受信根目录")
    else:
        log.warning("证书自动安装失败（%s），Excel 可能提示证书错误", result.stderr.strip())
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
    """一键启动：手机接入 API(8765) + 加载项页面 HTTPS(3000)。"""
    import uvicorn

    if not ADDIN_DIST.is_dir():
        log.error("未找到 %s，请先在 addin/ 目录执行: npm install && npm run build", ADDIN_DIST)
        return
    busy = [p for p in (PORT, UI_PORT) if _port_busy(p)]
    if busy:
        log.error(
            "端口 %s 已被占用。若之前开着 npm start 开发服务器，请先关闭它；"
            "若中转服务已在运行则无需重复启动。", busy,
        )
        return

    cert = find_dev_cert()
    if cert is None:
        cert = ensure_selfsigned_cert()

    lan_ip = detect_lan_ip()
    banner = f"""
============================================================
  Scan-Relay 服务已启动
------------------------------------------------------------
  Excel 加载项页面 : https://localhost:{UI_PORT}/taskpane.html
  手机接入地址     : ws://{lan_ip}:{PORT}/ws
  浏览器扫码测试页 : http://{lan_ip}:{PORT}/scan?token=<token>
  关闭本窗口即停止服务
============================================================"""
    print(banner)

    servers = [
        uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=PORT, log_level="warning")),
        uvicorn.Server(uvicorn.Config(
            create_ui_app(), host="0.0.0.0", port=UI_PORT,
            ssl_certfile=str(cert[0]), ssl_keyfile=str(cert[1]), log_level="warning",
        )),
    ]
    threads = [threading.Thread(target=s.run, daemon=True) for s in servers]
    for t in threads:
        t.start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("\n已停止")


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
