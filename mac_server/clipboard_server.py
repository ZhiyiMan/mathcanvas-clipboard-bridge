#!/usr/bin/env python3
"""
MathCanvas Mac 本地接收服务
--------------------------------
功能：
1) 接收 iPad 通过 HTTP POST 发送的图片（/upload）
2) 将图片保存到 received_images/
3) 自动写入 Mac 系统剪贴板，便于直接 Cmd+V

仅依赖 Python 标准库，不需要额外 pip 安装。
"""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Tuple


DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8765
MAX_PAYLOAD_BYTES = 20 * 1024 * 1024  # 20MB
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_IMAGES_DIR = PROJECT_ROOT / "received_images"


def _timestamp_filename(ext: str) -> str:
    now = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    return f"mathcanvas_{now}.{ext}"


def _content_type_to_ext(content_type: str) -> str:
    lowered = (content_type or "").lower()
    if "png" in lowered:
        return "png"
    return "jpg"


def _copy_image_to_clipboard(image_path: Path) -> Tuple[bool, str]:
    """
    使用 osascript 将图片设置到系统剪贴板。
    说明：osascript 直接读取图片文件，避免引入 PyObjC 依赖，分享更容易。
    """
    image_type = "PNG picture" if image_path.suffix.lower() == ".png" else "JPEG picture"
    script = (
        f'set the clipboard to (read (POSIX file "{image_path}") as {image_type})'
    )

    try:
        subprocess.run(["osascript", "-e", script], check=True, capture_output=True, text=True)
        return True, "ok"
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        return False, stderr or f"osascript failed with code {exc.returncode}"


def _list_interface_ips() -> list[str]:
    """列出本机所有非回环 IPv4 地址（macOS ifconfig）。"""
    try:
        result = subprocess.run(["ifconfig"], capture_output=True, text=True, check=False)
    except OSError:
        return []

    ips: list[str] = []
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped.startswith("inet ") or "127.0.0.1" in stripped:
            continue
        parts = stripped.split()
        if len(parts) >= 2:
            ips.append(parts[1])
    return ips


def _is_reachable_lan_ip(ip: str) -> bool:
    """排除 VPN/代理常用的 198.18.x 以及链路本地地址。"""
    octets = ip.split(".")
    if len(octets) != 4:
        return False
    if ip.startswith("169.254."):
        return False
    if octets[0] == "198" and octets[1] == "18":
        return False
    return ip.startswith(("192.168.", "10.", "172."))


def _guess_local_ip() -> str:
    """
    猜测 iPad 应填写的局域网 IP。
    不能依赖「连 8.8.8.8 看源地址」——VPN/代理会把 198.18.x 误报成出口。
    """
    candidates = [ip for ip in _list_interface_ips() if _is_reachable_lan_ip(ip)]
    if candidates:
        def sort_key(ip: str) -> tuple[int, str]:
            if ip.startswith("192.168."):
                return (0, ip)
            if ip.startswith("10."):
                return (1, ip)
            return (2, ip)

        return sorted(candidates, key=sort_key)[0]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def _list_recommended_ips() -> list[str]:
    """返回所有可供 iPad 尝试的局域网 IP（按优先级排序）。"""
    candidates = [ip for ip in _list_interface_ips() if _is_reachable_lan_ip(ip)]

    def sort_key(ip: str) -> tuple[int, str]:
        if ip.startswith("192.168."):
            return (0, ip)
        if ip.startswith("10."):
            return (1, ip)
        return (2, ip)

    return sorted(set(candidates), key=sort_key)


