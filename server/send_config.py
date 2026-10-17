"""以加载项身份向手机下发表单配置（联调用）。

用法: python send_config.py <token>
"""
import asyncio
import json
import sys

import websockets


async def main(token: str) -> None:
    uri = f"ws://127.0.0.1:8765/ws?token={token}&role=addin"
    async with websockets.connect(uri) as ws:
        await ws.recv()  # peer_status
        await ws.send(json.dumps({
            "type": "form_config",
            "fields": [{"name": "条码", "column": "A"}, {"name": "数量", "column": "B"}],
        }))
        print("[send_config] 表单配置已下发，等待 60 秒接收提交…")
        try:
            async with asyncio.timeout(60):
                async for raw in ws:
                    print("[收到]", raw)
        except TimeoutError:
            pass


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
