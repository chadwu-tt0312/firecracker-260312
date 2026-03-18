import asyncio
import argparse
import os
import shutil
import statistics
import subprocess
import time
from pathlib import Path

import aiohttp
import psutil

# 執行時產生的 socket / logs 會放在 /tmp/firecracker-bench（建議掛 tmpfs 提升效能）
# sudo mkdir -p /tmp/firecracker-bench
# sudo mount -t tmpfs -o size=4G tmpfs /tmp/firecracker-bench


# --- 實驗室配置 (Industrial Standard Configuration) ---
VM_COUNT = 50  # 初始測試建議 50，隨後挑戰 1000
BASE_DIR = Path("/tmp/firecracker-bench")
REPO_ROOT = Path(__file__).resolve().parents[1]
BIN_DIR = REPO_ROOT / "bin"
# 優先：環境變數 FC_BINARY → PATH 中的 firecracker → 當前目錄 ../bin/firecracker
FC_BINARY = os.environ.get("FC_BINARY") or shutil.which("firecracker") or "../bin/firecracker"
FC_BINARY = Path(FC_BINARY).resolve() if FC_BINARY else None
# Kernel / RootFS：預設使用 bin/；可透過 CLI 或環境變數覆蓋
KERNEL: Path | None = None
ROOTFS: Path | None = None
LOG_DIR = BASE_DIR / "logs"
STARTUP_TIMEOUT_SECONDS = 5
SHUTDOWN_TIMEOUT_SECONDS = 3


class FirecrackerInstance:
    def __init__(self, vm_id):
        self.vm_id = vm_id
        self.socket_path = BASE_DIR / f"fc_{vm_id}.socket"
        self.log_path = LOG_DIR / f"fc_{vm_id}.log"
        self.process = None
        self.metrics = {}
        self.failed = False
        self.error_message = None

    async def start_process(self):
        """啟動 Firecracker 守護進程 [cite: 1]"""
        if self.socket_path.exists():
            self.socket_path.unlink()

        # 頂尖思維：使用 taskset 進行 CPU 綁定，減少 Context Switch 噪聲
        # 這裡簡單示範啟動命令
        cmd = [str(FC_BINARY), "--api-sock", str(self.socket_path), "--id", str(self.vm_id)]
        log_file = self.log_path.open("wb")
        self.process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=log_file)
        log_file.close()

        # 避免 Firecracker 啟動失敗時無限等待 socket。
        deadline = time.perf_counter() + STARTUP_TIMEOUT_SECONDS
        while time.perf_counter() < deadline:
            if self.socket_path.exists():
                return
            if self.process.poll() is not None:
                raise RuntimeError(
                    f"VM {self.vm_id} 啟動失敗，Firecracker 提前退出，請檢查 log: {self.log_path}"
                )
            await asyncio.sleep(0.01)

        raise TimeoutError(
            f"VM {self.vm_id} 在 {STARTUP_TIMEOUT_SECONDS}s 內未建立 API socket: {self.socket_path}"
        )

    async def configure_and_run(self):
        """執行 API 配置流程"""
        start_ts = time.perf_counter()

        # 1. 配置內核 (Boot Source)
        await self.api_put(
            "/boot-source",
            {
                "kernel_image_path": str(KERNEL),
                "boot_args": "console=ttyS0 reboot=k panic=1 pci=off",
            },
        )

        # 2. 配置磁碟 (RootFS)
        await self.api_put(
            "/drives/rootfs",
            {
                "drive_id": "rootfs",
                "path_on_host": str(ROOTFS),
                "is_root_device": True,
                "is_read_only": True,  # 唯讀模式效能更佳
            },
        )

        # 3. 發射 (Launch)
        launch_ts = time.perf_counter()
        await self.api_put("/actions", {"action_type": "InstanceStart"})

        self.metrics["api_latency_ms"] = (launch_ts - start_ts) * 1000
        self.metrics["boot_command_ms"] = (time.perf_counter() - launch_ts) * 1000

    async def api_put(self, path, data):
        connector = aiohttp.UnixConnector(path=str(self.socket_path))
        async with aiohttp.ClientSession(connector=connector) as s:
            async with s.put(f"http://localhost{path}", json=data) as resp:
                if resp.status != 204:
                    body = await resp.text()
                    raise RuntimeError(
                        f"VM {self.vm_id} API {path} 失敗，status={resp.status}, body={body}"
                    )

    def stop(self):
        if self.process:
            if self.process.poll() is not None:
                return
            try:
                self.process.terminate()
                self.process.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)
            except ProcessLookupError:
                return
            except subprocess.TimeoutExpired:
                try:
                    self.process.kill()
                    self.process.wait()
                except ProcessLookupError:
                    return


