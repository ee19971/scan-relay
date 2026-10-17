"""链路测试：模拟 加载项 + 手机端，验证配对与消息转发。

用法: python test_relay.py
"""
import asyncio
import json
import sys

import httpx
import websockets

BASE = "http://127.0.0.1:8765"
WS = "ws://127.0.0.1:8765/ws"


async def main() -> int:
    # 1. 配对
    async with httpx.AsyncClient() as client:
        r = await client.get(f"{BASE}/pair")
        info = r.json()
    token = info["token"]
    assert token and info["ws_url"].startswith("ws://"), info
    print(f"[1] 配对 OK, token={token}, ws_url={info['ws_url']}")

    # 2. 加载项连接
    addin = await websockets.connect(f"{WS}?token={token}&role=addin")
    msg = json.loads(await addin.recv())
    assert msg == {"type": "peer_status", "phones": 0}, msg
    print(f"[2] addin 连接 OK, 收到 {msg}")

    # 3. 手机连接 -> addin 应收到 phones=1 + 手机应收到最新配置(None 则不发)
    phone = await websockets.connect(f"{WS}?token={token}&role=phone")
    msg = json.loads(await addin.recv())
    assert msg == {"type": "peer_status", "phones": 1}, msg
    print(f"[3] phone 上线通知 OK: {msg}")

    # 4. addin 下发表单配置 -> phone 收到
    await addin.send(json.dumps({"type": "form_config", "fields": [
        {"name": "条码", "column": "A"}, {"name": "数量", "column": "B"}
    ]}))
    msg = json.loads(await phone.recv())
    assert msg["type"] == "form_config" and len(msg["fields"]) == 2, msg
    print(f"[4] form_config 下发 OK: {msg}")

    # 5. 手机发送扫码 -> addin 收到
    await phone.send(json.dumps({"type": "scan", "value": "6901234567890", "symbology": "QR", "ts": 1}))
    msg = json.loads(await addin.recv())
    assert msg["type"] == "scan" and msg["value"] == "6901234567890", msg
    print(f"[5] scan 转发 OK: {msg}")

    # 6. 手机提交表单 -> addin 收到
    await phone.send(json.dumps({"type": "form_submit", "fields": {"条码": "690123", "数量": "5"}, "ts": 2}))
    msg = json.loads(await addin.recv())
    assert msg["type"] == "form_submit" and msg["fields"]["数量"] == "5", msg
    print(f"[6] form_submit 转发 OK: {msg}")

    # 7. 手机断开 -> addin 收到 phones=0；新手机连接应补发配置
    await phone.close()
    msg = json.loads(await addin.recv())
    assert msg == {"type": "peer_status", "phones": 0}, msg
    print(f"[7] phone 下线通知 OK: {msg}")

    phone2 = await websockets.connect(f"{WS}?token={token}&role=phone")
    msg = json.loads(await phone2.recv())
    assert msg["type"] == "form_config", msg
    print(f"[8] 新手机自动补发配置 OK")
    await phone2.close()
    await addin.close()

    # 9. 空会话回收
    await asyncio.sleep(0.3)
    async with httpx.AsyncClient() as client:
        r = await client.get(f"{BASE}/")
        assert r.json()["sessions"] == 0, r.json()
    print("[9] 空会话回收 OK")
    print("\n全部通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
