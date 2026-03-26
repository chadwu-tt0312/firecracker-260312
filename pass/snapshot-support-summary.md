# Firecracker Snapshotting：文件重點總結（snapshot-support.md）

來源：[`docs/snapshotting/snapshot-support.md`](https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/docs/snapshotting/snapshot-support.md)

---

## 1. 什麼是 microVM snapshotting？

Firecracker 的 microVM snapshotting 是一種把「正在執行中的 microVM 及其資源」序列化並保存成外部檔案（snapshot）的機制；之後可以用這份 snapshot 在**另一個 Firecracker 行程**中還原並恢復先前的 guest 工作負載。

重點概念：
- Snapshot 不是「乾淨開機」而是「從某個時間點繼續執行」。
- Snapshot 會產生多個檔案：包含 guest memory、microVM 狀態、以及（由使用者管理的）磁碟檔等。
- 原先建立 snapshot 的 microVM 在 resume 前，通常會感受到的副作用主要是 snapshot 建立的延遲；以及 vsock/網路行為在跨行程 resume 時可能會不一致。

---

## 2. snapshot 恢復的基本效果與限制

文件指出，從 snapshot resume 後可能出現以下特性（尤其是跨不同 Firecracker 行程）：
- **網路（network）封包遺失**：可能發生封包 loss。
- **vsock 封包狀態**：snapshot resume 會關閉在 snapshot 時已開啟的 vsock 連線；但 guest 內已有的 vsock listen socket 仍可能在 resume 後繼續接受新連線。
- **網路連線狀態不保證保留**：已建立的連線狀態不一定延續。

---

## 3. Snapshot 會序列化哪些東西？

Snapshot 主要保存：
- guest memory
- emulated HW state（包含 KVM 與 Firecracker emulated HW）

並在 snapshot create 時實際生成多個檔案：
- memory 檔案（由 Firecracker 產生）
- microVM state 檔案（由 Firecracker 產生）
- disk 檔案（依 guest 有幾顆 block device 而定，**由使用者管理**）

效能設計：
- Resume 時，Firecracker 對 memory file 使用 `MAP_PRIVATE` 記憶體映射，達到較快載入。
- 代價是：resumed microVM 的整段生命週期需要保留 memory file（因為依賴按需換頁）。

---

## 4. API 流程與 prerequisites（Pause / Create / Resume / Load）

Firecracker snapshot 的 API 主要包含：
- `Pause`（暫停 microVM）
- `CreateSnapshot`（建立 full 或 diff snapshot）
- `Resume`（恢復執行）
- `LoadSnapshot`（在 boot 之前載入 snapshot）

關鍵 API 生命週期限制：
- `Pause` / `CreateSnapshot` / `Resume`：都只能在 microVM 已 boot 後使用。
- `LoadSnapshot`：只能在 microVM 尚未配置/啟動前使用（允許的配置資源限制在 logger/metrics）。

### 4.1 暫停（Pausing the microVM）
- 透過 `PATCH /vm` 將 `"state": "Paused"`。
- Success 時 microVM 保證停在 `Paused`。
- Failure 時不應產生副作用。

### 4.2 建立快照（Creating snapshots）
創建之前：microVM 必須已 `Paused`。

snapshot_type：
- `Full`：保證包含可 resume 的完整 microVM state 與 memory。
- `Diff`：在技術上會保存相對於上一個快照（full 或 diff）「之後曾被寫入/髒頁（dirty pages）」的 memory diff。

文件特別提醒：
- Diff snapshot 目前（在文件敘述的狀況下）仍處於 developer preview。
- Diff snapshot 一般**不保證可直接 resume**，常見作法是把 diff layer 合併（rebase/merge）成新的 full snapshot。
- 例外：對「已 boot 的 VM」所產生的 diff snapshots，在該情境下會被描述為可立即 resumable。

#### Diff snapshot 的兩種 dirty page 追蹤方式
1. `track_dirty_pages=true`（使用 KVM dirty page log）
   - Diff 只包含確定在期間被寫入的頁面。
   - 代價：KVM 需要追蹤髒頁，會增加 CPU cost。
2. `track_dirty_pages=false`（使用 `mincore(2)`）
   - 需要 swap disabled，因為 `mincore` 不考慮寫入到 swap 的頁面。
   - 可能導致 diff 檔比較大（雖仍可 sparse）。

#### snapshot create 成功後的效果（高層摘要）
- `snapshot_path`：保存 devices model state 與 emulation state。
- `mem_file_path`：保存 memory（Full 為完整、Diff 為 diff copy）。
- Firecracker 會產出檔案並取得當前行程的所有權（host 端仍需自行備份 block device backing 檔內容）。
- dirty page bitmap 可能會被重置/標記所有頁對追蹤角度視為 clean（依文件描述）。