def _check_firecracker_binary():
    """確認 firecracker 二進位檔存在且可執行，否則拋出明確錯誤。"""
    if not FC_BINARY:
        raise SystemExit(
            "找不到 firecracker 二進位檔。請：\n"
            "  1) 安裝並將 firecracker 加入 PATH，或\n"
            "  2) 設定環境變數：export FC_BINARY=/path/to/firecracker"
        )
    path = Path(FC_BINARY)
    if not path.exists():
        raise SystemExit(
            f"firecracker 二進位檔不存在：{FC_BINARY}\n"
            "請安裝或下載後設定 FC_BINARY，或將可執行檔放在 PATH 中或當前目錄並命名為 firecracker。"
        )
    if not os.access(path, os.X_OK):
        raise SystemExit(f"firecracker 不可執行：{FC_BINARY}")


def _check_kvm_access():
    """確認 /dev/kvm 存在且當前使用者有存取權限。"""
    kvm = Path("/dev/kvm")
    if not kvm.exists():
        raise SystemExit(
            "/dev/kvm 不存在。Firecracker 需要 KVM 才能執行。\n"
            "  - 若在 WSL2：WSL2 不支援 nested virtualization，請改在原生 Linux 環境執行。\n"
            "  - 若在實體機：請確認已載入 kvm 模組（modprobe kvm_intel 或 kvm_amd）。"
        )
    if not os.access(kvm, os.R_OK | os.W_OK):
        raise SystemExit(
            "無權限存取 /dev/kvm。請將當前使用者加入 kvm 群組：\n"
            "  sudo usermod -aG kvm $USER\n"
            "  登出後重新登入使群組變更生效。"
        )


def _check_kernel_rootfs(kernel: Path, rootfs: Path):
    """確認 kernel 與 rootfs 檔案存在，否則拋出明確錯誤。"""
    missing = []
    if not kernel.exists():
        missing.append(f"  kernel: {kernel}")
    if not rootfs.exists():
        missing.append(f"  rootfs: {rootfs}")
    if missing:
        raise SystemExit(
            "找不到以下檔案，無法啟動 MicroVM：\n" + "\n".join(missing) + "\n\n請先準備：\n"
            "  1) 將 kernel/rootfs 放到 "
            + str(BIN_DIR)
            + "（預設檔名：vmlinux.bin、bionic.rootfs.ext4），或\n"
            "  2) 使用 CLI 參數：--kernel/--rootfs 或 --rootfs-preset，或\n"
            "  3) 設定環境變數：export KERNEL_PATH=/path/to/vmlinux.bin ROOTFS_PATH=/path/to/rootfs.ext4"
        )


def _get_process_rss_bytes(process):
    """讀取單一 process 的 RSS；若 process 已消失則回傳 0。"""
    if not process or process.poll() is not None:
        return 0

    try:
        return psutil.Process(process.pid).memory_info().rss
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return 0


def _parse_args():
    p = argparse.ArgumentParser(description="Firecracker microVM startup benchmark")
    p.add_argument("--vm-count", type=int, default=VM_COUNT, help="要啟動的 VM 數量")
    p.add_argument(
        "--kernel",
        type=Path,
        default=None,
        help="Kernel image path（優先於 KERNEL_PATH 與預設值）",
    )
    p.add_argument(
        "--rootfs",
        type=Path,
        default=None,
        help="RootFS image path（優先於 ROOTFS_PATH 與預設值）",
    )
    p.add_argument(
        "--rootfs-preset",
        choices=["bionic", "noble"],
        default="bionic",
        help="RootFS 快速選擇（未指定 --rootfs 時生效）",
    )
    return p.parse_args()


def _resolve_paths(args):
    kernel = args.kernel or (
        Path(os.environ["KERNEL_PATH"]) if os.environ.get("KERNEL_PATH") else (BIN_DIR / "vmlinux.bin")
    )
    if args.rootfs:
        rootfs = args.rootfs
    elif os.environ.get("ROOTFS_PATH"):
        rootfs = Path(os.environ["ROOTFS_PATH"])
    else:
        if args.rootfs_preset == "noble":
            rootfs = BIN_DIR / "ubuntu-noble-base.rootfs.ext4"
        else:
            rootfs = BIN_DIR / "bionic.rootfs.ext4"

    return kernel.expanduser().resolve(), rootfs.expanduser().resolve()


