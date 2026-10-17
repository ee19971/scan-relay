"""假加载项：连接中转服务并打印收到的消息（用于手机端联调）。

用法: python fake_addin.py <token>
"""
import asyncio
import json
import sys

import websockets


async def main(token: str) -> None:
    uri = f"ws://127.0.0.1:8765/ws?token={token}&role=addin"
    async with websockets.connect(uri) as ws:
        print(f"[fake-addin] 已连接 token={token}，等待消息…")
        async for raw in ws:
            print("[收到]", raw)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    asyncio.run(main(sys.argv[1]))
