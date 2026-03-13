#!/usr/bin/env python3
# Copyright 2025 Firecracker 專案使用示範
# 獨立腳本：在 WSL2（或一般 Linux）中啟動 Firecracker 並透過 API 配置、啟動 microVM，用於驗證環境與二進位檔。

"""
使用方式（需先備好 kernel 與 rootfs，路徑改為實際路徑）：

  sudo python3 scripts/test_firecracker.py \\
    --firecracker-binary ./release-1.15.0-x86_64/firecracker-1.15.0-x86_64 \\
    --kernel /path/to/vmlinux-5.10.204 \\
    --rootfs /path/to/ubuntu-22.04.ext4 \\
    --socket /tmp/firecracker.socket

依賴：pip install requests requests-unixsocket
"""

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

try:
    import requests
    from requests_unixsocket import DEFAULT_SCHEME
    from requests_unixsocket.adapters import UnixAdapter
except ImportError as e:
    print("請安裝依賴: pip install requests requests-unixsocket", file=sys.stderr)
    raise SystemExit(1) from e


def main():
    parser = argparse.ArgumentParser(
        description="啟動 Firecracker，透過 API 配置並啟動 microVM，用於測試環境。"
    )
    parser.add_argument(
        "--firecracker-binary",
        required=True,
        help="Firecracker 二進位檔路徑（例如 release-1.15.0-x86_64/firecracker-1.15.0-x86_64）",
    )
    parser.add_argument(
        "--kernel",
        required=True,
        help="Guest 內核路徑（未壓縮 vmlinux）",
    )
    parser.add_argument(
        "--rootfs",
        required=True,
        help="Rootfs ext4 映像路徑",
    )
    parser.add_argument(
        "--socket",
        default="/tmp/firecracker.socket",
        help="API Unix socket 路徑（預設: /tmp/firecracker.socket）",
    )
    parser.add_argument(
        "--wait-seconds",
        type=float,
        default=3.0,
        help="InstanceStart 後等待秒數再檢查 VM 狀態（預設: 3.0）",
    )
    args = parser.parse_args()

    fc_bin = Path(args.firecracker_binary).resolve()
    kernel_path = Path(args.kernel).resolve()
    rootfs_path = Path(args.rootfs).resolve()
    socket_path = args.socket

    for name, path in [("firecracker", fc_bin), ("kernel", kernel_path), ("rootfs", rootfs_path)]:
        if not path.exists():
            print(f"錯誤: {name} 路徑不存在: {path}", file=sys.stderr)
            sys.exit(1)
    if not os.access(fc_bin, os.X_OK):
        print(f"錯誤: 無執行權限: {fc_bin}", file=sys.stderr)
        sys.exit(1)

    # 移除舊 socket
    if os.path.exists(socket_path):
        os.unlink(socket_path)

    # 啟動 Firecracker 子行程
    cmd = [str(fc_bin), "--api-sock", socket_path, "--enable-pci"]
    print("啟動 Firecracker:", " ".join(cmd))
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    try:
        # 等待 socket 出現
        for _ in range(50):
            if os.path.exists(socket_path):
                break
            time.sleep(0.1)
        else:
            print("錯誤: API socket 未出現", file=sys.stderr)
            proc.terminate()
            proc.wait(timeout=5)
            sys.exit(1)

        # 使用 Unix socket 的 HTTP Session
        session = requests.Session()
        session.mount(DEFAULT_SCHEME, UnixAdapter())
        import urllib.parse

        url_base = DEFAULT_SCHEME + urllib.parse.quote_plus(socket_path)

        def put(path: str, json_body: dict) -> None:
            r = session.put(url_base + path, json=json_body, timeout=5)
            if r.status_code not in (200, 204):
                raise RuntimeError(f"PUT {path} 失敗: {r.status_code} {r.text}")

        # 1. Logger（可選，便於除錯）
        put(
            "/logger",
            {
                "log_path": "/dev/stderr",
                "level": "Debug",
                "show_level": True,
                "show_log_origin": True,
            },
        )

        # 2. Boot source
        put(
            "/boot-source",
            {
                "kernel_image_path": str(kernel_path),
                "boot_args": "console=ttyS0 reboot=k panic=1",
            },
        )

        # 3. Rootfs
        put(
            "/drives/rootfs",
            {
                "drive_id": "rootfs",
                "path_on_host": str(rootfs_path),
                "is_root_device": True,
                "is_read_only": False,
            },
        )

        # 4. Machine config（可選，預設 1 vCPU、128 MiB）
        put(
            "/machine-config",
            {
                "vcpu_count": 1,
                "mem_size_mib": 128,
                "smt": False,
            },
        )

        # 5. 啟動 VM
        put("/actions", {"action_type": "InstanceStart"})

        time.sleep(args.wait_seconds)

        # 6. 查詢 VM 狀態（可選驗證）
        r = session.get(url_base + "/vm/config", timeout=5)
        if r.status_code == 200:
            print("VM 已啟動，/vm/config:", r.json())
        else:
            print("警告: 無法取得 /vm/config:", r.status_code, file=sys.stderr)

        print("測試完成：Firecracker 已依 API 配置並啟動 microVM。")
        return 0

    except Exception as e:
        print(f"錯誤: {e}", file=sys.stderr)
        return 1
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    sys.exit(main())