async def run_benchmark():
    global VM_COUNT, KERNEL, ROOTFS
    args = _parse_args()
    VM_COUNT = args.vm_count
    KERNEL, ROOTFS = _resolve_paths(args)

    _check_firecracker_binary()
    _check_kernel_rootfs(KERNEL, ROOTFS)
    _check_kvm_access()
    # --- Step 1: 環境預熱與清理（只清 socket/log，保留 kernel 與 rootfs）---
    print("🧹 初始化 tmpfs 環境...")
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    for p in BASE_DIR.glob("fc_*.socket"):
        p.unlink(missing_ok=True)
    for p in LOG_DIR.glob("fc_*.log"):
        p.unlink(missing_ok=True)

    print("🔎 使用設定：")
    print(f"  firecracker: {FC_BINARY}")
    print(f"  kernel:     {KERNEL}")
    print(f"  rootfs:     {ROOTFS}")
    print(f"🚀 正在併發啟動 {VM_COUNT} 個 MicroVM...")

    instances = [FirecrackerInstance(i) for i in range(VM_COUNT)]
    start_bench = None
    end_bench = None
    fatal_error_message = None

    try:
        # --- Step 2: 批量啟動進程 ---
        startup_results = await asyncio.gather(
            *(inst.start_process() for inst in instances), return_exceptions=True
        )
        for inst, result in zip(instances, startup_results):
            if isinstance(result, Exception):
                inst.failed = True
                inst.error_message = str(result)

        runnable_instances = [inst for inst in instances if not inst.failed]
        if not runnable_instances:
            fatal_error_message = "所有 Firecracker instance 都啟動失敗，請檢查 logs。"
        else:
            # --- Step 3: 批量 API 配置 (核心測試段) ---
            start_bench = time.perf_counter()
            run_results = await asyncio.gather(
                *(inst.configure_and_run() for inst in runnable_instances),
                return_exceptions=True,
            )
            end_bench = time.perf_counter()

            for inst, result in zip(runnable_instances, run_results):
                if isinstance(result, Exception):
                    inst.failed = True
                    inst.error_message = str(result)

        successful_instances = [
            inst for inst in instances if not inst.failed and "boot_command_ms" in inst.metrics
        ]

        # --- Step 4: 資源觀測 (RSS 記憶體) ---
        total_rss = sum(_get_process_rss_bytes(inst.process) for inst in successful_instances)

        # --- Step 5: 數據分析 ---
        failures = [inst for inst in instances if inst.failed]
        print("\n" + "=" * 40)
        if start_bench is not None and end_bench is not None:
            print(f"📊 測試結果 (總耗時: {end_bench - start_bench:.4f}s)")
        print(f"成功啟動 VM 數量: {len(successful_instances)} / {VM_COUNT}")
        print(f"失敗 VM 數量: {len(failures)}")
        if successful_instances:
            latencies = [inst.metrics["boot_command_ms"] for inst in successful_instances]
            print(f"平均啟動指令延遲: {statistics.mean(latencies):.2f} ms")
            if len(latencies) >= 2:
                print(f"P99 延遲: {statistics.quantiles(latencies, n=100)[98]:.2f} ms")
            else:
                print(f"P99 延遲: {latencies[0]:.2f} ms")
            print(f"總記憶體佔用 (RSS): {total_rss / 1024 / 1024:.2f} MB")
            print(
                f"每個 VM 平均開銷: {(total_rss / len(successful_instances)) / 1024 / 1024:.2f} MB"
            )
        if failures:
            print("失敗摘要:")
            for inst in failures[:5]:
                print(f"  VM {inst.vm_id}: {inst.error_message}")
            if len(failures) > 5:
                print(f"  ... 其餘 {len(failures) - 5} 個失敗請查看 logs。")
        print("=" * 40)
        if runnable_instances and not successful_instances and not fatal_error_message:
            fatal_error_message = "所有 Firecracker instance 都在 API 配置或啟動階段失敗。"
        if fatal_error_message:
            raise SystemExit(fatal_error_message)
    finally:
        # --- Step 6: 優雅清理 ---
        for inst in instances:
            inst.stop()
        print("✅ 測試完成，環境已清理。")


if __name__ == "__main__":
    # 注意：請確保 firecracker 可從 PATH 或 FC_BINARY 找到
    asyncio.run(run_benchmark())
