# Firecracker + OpenCode microVM 平台

Ubuntu 24.04 (noble) base rootfs + OpenCode API server，在 Firecracker microVM 上量測啟動時間與驗證 skills。

## 快速參考

| 目的 | 指令／文件 |
|------|------------|
| 產生 rootfs | `sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 12` |
| 啟動 VM 並量測 opencode 啟動時間 | `sudo ./scripts/run-noble-vm-with-opencode.sh [--kernel ...] [--rootfs ...] [--vm-id <id>]` |
| 打包 skills 成 RO 映像 | `sudo ./scripts/package-ro-skills.sh` → `bin/ro-skills.ext4` |
| 驗證 RO skills 映像內容 | `./scripts/test-ro-skills.sh [--image bin/ro-skills.ext4]` |
| 啟動 VM 並掛載 RO skills | 同上 run 腳本加 `--ro-skills bin/ro-skills.ext4` |
| 驗證 microVM（SSH shell） | rootfs 用 `--enable-ssh` 重建後，`./scripts/attach-microvm-shell.sh` |
| 前置條件與錯誤處理 | [docs/RUN-VM-PREREQUISITES-AND-VERIFY.md](docs/RUN-VM-PREREQUISITES-AND-VERIFY.md) |
| Session 記憶與設計 | [docs/260316-MEMORY.md](docs/260316-MEMORY.md) |

## 前置需求

- Linux host、KVM（`/dev/kvm`）
- Kernel（如 `bin/vmlinux.bin`）、Firecracker 二進位（如 `bin/firecracker`）
- 首次需先執行 prepare 產生 rootfs

## microVM 外網（NAT）

- `run-noble-vm-with-opencode.sh` / `attach-microvm-shell.sh` **預設會自動在 host 設置 NAT/forward（iptables）**，讓 microVM 可以連外抓取 `models.dev` 等資源。
- 若你不希望腳本動到 iptables，可加 `--no-nat` 關閉。

### 驗證

在 VM 內：

```bash
curl -I --max-time 3 https://models.dev
opencode --version
```
