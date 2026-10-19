"""内嵌 Python 运行时自检。

不要满足于 `import fastapi` 这种点到为止的检查——把 relay.py / tray.py 真正会走到的
路径全跑一遍。尤其是 cryptography 的 x509 那条链：relay.py 是 lazy import 它来生成
localhost 证书的，漏掉任何一环，新机器上第一次启动就会崩在证书生成这一步，
而开发机因为 ~/.office-addin-dev-certs 已存在走短路，永远不会暴露。

用法：用**内嵌运行时**的解释器跑本文件，例如
    dist\\standalone\\python\\python.exe packaging\\smoke.py
"""
from __future__ import annotations

import importlib
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# 让 `import relay` / `import tray` 能找到仓库里的源码：
# 自检跑的是「内嵌解释器 + 仓库源码」，站点包则来自内嵌目录的 site-packages。
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))

FAILS: list[str] = []


def probe(label: str, fn) -> None:
    try:
        fn()
    except Exception as exc:  # noqa: BLE001
        FAILS.append(label)
        print(f"  FAIL  {label}: {type(exc).__name__}: {exc}")
    else:
        print(f"  ok    {label}")


def _crypto_x509_chain() -> None:
    """完整复刻 relay.py 的证书生成路径，而不只是 import 成功。"""
    import ipaddress

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

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
                x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")),
            ]),
            critical=False,
        )
        .sign(private_key, hashes.SHA256())
    )
    pem = cert.public_bytes(serialization.Encoding.PEM)
    assert pem.startswith(b"-----BEGIN CERTIFICATE-----")
    # 指纹：卸载器据此从用户根证书存储里清掉它
    assert len(cert.fingerprint(hashes.SHA1())) == 20


def _pystray_needs_pillow() -> None:
    """pystray 的 win32 后端在 import 时就要求 PIL，缺了会直接 ImportError。"""
    from PIL import Image  # noqa: F401
    import pystray  # noqa: F401

    assert hasattr(pystray.Icon, "notify")


def main() -> int:
    print("== interpreter ==")
    print(f"  {sys.version}")
    print(f"  exe = {sys.executable}")
    print("  sys.path (tail):")
    for p in sys.path[-3:]:
        print(f"    {p}")

    print("\n== server stack (server/relay.py) ==")
    probe("relay.py 模块导入", lambda: importlib.import_module("relay"))
    probe("fastapi / starlette", lambda: (importlib.import_module("fastapi"),
                                          importlib.import_module("starlette")))
    probe("pydantic + core", lambda: importlib.import_module("pydantic").VERSION)
    probe("uvicorn + websockets", lambda: (importlib.import_module("uvicorn"),
                                           importlib.import_module("websockets")))
    probe("cryptography x509 证书链", _crypto_x509_chain)

    print("\n== tray stack (server/tray.py) ==")
    probe("tray.py 模块导入", lambda: importlib.import_module("tray"))
    probe("pystray（依赖 PIL）", _pystray_needs_pillow)
    probe("winotify", lambda: importlib.import_module("winotify"))

    print()
    if FAILS:
        print(f"FAILED ({len(FAILS)}): {', '.join(FAILS)}")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