class ClipboardUploadHandler(BaseHTTPRequestHandler):
    server_version = "MathCanvasClipboardServer/1.0"

    @property
    def app_server(self) -> "ClipboardHTTPServer":
        return self.server  # type: ignore[return-value]

    def _write_json(self, status_code: int, payload: dict) -> None:
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:
        if self.path == "/":
            self._write_json(
                200,
                {
                    "name": "MathCanvas Clipboard Server",
                    "status": "ok",
                    "upload_path": "/upload",
                    "images_dir": str(self.app_server.images_dir),
                },
            )
            return

        if self.path == "/health":
            self._write_json(200, {"status": "ok"})
            return

        self._write_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/upload":
            self._write_json(404, {"error": "only /upload is supported"})
            return

        content_length_raw = self.headers.get("Content-Length")
        if not content_length_raw:
            self._write_json(411, {"error": "missing Content-Length"})
            return

        try:
            content_length = int(content_length_raw)
        except ValueError:
            self._write_json(400, {"error": "invalid Content-Length"})
            return

        if content_length <= 0:
            self._write_json(400, {"error": "empty request body"})
            return

        if content_length > MAX_PAYLOAD_BYTES:
            self._write_json(413, {"error": f"payload too large, max {MAX_PAYLOAD_BYTES} bytes"})
            return

        body = self.rfile.read(content_length)
        if len(body) != content_length:
            self._write_json(400, {"error": "incomplete request body"})
            return

        content_type = self.headers.get("Content-Type", "")
        ext = _content_type_to_ext(content_type)
        filename = _timestamp_filename(ext)
        self.app_server.images_dir.mkdir(parents=True, exist_ok=True)
        save_path = self.app_server.images_dir / filename
        save_path.write_bytes(body)

        copied = False
        clipboard_message = "disabled"
        if self.app_server.enable_clipboard:
            copied, clipboard_message = _copy_image_to_clipboard(save_path)

        print(
            f"[UPLOAD] saved={save_path} size={len(body)}B "
            f"clipboard={'ok' if copied else clipboard_message}"
        )

        self._write_json(
            200,
            {
                "ok": True,
                "saved_path": str(save_path),
                "bytes": len(body),
                "clipboard_copied": copied,
                "clipboard_message": clipboard_message,
            },
        )

    def log_message(self, format: str, *args) -> None:
        # 精简默认日志格式，保留核心信息
        print(f"[HTTP] {self.address_string()} - {format % args}")


class ClipboardHTTPServer(ThreadingHTTPServer):
    def __init__(self, server_address, handler_class, images_dir: Path, enable_clipboard: bool):
        super().__init__(server_address, handler_class)
        self.images_dir = images_dir
        self.enable_clipboard = enable_clipboard


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="MathCanvas clipboard HTTP server")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"listen host (default: {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"listen port (default: {DEFAULT_PORT})")
    parser.add_argument(
        "--images-dir",
        default=str(DEFAULT_IMAGES_DIR),
        help=f"directory for received images (default: {DEFAULT_IMAGES_DIR})",
    )
    parser.add_argument(
        "--no-clipboard",
        action="store_true",
        help="save image only, do not copy to macOS clipboard",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    images_dir = Path(args.images_dir).expanduser().resolve()
    enable_clipboard = not args.no_clipboard

    server = ClipboardHTTPServer(
        (args.host, args.port),
        ClipboardUploadHandler,
        images_dir=images_dir,
        enable_clipboard=enable_clipboard,
    )

    local_ip = _guess_local_ip()
    all_ips = _list_recommended_ips()
    print("==============================================")
    print(" MathCanvas Clipboard Server 已启动")
    print("==============================================")
    print(f"监听地址: {args.host}:{args.port}")
    print(f"推荐 iPad 地址: http://{local_ip}:{args.port}/upload")
    if len(all_ips) > 1:
        print("其他可用地址（iPad 与 Mac 须在同一网段时选对应 IP）：")
        for ip in all_ips:
            if ip != local_ip:
                print(f"  http://{ip}:{args.port}/upload")
    print(f"健康检查: http://{local_ip}:{args.port}/health")
    print("提示: 若看到 198.18.x，那是 VPN/代理虚拟网卡，iPad 无法访问。")
    print(f"保存目录: {images_dir}")
    print(f"自动写剪贴板: {'开启' if enable_clipboard else '关闭'}")
    print("按 Ctrl+C 停止服务")
    print("----------------------------------------------")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n收到停止信号，正在退出...")
    finally:
        server.server_close()
        print("服务已停止。")


if __name__ == "__main__":
    main()
