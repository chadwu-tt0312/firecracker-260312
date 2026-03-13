import asyncio
import json
import os
import time
from pathlib import Path

import aiohttp

# 配置參數
VM_COUNT = 100  # 先從 100 個開始，觀察穩定性再上 1000
FC_BINARY = "./firecracker"
CHROOT_BASE = Path("/tmp/firecracker-bench")
KERNEL_PATH = CHROOT_BASE / "vmlinux.bin"
ROOTFS_PATH = CHROOT_BASE / "bionic.rootfs.ext4"


class MicroVM:
    def __init__(self, vm_id):
        self.vm_id = vm_id
        self.socket_path = CHROOT_BASE / f"fc_{vm_id}.socket"
        self.results = {}

    async def setup_vm(self, session):
        start_time = time.perf_counter()

        # 1. 設定 Boot Source
        await self.api_put(
            session,
            "/boot-source",
            {
                "kernel_image_path": str(KERNEL_PATH),
                "boot_args": "console=ttyS0 reboot=k panic=1 pci=off",
            },
        )

        # 2. 設定 RootFS
        await self.api_put(
            session,
            "/drives/rootfs",
            {
                "drive_id": "rootfs",
                "path_on_host": str(ROOTFS_PATH),
                "is_root_device": True,
                "is_read_only": False,
            },
        )

        # 3. 啟動 VM (這一步是關鍵計時點)
        launch_start = time.perf_counter()
        await self.api_put(session, "/actions", {"action_type": "InstanceStart"})
        self.results["launch_duration_ms"] = (time.perf_counter() - launch_start) * 1000
        self.results["total_setup_ms"] = (time.perf_counter() - start_time) * 1000

    async def api_put(self, session, path, data):
        # 使用 Unix Domain Socket 進行通信
        connector = aiohttp.UnixConnector(path=str(self.socket_path))
        async with aiohttp.ClientSession(connector=connector) as s:
            async with s.put(f"http://localhost{path}", json=data) as resp:
                return await resp.text()


async def run_benchmark():
    print(f"🚀 開始併發啟動 {VM_COUNT} 個 MicroVM...")
    # 這裡應包含啟動 Firecracker 進程的代碼 (subprocess.Popen)
    # 為了簡潔，假設進程已預先啟動

    tasks = []
    # 這裡展現頂尖人士的「批量噴射」思路
    for i in range(VM_COUNT):
        vm = MicroVM(i)
        tasks.append(vm.setup_vm(None))

    start_all = time.perf_counter()
    await asyncio.gather(*tasks)
    end_all = time.perf_counter()

    print(f"✅ 完成！總耗時: {end_all - start_all:.2f} 秒")
    print(f"平均每個 VM 啟動延遲: {(end_all - start_all) / VM_COUNT * 1000:.2f} ms")


if __name__ == "__main__":
    # 提醒：執行前請確保 /tmp/firecracker-bench 已掛載為 tmpfs
    asyncio.run(run_benchmark())
