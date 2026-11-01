#!/usr/bin/env python3
"""把 /var/run/usbmuxd 这个 unix socket 桥接到 Windows 侧的 usbmuxd TCP 端口。

为什么需要它：

- WSL 自带的 usbmuxd 看不到 USB 设备（没有 USB 直通），它在 /var/run/usbmuxd
  上占着 unix socket，但里面永远是空的。
- 手机真正的 usbmuxd 在 Windows 上，只绑 127.0.0.1:27015，由一条 portproxy
  转发到 WSL 能访问的 27016。
- xtool 经由 libusbmuxd 只连 unix socket，不认 TCP 地址（USBMUXD_SOCKET_ADDRESS
  对 pymobiledevice3 有效，对它无效）。

所以在 unix socket 上架一个双向转发，两边就接上了。

由 Tools/fix-device-link.sh 负责启动（需要先停掉 WSL 自带的 usbmuxd）。
"""
import os
import socket
import struct
import subprocess
import sys
import threading

SOCKET_PATH = os.environ.get("BRIDGE_SOCKET_PATH", "/var/run/usbmuxd")
CONNECT_TIMEOUT = 10


def gateway():
    out = subprocess.run(
        ["ip", "route", "show", "default"], capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        parts = line.split()
        if "via" in parts:
            return parts[parts.index("via") + 1]
    raise SystemExit("could not determine gateway")


def log(msg):
    print(msg, flush=True)


def is_list_devices_request(data):
    """只用来在日志里标注设备枚举，不改动流量。"""
    if len(data) < 16:
        return False
    try:
        total = struct.unpack("<I", data[:4])[0]
        return b"ListDevices" in data[16:total]
    except Exception:
        return False


def pump(src, dst, label):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if label == "c->u" and is_list_devices_request(data):
                log("ListDevices ->")
            dst.sendall(data)
    except OSError as exc:
        # 客户端断开是常态（xtool 每次都新连一次），不当作错误。
        if exc.errno not in (104, 32, 107):
            log(f"{label}: {exc}")
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    try:
        upstream = socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=CONNECT_TIMEOUT)
    except OSError as exc:
        log(f"upstream connect to {TARGET_HOST}:{TARGET_PORT} failed: {exc}")
        client.close()
        return
    upstream.settimeout(None)
    threading.Thread(target=pump, args=(client, upstream, "c->u"), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client, "u->c"), daemon=True).start()


def main():
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o666)
    server.listen(64)
    log(f"bridging {SOCKET_PATH} -> {TARGET_HOST}:{TARGET_PORT}")
    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


TARGET_HOST = os.environ.get("BRIDGE_TARGET_HOST") or gateway()
TARGET_PORT = int(os.environ.get("BRIDGE_TARGET_PORT", "27016"))

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
