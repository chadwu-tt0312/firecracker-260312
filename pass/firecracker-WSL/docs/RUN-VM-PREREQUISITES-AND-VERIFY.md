# 執行 run-noble-vm-with-opencode.sh 之前提與驗證

> **文件範圍：** 本文件是**操作指南**，聚焦於「如何用現有腳本跑起單一 Firecracker VM 並驗證其正常運作」。
> 包含前置條件、執行步驟、常見錯誤排除、驗證方式。
>
> 若需了解多租戶平台的**架構設計**（warm pool、雙層資源、磁碟策略、帳號管理、OpenCode API Server），
> 請參閱 [IMPLEMENTATION-PLAN-OPENCODE-VM.md](./IMPLEMENTATION-PLAN-OPENCODE-VM.md)。

## 1. 前置條件一覽

| 項目 | 說明 | 若缺少時處理方式 |
|------|------|------------------|
| **root 權限** | 建立 TAP、存取 /dev/kvm | 必須使用 `sudo ./scripts/run-noble-vm-with-opencode.sh ...` |
| **KVM** | `/dev/kvm` 存在且可存取 | 確認主機支援虛擬化、未在容器內無 KVM 時無法跑 |
| **Kernel** | 預設 `bin/vmlinux.bin` | 可從 [Firecracker quickstart](https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md) 取得，或使用專案既有 kernel |
| **Rootfs** | 預設 `bin/ubuntu-noble-base.rootfs.ext4` | 先執行：`sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 12` |
| **Firecracker 二進位** | 預設 `bin/firecracker` 或 PATH | 下載並放到 `bin/firecracker` 或安裝到系統 PATH |

## 2. 建議執行順序（首次）

```bash
# 從專案根目錄執行
cd /path/to/firecracker-260312

# 1) 產生 rootfs（若尚未產生）
sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 12

# 2) 若有 kernel（例如 bin/vmlinux.bin）即可啟動 VM
sudo ./scripts/run-noble-vm-with-opencode.sh --vm-id noble-test-1
```

## 3. 常見錯誤與對應處理

| 錯誤訊息／現象 | 可能原因 | 處理方式 |
|----------------|----------|----------|
| 找不到 kernel | `bin/vmlinux.bin` 不存在 | 指定現有 kernel：`--kernel /path/to/vmlinux.bin`，或從 Firecracker 文件下載 |
| 找不到 rootfs | 尚未執行 prepare | 執行 `sudo ./scripts/prepare-ubuntu-noble-rootfs.sh ...` 產生 rootfs |
| 找不到 firecracker 二進位 | bin/firecracker 不存在且 PATH 無 | 下載 Firecracker release，將二進位放到 `bin/firecracker` 或設定 `FC_BINARY` |
| /dev/kvm 不存在 | 主機不支援或未載入 KVM 模組 | 確認 CPU 虛擬化、載入 `kvm` 模組；若在容器內則需 privileged 或透傳 /dev/kvm |
| 在 TIMEOUT 內未等到 opencode serve | guest 網路未通或 opencode 未啟動 | 見下方「暫留問題」：確認 rootfs 為 prepare 後含 netplan 靜態 IP 與 wait-online 逾時之版本；必要時重建 rootfs |
| API socket 未建立 | Firecracker 啟動失敗 | 查看 `$WORK_DIR/fc.log`（預設 `/tmp/fc-<vm-id>/fc.log`） |

## 4. 驗證 microVM（attach shell）

- **方式一：SSH（建議）**  
  - 先讓 rootfs 具備 SSH：prepare 時加 `--enable-ssh` 重建 rootfs。  
  - 啟動 VM 後在另一終端執行：  
    `./scripts/attach-microvm-shell.sh`  
  - 預設連線為 `root@172.30.0.2`，密碼為 `opencode`（僅限開發/測試用）。

- **方式二：Serial 輸出**  
  - Guest 的 kernel/console 輸出寫入 Firecracker 的 log。  
  - 查看：`tail -f /tmp/fc-<vm-id>/fc.log`。  
  - 無互動式 shell，僅能觀察開機與服務日誌。

## 5. 自動修復的邊界

- **腳本可自動處理的**：無（目前不包含「缺檔就自動下載」邏輯）。  
- **需你事先準備或手動修復的**：  
  - 缺少 kernel/rootfs/firecracker → 依上表取得或產生後再執行。  
  - 開機卡在 network-online → 使用**已含 Step 8b/8d** 的 `prepare-ubuntu-noble-rootfs.sh` 重建 rootfs（見 `docs/260316-MEMORY.md` 暫留問題說明）。  
- **若希望「一鍵跑到底」**：可自行寫一層 wrapper 依序檢查 kernel、rootfs、firecracker 是否存在，缺則下載/執行 prepare，再呼叫 `run-noble-vm-with-opencode.sh`；失敗時解析錯誤並重試或輸出上述對應處理方式。

## 6. 你需要提供給自動化／AI 的資訊

若要由腳本或 AI 代為執行並在錯誤時反覆修復，建議提供或允許存取：

1. **專案根目錄**：腳本預設從專案根執行，路徑需一致。  
2. **Kernel 來源**：若無 `bin/vmlinux.bin`，需有可下載的 URL 或本機路徑。  
3. **sudo 權限**：run 與 prepare 皆需 root。  
4. **網路**：prepare 會下載 Ubuntu root tarball；run 時 host 與 guest 僅 172.30.0.0/24 通訊，不需外網。  
5. **錯誤日誌路徑**：`/tmp/fc-<vm-id>/fc.log` 與腳本輸出的錯誤訊息，供判斷是缺檔、KVM、還是 guest 開機/網路問題。

## 7. 由 AI／自動化執行時

- 腳本**必須**在具 **KVM**（`/dev/kvm`）與 **sudo** 的環境執行（實機或支援嵌套虛擬化的 VM）；WSL2 預設無 KVM，需 WSL2 內建或外層 Linux 實機。
- **無法在目前環境代你「跑完」**：若 Cursor/Agent 所在環境沒有 sudo 或 /dev/kvm，只能做到檢查參數、產出/修改腳本與文件，無法實際啟動 Firecracker。
- **你可做的**：在本機（有 KVM + sudo）依「建議執行順序」執行；若希望「一鍵＋自動修復」，可自寫 wrapper：先檢查 `bin/vmlinux.bin`、`bin/ubuntu-noble-base.rootfs.ext4`、`bin/firecracker` 是否存在，缺則下載或執行 prepare，再呼叫 `run-noble-vm-with-opencode.sh`，並根據錯誤訊息重試或輸出上表對應處理方式。