### 4.3 恢復（Resuming the microVM）
- 透過 `PATCH /vm` 設 `"state": "Resumed"`。
- 前置條件：microVM 必須是 `Paused`。
- success 後保證在 `Resumed`。

### 4.4 載入快照（Loading snapshots）
- 透過 `PUT /snapshot/load` 載入。
- 前置條件：**在 microVM 尚未配置前**使用。
- 需要提供：
  - 完整的 memory snapshot 檔（microVM memory）
  - microVM state 檔
  - block device/網路（TAP backs）/vsock 等原本 microVM 所依賴的 host resources，在新行程以相同相對路徑可被存取。

`mem_backend`：
- `backend_type: "File"`：由 OS 利用 page faults 以需載入方式存取 memory file。
- `backend_type: "Uffd"`：由使用者空間（user space）處理 page faults（需透過 unix domain socket 與 Firecracker 溝通）。

載入成功後狀態：
- microVM 進入 `Paused`，接著可再 `Resume`。
- memory file 必須被視為 immutable（不允許外部修改，否則會導致 guest memory 非定義行為）。
- dirtied page bitmap 會在 diff snapshot 觀點重置。

補充：wall-clock 漂移（guest wall-clock）
- resume 後 guest 的 wall-clock 會從 snapshot 建立時刻繼續。
- 因此文件建議更新 guest 側時間以避免 drifing。

---

## 5. Snapshot 版本與兼容性

microVM state snapshot file 使用版本格式 `MAJOR.MINOR.PATCH`。
- 每個 Firecracker binary 支援固定 snapshot data format 版本。
- 建立 snapshot 時會使用該版本。
- 載入 snapshot 時會檢查版本相容性。

---

## 6. Snapshot security 與 uniqueness（避免重複使用危險狀態）

文件強調：若同一份 guest state 被 resume 多次，原本應唯一（unique）的資訊可能變得重複使用，包含：
- identifiers
- random numbers/seed
- guest OS entropy pool
- cryptographic tokens

風險本質：
- 缺乏讓「唯一性資訊在多次 resume 後仍保持唯一」的機制，因此對於安全性不做保證。

對策範例（文中示意）：
- 若 microVM A 建 snapshot 後終止，且只讓 microVM B 從 snapshot resume 一次，風險較低。
- 若 microVM A resume 後繼續做事，或多個 microVM（B、C…）都從同一 snapshot resume 並執行，則可能造成 unique state 被重複使用，風險提高。

---

## 7. VMGenID 與隨 snapshot resume 的隨機性行為

Firecracker 支援 `VMGenID` device：
- 在 resume snapshot 時，會更新 16-byte generation ID 並在 guest 注入通知。
- 對 Linux guest（特別是支援 5.18+ 的版本）可觸發重新種子（re-seed）內核 PRNG。

文件也明確指出：
- 內核 PRNG/entropy pool 可能會因 VMGenID 更新而刷新。
- 但像是「內核以外」的 unique state（快取的 random 數、token 等）仍可能被複製並重複，因此仍需使用者端去重（deduplication）機制。

---

## 8. Limitation（已知限制/注意事項）

文件列出的主要限制包含：
- cgroups v1 的情境下，snapshot restore latency 可能很高；建議使用 cgroups v2 的 host。
- guest network connectivity 在 resume 後不保證保留（需要參考 clone 的網路建議）。
- arm64 情境：snapshotting 可用於不同 GIC 版本之間的恢復不一定可行（不同 GIC version restoration 受限）。
- x86_64 上若未使用 CPU template，某些 MSR（如 `MSR_IA32_TSX_CTRL`）覆寫可能在 resume 後不保留。
- 若 snapshot 取在 guest kernel boot 很早期，resume 可能導致 crash；建議在 kernel 完成 boot 後再取 snapshot。

另外也提及 `vmclock` / `vm_generation_counter` 等使用者空間通知機制（用於協助 wall-clock 同步與 disruption marker / generation counter 變更偵測）。

---

## 9. 釐清的操作重點（快速抓重點）

- 建 snapshot 前：通常需要先 `Pause`。
- Diff snapshot：需理解 `track_dirty_pages` 或 `mincore` 的前提（例如 swap disabled）。
- Disk/網路/TAP/vsock backing：多數資源需由使用者在新行程以相同路徑提供。
- memory file 必須 immutable。
- 安全性：同一份 snapshot 若被 resume 多次，可能重複敏感唯一狀態，需要使用者層級處理。

---

## TO-DO List

1. 檢查這份總結是否符合你要的「摘要深度」（例如是否要再加上 API request 範本）。
2. 若你要把它放進專案文件目錄，告訴我你想要的路徑規範（例如 `docs/` 下的命名習慣）。
3. 視你的使用情境補上你關心的重點（例如是否使用 `Uffd`、是否取 diff snapshot）。 

