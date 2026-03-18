# Accessing hostOS APIs and files from VM
_Exported on 2026/3/16 at 18:35:32 [GMT+8] from Cursor (2.6.19)_

---

**User**

1. 如何在 vm 中可以呼叫外面 hostOS 中的 LLM (ollama 和 opencode API 和 gemini API)
2. 如何將在 vm 中可以存取外面 hostOS 中特定目錄下的檔案

---

**Cursor**

先看一下你目前這個 `Firecracker + WSL2` 環境的設定文件，確認網路與檔案共享的前提，再整理成可直接操作的做法。

我已先對齊你這個專案的實際架構：`Firecracker` 是跑在 `WSL2` 內，所以對 microVM 來說，真正的 host 是 `WSL2 Linux`，不是直接的 Windows。接下來我會用這個前提，把 `LLM API` 存取和 host 檔案共享拆成可落地的方案。

先釐清一個關鍵前提：對 `Firecracker microVM` 來說，真正的 host 是你現在跑 `Firecracker` 的那層 `WSL2 Linux`。若你的 `Ollama` 是跑在 Windows，而 `Firecracker` 跑在 WSL2，那路徑其實是：

```mermaid
flowchart LR
  G[Firecracker Guest VM] --> H[WSL2 Host]
  H --> W[Windows Host]
  H --> I[Internet]
```

所以你的問題可以拆成兩件事：

1. `Guest VM` 怎麼打到 `WSL2 host` 上的服務
2. `Guest VM` 怎麼安全地讀 `WSL2 host` 上特定目錄的檔案

## TO-DO List
- 確認 `microVM` 已有可用網路，能到 `WSL2 host` 的 `tap` IP
- 決定 `LLM` 要走 `TCP/HTTP proxy` 還是 `vsock proxy`
- 決定 host 檔案要用「只讀映像檔」、「檔案服務 API」或 `vsock file agent`
- 若要保護 API key，優先把 `Gemini API key` 留在 host，不直接放進 guest
- 只暴露白名單目錄，不要讓 guest 直接碰整個 host filesystem

## 先講結論
### 1. 在 VM 呼叫外面 hostOS 的 LLM
最實務的做法是：

- `Gemini API`：guest 直接走 internet 呼叫即可，只要 guest 有 egress network。
- `Ollama` / `OpenCode API`：不要讓 guest 直接找 `127.0.0.1`，而是讓 host 把服務綁在 `tap` IP，或由 host 開一個 proxy 給 guest 打。

### 2. 在 VM 存取 hostOS 特定目錄的檔案
`Firecracker` 不適合用 Docker 那種「直接 bind mount host directory」思維。它沒有成熟的原生 host directory sharing 機制可直接拿來當標準解法。實務上通常用這三種：

- 固定、只讀資料：做成額外 block device 掛進 guest
- 動態讀檔：host 開一個檔案服務 API 給 guest 存取
- 需要更嚴格控制：用 `vsock` 做 host-side file agent

## 一、LLM 存取方案
### 方案 A：用 host 網路 IP 暴露 HTTP API
這是最簡單、最容易落地的方式。

架構：

```mermaid
flowchart LR
  G[Guest VM App] --> T[Host tap IP]
  T --> O[Ollama / OpenCode Proxy]
  O --> L[Local LLM or External API]
```

做法重點：

- host 端有一個 `tap` 介面，例如 `172.16.0.1`
- guest 端有 IP，例如 `172.16.0.2`
- guest 直接呼叫 `http://172.16.0.1:<port>`
- host 上的 `Ollama` 或 proxy 必須綁定在 `172.16.0.1` 或 `0.0.0.0`，不是只綁 `127.0.0.1`

範例：

```bash
# host 端
OLLAMA_HOST=172.16.0.1:11434 ollama serve
```

guest 內：

```bash
curl http://172.16.0.1:11434/api/tags
```

如果 `Ollama` 已經只跑在 host 的 `127.0.0.1:11434`，可以在 host 再加一層轉發：

```bash
socat TCP-LISTEN:11434,bind=172.16.0.1,fork TCP:127.0.0.1:11434
```

`OpenCode API` 也是同樣概念，只要它本質是 `HTTP API`，guest 就打 host 的 `tap IP + port`。

### 方案 B：`Gemini API` 直接從 guest 出網
如果你的 guest 已經能上網，`Gemini API` 最簡單就是直接呼叫官方 endpoint。

優點：

- 不需要 host 轉發
- 路徑最短

缺點：

- `API key` 會進 guest
- 若 guest 是不可信 workload，風險較高

適合情境：

- guest 是你自己控制的 app
- 沒有多租戶/隔離風險
- 你接受 key 存在 guest 裡

### 方案 C：host 端做統一 LLM gateway
這是我最推薦的架構，尤其你同時有 `Ollama`、`OpenCode API`、`Gemini API`。

做法：

- guest 只打 host 上一個統一入口，例如 `http://172.16.0.1:8080`
- host proxy 依路徑轉發到：
  - `Ollama`
  - `OpenCode API`
  - `Gemini API`
- 所有 token / key 都只留在 host

例如：

- `http://172.16.0.1:8080/ollama/...`
- `http://172.16.0.1:8080/opencode/...`
- `http://172.16.0.1:8080/gemini/...`

這樣 guest 不知道真正憑證，也比較好做：

- 白名單模型
- rate limit
- request/response logging
- access control

### 方案 D：用 `vsock`，不要走 TCP
如果你不想把 host service 暴露到網路介面，`vsock` 是更乾淨的 host-guest 通道。

適合：

- 只要 host 與 guest 通訊
- 不想開 `tap` 上的 HTTP port
- 想把 attack surface 壓小

但缺點也很明顯：

- 一般 `curl` / SDK 不能直接無痛用
- 通常要自己做一個 `vsock <-> HTTP` bridge
- 落地複雜度比 TCP 高

所以如果你現在目標是「先能用」，先選 `方案 A` 或 `方案 C`。

## 二、host 檔案存取方案
### 先講限制
如果你問的是像 Docker 那樣：

- host 有 `/data/prompts`
- guest 直接 mount 成 `/mnt/prompts`

在 `Firecracker` 上，這不是最順手的標準做法。不要把它當成現成有的能力。

### 方案 1：把特定目錄做成只讀磁碟映像
如果那批檔案更新不頻繁，這是最穩的方式。

做法：

- 在 host 把指定目錄打包成 `ext4` 或 `squashfs` 映像
- 當成第二顆 block device 掛進 microVM
- guest 開機後 mount 成例如 `/mnt/shared`

適合：

- prompt templates
- 模型設定檔
- 基準測試資料集
- 幾乎不變的 assets

優點：

- 最接近 Firecracker 設計哲學
- 簡單、穩定、隔離清楚

缺點：

- 更新內容要重建映像
- 不適合高頻率雙向寫入

### 方案 2：host 開檔案服務 API
如果你要的是「guest 可以讀 host 某個白名單目錄內的檔案」，這通常是最實用的方案。

例如 host 開一個小服務，只允許讀：

- `/srv/shared/prompts`
- `/srv/shared/input`

guest 透過 HTTP API 做：

- `GET /files/prompts/a.txt`
- `GET /files/input/job-001.json`
- `PUT /files/output/result.json`

優點：

- 權限好控
- 不需要 guest 直接 mount host filesystem
- 容易加驗證、審計、白名單

缺點：

- 你要自己定 API
- 不像本地檔案系統那麼透明

如果你的 guest 只是 app，不是要 shell 裡面到處 `ls/cp/vim`，這是最好的折衷。

### 方案 3：用 `vsock file agent`
這是安全版的檔案代理。

架構：

```mermaid
flowchart LR
  G[Guest App] --> V[vsock]
  V --> A[Host File Agent]
  A --> D[/host/allowed-dir]
```

host agent 只接受有限操作，例如：

- `read(path)`
- `list(path)`
- `write(path)`
- `stat(path)`

而且 `path` 只能在白名單根目錄下。

優點：

- 不經過一般 TCP port
- 攻擊面較小
- 適合敏感環境

缺點：

- 開發成本比 HTTP 高
- 除錯也比較麻煩

### 方案 4：用 SSH/SFTP/NFS 類檔案服務
也可行，但我不會列為第一選擇。

原因：

- 對 `microVM` 來說偏重
- 權限收斂沒那麼精準
- 你只是要「特定目錄存取」時，通常 HTTP API / vsock agent 更乾淨

## 我的建議
如果你現在要的是「先能跑，再逐步收斂安全性」，建議這樣選：

### LLM
- `Ollama` / `OpenCode API`：先用 `host tap IP + HTTP proxy`
- `Gemini API`：若重視 key 保護，也走同一個 host proxy；若只是快速驗證，可先 guest 直連官方 API

### 檔案
- 靜態檔案：用額外 block device
- 動態檔案：用 host file service API
- 高安全需求：再升級成 `vsock agent`

## 最小可行架構
你可以直接把系統收斂成下面這個樣子：

```mermaid
flowchart TD
  G[Guest VM]
  P[Host LLM Proxy]
  F[Host File Service]
  O[Ollama]
  C[OpenCode API]
  M[Gemini API]
  D[/srv/firecracker-shared]

  G --> P
  G --> F
  P --> O
  P --> C
  P --> M
  F --> D
```

這樣 guest 只需要知道兩個 endpoint：

- `http://172.16.0.1:8080`：LLM gateway
- `http://172.16.0.1:8081`：檔案服務

其餘憑證、真實路徑、模型選擇、rate limit 都留在 host。

## 你這個環境的特別提醒
因為你目前是 `Windows -> WSL2 -> Firecracker guest` 三層結構：

- 若 `Ollama` 跑在 Windows，不建議讓 guest 直接找 Windows IP
- 比較穩的做法是：先在 `WSL2 host` 開 proxy，再由 proxy 去打 Windows 上的 `Ollama`
- 對 `Firecracker guest` 而言，只看見 `WSL2 host tap IP`

這樣網路拓樸最單純，也比較好除錯。

## 一句話版本
- `LLM`：用 `WSL2 host` 當 gateway，guest 只打 host 的固定 IP/port
- `檔案`：不要期待直接 bind mount host 目錄，改用「block device」或「host file service / vsock agent」

如果你要，我下一步可以直接幫你補一版「可落地 Implementation Plan」，內容包含：
1. `Firecracker tap network` 配置
2. `host LLM proxy` 範例
3. `host file service` 範例
4. guest 內怎麼呼叫這兩個服務

---

**User**

目標: 在 vm 內安裝 opencode+skills 然後提供給每一個 user 使用

---

**Cursor**

這個目標已經進入「系統設計」範圍，我先切到 `Plan Mode`，整理成可執行的部署方案與邊界條件，再跟你確認後才往實作細節走。

## Top-down Overview
如果你的目標是「在 `Firecracker VM` 內安裝 `opencode + skills`，並提供給每一個 user 使用」，我建議不要做成「一台共享 VM 給所有人一起用」，而是做成：

- `每個 user 一個獨立 microVM`
- `opencode` 預裝在 base image
- `skills` 分成「共用唯讀」與「使用者專屬可寫」
- 所有 LLM 存取統一走 host 上的 `gateway/proxy`
- user 只接觸自己的 VM，不直接接觸 host 憑證與 host 檔案系統

這樣比較符合 `Firecracker` 的隔離模型，也比較容易管控 API key、檔案權限與資源配額。

## Implementation Plan
### 目標架構
```mermaid
flowchart LR
  U[User] --> CP[Control Plane]
  CP --> VM1[Per-user Firecracker VM]
  CP --> VM2[Per-user Firecracker VM]
  VM1 --> GW[Host LLM Gateway]
  VM2 --> GW
  GW --> OL[Ollama]
  GW --> OC[OpenCode API]
  GW --> GM[Gemini API]
  VM1 --> SK1[Shared Skills RO]
  VM1 --> HOME1[User Workspace RW]
  VM2 --> SK1
  VM2 --> HOME2[User Workspace RW]
```

### 核心設計
1. `Base Image`
- 在 guest image 內預裝：
  - `opencode`
  - 必要 runtime，例如 `node/python/git/curl`
  - 基本 shell 環境
- 這個 image 不放 user data，不放真正 API key

2. `Shared Skills`
- 把共用 `skills` 做成唯讀資料來源
- 建議路徑：
  - guest 內：`/opt/opencode/skills`
- 來源可選：
  - 額外唯讀 block image
  - host file service API
- 若 skills 更新頻率不高，優先用 `唯讀 block image`

3. `User Private Workspace`
- 每個 user 有自己的可寫工作區
- 建議路徑：
  - `/home/<user>/workspace`
  - `/home/<user>/.opencode`
- 這裡放：
  - user 專案
  - user 自訂設定
  - user 私有 skills override

4. `LLM Gateway`
- guest 內的 `opencode` 不直接拿 `Gemini key`
- 改成打 host 上統一入口，例如：
  - `http://172.16.0.1:8080`
- gateway 再轉發到：
  - `Ollama`
  - `OpenCode API`
  - `Gemini API`
- 好處：
  - key 留在 host
  - 可做 auth / audit / rate limit / model allowlist

5. `Provisioning`
- user 登入或建立 session 時：
  - 建立一台新的 microVM
  - 掛載 base image
  - 掛載 user 專屬 writable rootfs 或 overlay
  - 掛載 shared skills
  - 注入該 user 的 metadata
- session 結束後：
  - 保留或回收 user disk，看你的產品需求

## TO-DO List
- 確認「每個 user 一台 VM」還是「多人共用同一台 VM」
- 確認 `opencode` 的執行模式：CLI、daemon，還是 API server
- 確認 `skills` 要分成「平台共用」與「user 私有」嗎
- 確認 user workspace 要不要持久化
- 確認 LLM 存取是否必須隱藏 API key
- 確認 user 是否可以安裝額外套件
- 確認 VM 啟動延遲與資源配額上限
- 確認要不要做 snapshot / warm pool

## 我建議的落地版本
### V1：先做可用版本
- `每個 user 一個 VM`
- base image 內建 `opencode`
- shared skills 用唯讀映像檔掛進 guest
- user workspace 用獨立 writable disk
- guest 內所有 LLM 請求都打 host gateway

這版最穩，複雜度也合理。

### V2：再做營運化
- warm pool 預先啟動數台 VM 降低 cold start
- snapshot restore 加速 user session
- skills 版本管理
- user 配額與審計
- 觀測指標：啟動時間、token 使用量、VM RSS、錯誤率

## 邊界條件
你現在要先決定這幾件事，不然後面實作會差很多：

1. `每個 user` 是不是代表「每人一台獨立 VM」？
2. `opencode` 是要給 user 在 VM 內用 CLI，還是你要做成對外服務？
3. `skills` 是全員共用一份，還是每個 user 可以有自己的 skills？
4. user 的工作目錄是否需要跨 session 保留？
5. `Gemini / Ollama / OpenCode API` 的憑證是否只能留在 host？

## 我目前的建議答案
如果你要的是安全、可維運、能擴充的方案，我會定義成：

- `每個 user 一台 Firecracker microVM`
- `opencode` 烘進 base image
- `shared skills` 用唯讀映像掛載
- `user workspace` 用獨立可寫 disk
- `LLM` 全部走 host gateway
- `API key` 永遠不進 guest

如果你確認這個方向，我下一步可以直接幫你產出一版更具體的 **Implementation Plan v2**，內容會包含：

1. guest 內目錄規劃
2. base image 該安裝哪些套件
3. shared skills 與 user workspace 的掛載策略
4. host gateway 的 API 拓樸
5. user 建立 VM 的 lifecycle 流程
6. 第一版最小可行架構的實作順序

---

**User**

每個 user 一台 VM
skills 要分成「平台共用」與「user 私有」
LLM 存取不必隱藏 API key
session 結束後，根據 pool 數量決定是否直接回收(EX: pool <100 就先不回收)

請說明 "做 snapshot / warm pool"。才能決定
請說明 "VM 啟動延遲與資源配額上限" 。才能決定
請說明 user workspace 要不要持久化的差異。才能決定
請說明 user 不可以安裝額外套件和可以安裝額外套件的差異。才能決定
請說明 opencode 的執行模式：CLI、daemon，還是 API server 的差異。才能決定


---

**Cursor**

## Top-down Overview
你目前已經定下幾個重要前提：

- `每個 user 一台 VM`
- `skills` 分成「平台共用」與「user 私有」
- `LLM API key` 可以進 guest
- `session` 結束後是否回收，取決於 pool 水位

接下來真正要決定的是 5 個設計開關，因為它們會直接影響成本、啟動速度、可維運性與安全邊界：

1. 要不要做 `snapshot / warm pool`
2. 可接受的 `VM 啟動延遲` 與 `資源配額`
3. `user workspace` 要不要持久化
4. user 可不可以安裝額外套件
5. `opencode` 要用 `CLI`、`daemon` 還是 `API server`

## TO-DO List
- 決定是否追求「秒開」體驗，還是接受冷啟動
- 決定單一 user 的 CPU / RAM / disk 配額上限
- 決定 `workspace` 是短期 session 型還是長期個人型
- 決定 guest 是否允許安裝額外套件
- 決定 `opencode` 的對外使用型態
- 決定 pool 的回收門檻與閒置策略

## 1. `snapshot / warm pool` 是什麼
### `Warm Pool`
意思是先預備一批「已建立好、甚至已開機好」的 VM，等 user 來時直接分配。

### `Snapshot`
意思是先把某個 VM 狀態存成快照，之後新 user 不用從頭 boot kernel + init system + 啟動 app，而是直接從某個既定狀態 restore。

### 差異
```mermaid
flowchart LR
  A[Cold Start] --> B[Boot kernel]
  B --> C[Init userspace]
  C --> D[Start opencode]
  D --> E[Ready]

  F[Warm Pool] --> G[Pre-created VM]
  G --> E

  H[Snapshot Restore] --> I[Restore saved state]
  I --> E
```

### `Cold Start`
每次都從零開始。

優點：
- 架構最簡單
- 狀態最乾淨
- 不容易殘留前一個 user 的記憶體狀態

缺點：
- 啟動最慢
- user 體感最差
- pool 越大越容易被啟動尖峰打爆

### `Warm Pool`
預先準備 N 台可分配 VM。

優點：
- user 進來時幾乎可立即使用
- 操作簡單，通常比 snapshot 更容易維運

缺點：
- 會一直吃 RAM / CPU / disk
- pool 越大，待機成本越高
- 若 VM 已登入某些 user 狀態，要注意清理

### `Snapshot`
保留「已開機、已安裝、已啟動必要服務」的中間狀態。

優點：
- 啟動很快
- 比 full warm VM 更省一些待機成本
- 適合大量相同模板的 user VM

缺點：
- 維運複雜度較高
- snapshot 版本與 guest kernel / app 版本要一致管理
- 若 snapshot 時機選不好，容易把不該保留的狀態一起帶進去

### 什麼時候選哪個
- 要先求穩：先做 `cold start + 小型 warm pool`
- 要求很快登入：做 `warm pool`
- user 數量大、模板固定、很在乎秒開：再考慮 `snapshot`

### 你的情境建議
你現在是 `每個 user 一台 VM`，而且 session 結束可能依 pool 水位保留，最務實的是：

- `V1`：先做 `warm pool`
- `V2`：等你量到 cold start 真的太慢，再加 `snapshot`

因為 `warm pool` 比較好理解，也比較容易和「pool < 100 不回收」這種策略對齊。

## 2. `VM 啟動延遲` 與 `資源配額上限` 是什麼
這兩個其實是在決定你的產品體驗與成本模型。

### 啟動延遲
就是 user 從「要求一台 VM」到「可開始使用 opencode」所需的時間。

可拆成：

1. 建立 VM
2. boot guest
3. 掛載 skills / workspace
4. 啟動 `opencode`
5. 健康檢查通過

### 為什麼要先定
因為不同目標會導致完全不同的架構：

- 若要求 `< 2 秒`，通常要 `warm pool`，甚至 `snapshot`
- 若接受 `10~30 秒`，cold start 也可能可以
- 若接受 `30~60 秒`，很多簡化做法都可用，但體驗會差很多

### 建議的延遲分級
- `極佳體驗`：`1~3 秒`
- `可接受互動式體驗`：`3~10 秒`
- `偏批次型`：`10~30 秒`
- `不適合互動式`：`30 秒以上`

### 資源配額上限
就是每台 VM 最多給多少：

- `vCPU`
- `RAM`
- `rootfs / workspace disk`
- `network bandwidth`
- `process / file descriptor / request rate`

### 為什麼重要
因為 `opencode + skills + LLM client` 不一定很吃 CPU，但 user 一旦開始跑其他工具，資源就可能暴增。

### 典型差異
- 小配額：成本低，但容易卡
- 大配額：體驗好，但併發數下降

### 可參考的起始值
如果是文字型 agent / coding assistant 類工作負載，V1 可以先估：

- `1~2 vCPU`
- `1~2 GB RAM`
- `5~20 GB workspace`
- 明確限制同時背景程序數

若 user 會：

- 跑 `npm install`
- 跑測試
- 用 Python / Node 工具鏈
- 編譯較大專案

那你可能要往：

- `2~4 vCPU`
- `2~4 GB RAM`
- `10~30 GB disk`

### 你真正要先決定的不是數字本身，而是這句話
你的產品是要：

- 「大量 user，輕量互動」
- 還是「較少 user，但每人像一台真正開發機」

這兩種資源模型差非常多。

## 3. `user workspace` 要不要持久化
這是產品定位問題，不只是技術問題。

### 持久化
代表 user 下次回來時，還看得到之前的：

- 程式碼
- 設定
- 安裝的工具
- 產出檔案
- 私有 skills

優點：
- user 體驗最好
- 適合長期工作流
- 可保存私有 skills、自訂環境、暫存成果

缺點：
- 需要 disk lifecycle 管理
- 容易累積垃圾、舊依賴、版本漂移
- 若 VM 回收但 disk 保留，系統設計會變複雜

### 不持久化
每次 session 都是新環境。

優點：
- 環境乾淨
- 問題容易重現
- 維運最簡單
- 安全性與一致性較好

缺點：
- user 每次都要重新準備工作
- 私有 skills 與設定要另外同步
- 不適合長週期任務

### 中間方案
最常見也最合理的是：

- `workspace 持久化`
- `VM instance 不持久化`

也就是：
- VM 可以回收
- 但 user 的 disk / home / workspace 保留
- 下次新開 VM 再把這份資料掛進去

這通常是最平衡的作法。

### 你的情境建議
若你要提供給每個 user 長期使用，我建議：

- `user workspace 要持久化`
- `VM 本體不一定持久化`

這樣你可以同時得到：
- 乾淨的運算節點 lifecycle
- 可保留的 user 成果與私有 skills

## 4. user 可不可以安裝額外套件
這會直接改變平台的控制力。

### 不可以安裝額外套件
意思是 guest 內容基本固定，user 只能使用平台預裝東西。

優點：
- 最穩定
- 環境一致
- 最好支援 snapshot / warm pool
- 故障排查簡單

缺點：
- user 彈性低
- 一遇到缺工具就要平台補 image
- 客製需求多時，平台會成為瓶頸

適合：
- 平台型產品
- 高併發
- 你想把 VM 當「受控執行環境」

### 可以安裝額外套件
意思是 user 可自行 `apt/pip/npm/cargo` 類安裝。

優點：
- user 自由度高
- 適合開發型 workload
- 減少平台預裝壓力

缺點：
- 環境很快漂移
- snapshot 與 warm pool 一致性變差
- disk 成長不可控
- 問題很難重現
- 安全與濫用風險上升

適合：
- 研發團隊內部使用
- 高彈性需求
- 你接受 user VM 不完全可控

### 折衷方案
最常見是：

- 系統層套件：不允許
- user-space 套件：允許

例如：
- 不給 `sudo apt install`
- 但允許在 `~/.local`、venv、npm local install

這樣可以兼顧：
- 平台穩定
- user 有一定彈性
- 不破壞 base image

### 你的情境建議
若你要服務「很多 user」，我建議 V1 用：

- `不允許系統層安裝`
- `允許 user-space 安裝`

這比完全開放更可控，也比完全封死更實用。

## 5. `opencode` 的執行模式差異
這是最關鍵的一題，因為它決定 user 與 VM 互動方式。

### `CLI`
就是 user 進 VM 後直接跑命令，例如：

```bash
opencode
```

優點：
- 最簡單
- 最貼近開發者工具
- 很適合先做 PoC
- 幾乎不需要額外 server lifecycle

缺點：
- 不容易做多客戶端整合
- 不容易集中管理 session
- UI / browser / orchestration 整合通常要自己補

適合：
- 內部使用
- 每個 user 自己 SSH / terminal 進 VM
- 先驗證工具可用性

### `Daemon`
代表 `opencode` 在 VM 內常駐，user 透過 local socket / TCP 和它互動。

優點：
- 啟動一次後反應較快
- 可以保留一些 runtime context
- 比 CLI 更容易被其他工具整合

缺點：
- 要管理 daemon lifecycle
- 要考慮 crash recovery、health check、port/socket
- 比 CLI 複雜

適合：
- 你希望 user session 期間 agent 常駐
- 同一個 user 可能多次呼叫同一個 agent process

### `API Server`
代表 `opencode` 對外提供 HTTP / RPC API，平台或前端直接呼叫。

優點：
- 最容易和 web 平台整合
- 最適合做集中調度與 observability
- 最容易串接 control plane、auth、quota、audit

缺點：
- 複雜度最高
- 要處理 API schema、版本管理、錯誤模型
- 若本來 `opencode` 不是 server-first 設計，包裝成本會較高

適合：
- 產品化平台
- 有前端 / 控制平面 / 多種 client
- 你想把 VM 當 backend execution node

## 怎麼選 `opencode` 模式
### 如果你現在是 PoC / 內部驗證
選 `CLI`

原因：
- 最快落地
- 最容易驗證 skills、workspace、LLM 是否打通

### 如果你是單一 user 單 session，但想提升互動速度
選 `daemon`

原因：
- 保留 session context
- 比 CLI 更像 agent runtime

### 如果你要產品化給很多 user，外部有平台入口
選 `API server`

原因：
- 平台好整合
- 控制平面好做
- user 不一定要直接登入 VM

## 我對你目前情境的建議
以你現在的需求，我會建議這樣定義：

- `每個 user 一台 VM`
- `shared skills` 唯讀
- `user private skills` 放在持久化 workspace
- `workspace 持久化，VM 可回收`
- `先做 warm pool，不先做 snapshot`
- `不允許系統層安裝，允許 user-space 安裝`
- `V1 用 CLI 或 daemon`
- `等平台成形後再升級成 API server`

## 一句話版決策建議
如果你想先做一版穩定可落地的系統，建議你先選：

- `warm pool`: 要
- `snapshot`: 先不要
- `workspace`: 要持久化
- `額外套件`: 僅允許 user-space 安裝
- `opencode`: 先 `CLI`，若 session 互動頻繁再升級 `daemon`

## 下一步建議
如果你要，我可以直接幫你做下一版 **Implementation Plan v2**，把以上選項收斂成一套具體方案，內容會包含：

1. VM lifecycle 與 pool 回收策略
2. `shared skills` / `private skills` 目錄設計
3. workspace 持久化模型
4. `opencode CLI` 與 `daemon` 兩版部署草圖
5. 建議的第一版預設配額與啟動目標

---

**User**

warm pool
「大量 user，輕量互動」+ 少部分工程師需求「較少 user，但每人像一台真正開發機」
user workspace 持久化 + VM instance 不持久化
不允許系統層安裝 + 允許 user-space 安裝
opencode 模式 = CLI (後續目標 API Server) (不須 daemon)
其餘依據建議

---

**Cursor**


根據你確認的選項，整理成可直接落地的 **Implementation Plan v2**。



撰寫 Implementation Plan v2 文件，並與現有 benchmark 流程對齊。



撰寫完整實作計畫文件。



已把 **Implementation Plan v2** 寫進 `IMPLEMENTATION-PLAN-OPENCODE-VM.md`，並依你剛確認的選項整理好。

---

## 內容摘要

1. **已確認決策表**  
   你選的：warm pool、雙層 user、workspace 持久化 + VM 不持久化、僅 user-space 安裝、OpenCode 先 CLI 再 API Server，都寫在文件開頭。

2. **雙層資源**  
   - **輕量**：1 vCPU、1 GB、5～10 GB workspace，給多數 user。  
   - **開發機**：2～4 vCPU、2～4 GB、20～50 GB workspace，給少數工程師。

3. **磁碟與目錄**  
   - Base rootfs（RO）→ 根目錄 + opencode。  
   - Shared skills 映像（RO）→ guest `/opt/opencode/skills`。  
   - User workspace（RW）→ guest `/home/<user>/workspace`，持久化、隨 VM 掛載/卸載。

4. **Warm pool 與回收**  
   - Pool &lt; 門檻（例 100）：session 結束後 VM **不回收**，清完 guest 後放回 pool。  
   - Pool ≥ 門檻：**回收** VM process，**保留** 該 user 的 workspace 磁碟，下次同 user 用新 VM 掛同一 workspace。  
   - 建議：從 pool 取出的 VM **固定綁定單一 user**，避免多 user 共用同一台。

5. **與現有程式的對齊**  
   - 在現有 `PUT /boot-source`、`PUT /drives/rootfs`、`PUT /actions` 之外，加上兩顆額外 drive：`shared_skills`、`workspace`，並在 guest 開機時掛到上述路徑。

6. **實作階段（Phase 1～4）**  
   - Phase 1：單 VM + opencode + 雙 skills（共用 + 私有）可跑通。  
   - Phase 2：warm pool + light/dev 雙規格。  
   - Phase 3：session 結束後的歸還/回收與清理策略。  
   - Phase 4（可選）：OpenCode 以 API Server 形式提供。

7. **TO-DO List**  
   文件最後有實作檢查清單，可直接在開發時勾選。

---

接下來你可以：  
- 先做 **Phase 1**（單 VM、三顆碟、guest 目錄與 opencode CLI 驗證），或  
- 指定一段想先實作的部分（例如多 drive API、base rootfs 要裝什麼、或 pool 門檻常數放在哪），我可以依該段寫出對應的配置或程式碼片段。

---

**User**

先回答並釐清問題。最後等到與我確認後再開始實作。
1. Pool 回收策略: "Pool 數量 < 門檻" 與 "Pool 數量 >= 門檻" 在描述中只有 "殺 process" 的差異。那直接回收不是比較簡單? 還是有其他差異?
2. 不一定需要與現有程式對齊。可以直接新建。
3. "Guest 內需在開機腳本或 cloud-init 中掛載對應 block 裝置到 /opt/opencode/skills 與 /home/<user>/workspace（或先掛到固定點再 bind mount）。" 如何掛載?
4. User 如何透過 SSH 或 console 登入 VM ?
5. 如何將 opencode 安裝到 base rootfs 內 ?
6. 如何將 opencode 的 skills 指向 在 opencode 設定中指向 `/opt/opencode/skills` 和 `~/workspace/.skills` 路徑。
7. 在 guest 外以 API Server 形式執行 opencode，提供 HTTP/RPC 給 guest 內的程式呼叫。

---

**Cursor**


先只回答與釐清，不寫程式碼；等你確認後再開始實作。

---

## 1. Pool 回收策略：為什麼不一律「直接回收」？

差異不只是「有沒有殺 process」，而是 **下一批 user 拿到 VM 的速度**。

| 策略 | Session 結束後 | 下一位 user 拿到 VM 時 |
|------|----------------|--------------------------|
| **不回收（放回 pool）** | VM process 留著，清空 guest 狀態後標成 idle | 從 pool 拿一台 **已開好機** 的 VM → **幾乎立刻** 可用（1～3 秒） |
| **回收（殺 process）** | 關掉 VM process，只保留 workspace 磁碟 | 下一位要 **重新開一台 VM**（冷啟動）→ 可能要 10～30 秒 |

所以：

- **不回收**：多一點複雜度（要定義「歸還前清理」、誰可以用哪台 VM），換來 **低延遲**，適合「大量 user、輕量互動」。
- **一律回收**：實作最簡單，但每次分配都是冷啟動，延遲較高。

若你優先要 **簡單**，可以改成：**一律回收**；pool 只負責「預先冷啟動好 N 台 VM 待命」，user 用完就殺 process，下次再從 pool 取一台已開好的（若 pool 空了再冷啟動）。這樣「回收」的語意就變成：**VM 一定殺掉，但 pool 裡保持有若干台 idle VM 備用**。  
要的話可以把文件改成「僅此一種策略」，不再區分門檻。

---

## 2. 與現有程式對齊 → 改為新建

已記錄：**不強制與現有 `fc-pro-bench-02.py` 對齊，實作時以新建專案/模組為主**。之後實作計畫與程式都會以「新建」為前提撰寫。

---

## 3. Guest 內如何掛載兩顆額外 block 裝置？

Firecracker 會把多顆碟暴露成 guest 的 block device，例如：

- `/dev/vda`：第一顆（rootfs）
- `/dev/vdb`：第二顆（shared skills）
- `/dev/vdc`：第三顆（user workspace）

在 guest 裡要做的事：

1. **開機時**（init 腳本或 systemd）：
   - 建立目錄：`mkdir -p /opt/opencode/skills`、`mkdir -p /home/<user>/workspace`（若尚未存在）。
   - 掛載：
     - `mount /dev/vdb /opt/opencode/skills`
     - `mount /dev/vdc /home/<user>/workspace`
2. **若希望開機自動掛**：在 `/etc/fstab` 加上兩行（用 `nofail` 較安全，避免缺碟時開不了機），例如：
   - `/dev/vdb  /opt/opencode/skills  ext4  ro,nofail  0  2`
   - `/dev/vdc  /home/<user>/workspace  ext4  defaults,nofail  0  2`
3. **誰來執行**：由你選一種方式做「開機腳本」：
   - **build 進 base rootfs 的 `/etc/rc.local` 或 systemd oneshot**：開機時跑上述 `mkdir` + `mount`。
   - **cloud-init**：若 base 內有 cloud-init，可用 `runcmd` 或 mount 模組做同樣事。

**注意**：  
- 第二顆碟若做成 **唯讀**（在 host 用 `is_read_only: true`），guest 用 `ro` 掛載。  
- `<user>` 要在 base image 裡預先建好（例如固定一個 `opencode` 或 `dev` 帳號），或由開機腳本根據 metadata 建立；同一台 VM 對應的 user 由 control plane 決定。

你確認「用哪一種開機方式」（rc.local / systemd / cloud-init）後，實作時可以只做那一種。

---

## 4. User 如何透過 SSH 或 console 登入 VM？

分兩種：

**Console（序列埠）**

- Firecracker 支援 serial console（例如 `console=ttyS0`）。
- 在 **host** 上用同一顆 VM 的 socket 或 PTY 連線（依你啟動 Firecracker 時是否開 `--console pty` 或 `--console socket`）。
- 用途：除錯、救援；不適合當一般 user 的日常入口。

**SSH**

- Guest 內要跑 **sshd**（base rootfs 預裝並預設開機啟動）。
- Guest 要有 **網路**：Firecracker 需配置 tap 介面，guest 拿得到 IP（DHCP 或靜態）。
- **User 從哪裡連**：
  - **從 host 連到 guest**：host 上 `ssh user@<guest_ip>`（guest_ip 為 tap 網段，例如 172.16.0.2）。
  - **從外網連到 guest**：需在 host 做 **port forwarding**（例如 host 的 2222 → guest:22），user 連 `ssh -p 2222 user@<host_ip>`；或 host 當跳板：先 SSH 到 host，再從 host ssh 到 guest。

實作時需要：

- base rootfs 內：安裝並啟用 `openssh-server`，建立一個預設登入帳號（或每台 VM 依 user 建立帳號）。
- host：為每台 VM 配置 tap、給 IP，並決定「只從 host 連」還是「對外 port forward」。

等你確認「user 是從 host 連 guest，還是從外網經 host 轉到 guest」，實作時可以只做對應那一種。

---

## 5. 如何把 opencode 安裝到 base rootfs 內？

Base rootfs 是一塊 **ext4 映像檔**，在 **host** 上操作：

1. **掛載該映像**（例如掛到 `/mnt/rootfs`）：
   - `sudo mount -o loop base.rootfs.ext4 /mnt/rootfs`
2. **chroot 進去**（若要跑 opencode 的 install 腳本）：
   - `sudo chroot /mnt/rootfs`
   - 在 chroot 裡安裝 opencode（二進位、或從 source/build 裝）、依賴（如 Node/Python）。
3. **或不用 chroot**：直接把已編譯好的 opencode 二進位與必要檔案 **複製** 到掛載後的目錄，例如：
   - `sudo cp -r opencode /mnt/rootfs/opt/opencode/`
   - `sudo cp opencode-bin /mnt/rootfs/usr/local/bin/opencode`
4. **卸載**：`sudo umount /mnt/rootfs`。

「opencode」若來自套件（deb/rpm/npm/pip），就在 chroot 裡用該套件管理器安裝；若是單一 binary，就複製到 `/usr/local/bin` 或 `/opt/opencode/bin` 並在 PATH 中。  
實作時會依你實際的 opencode 發佈形式（二進位 / 套件 / 原始碼）寫具體步驟。

---

## 6. 如何讓 opencode 的 skills 指向 `/opt/opencode/skills` 和 `~/workspace/.skills`？

這取決於 **opencode 實際怎麼讀「skills 路徑」**（設定檔、環境變數、或 CLI 參數）。

常見做法：

- **單一路徑**：若只支援一個目錄，可把「共用 + 私有」合併成一個目錄給 opencode，由 **開機腳本或登入腳本** 做 merge：
  - 例如：把 `/opt/opencode/skills` 與 `~/workspace/.skills` 用 bind mount 或 symlink 合到 `/tmp/opencode-skills`，再讓 opencode 讀 `/tmp/opencode-skills`。
- **多路徑或優先順序**：若 opencode 支援多個目錄（例如 `SKILLS_PATH=/opt/opencode/skills:~/workspace/.skills` 或設定檔裡 list），就在 base 的 **預設設定** 裡寫死：
  - 共用：`/opt/opencode/skills`
  - 私有：`/home/<user>/workspace/.skills`（或用 `~`，由執行 opencode 的 user 決定）。

建議：**先查 opencode 官方文件** 看「skills 目錄」的設定方式（檔名、env、CLI）；若你提供文件連結或關鍵字，我可以幫你寫成「在 base 裡要改哪個檔、設什麼值」。  
實作時會假設：有辦法在設定中指定上述兩個路徑（或一個合併後的路徑）。

---

## 7. 在 guest「外」以 API Server 執行 opencode，給 guest 內程式呼叫

你現在要的架構是：

- **opencode 不在每台 guest 裡**，而是 **在 host（或獨立服務）** 以 API Server 形式跑。
- **Guest 內** 只有「呼叫 opencode 的 client」：透過 HTTP/RPC 打 **host 上的 opencode API**。

差異整理：

| 項目 | 先前寫的（opencode 在 guest 內） | 你現在要的 |
|------|-----------------------------------|------------|
| opencode 執行位置 | 每台 VM 內 | Host（或獨立服務） |
| Guest 內有什麼 | opencode CLI / 未來 API Server | 僅 client（例如 CLI 或小程式） |
| 連線方向 | 無（本機） | Guest → Host（tap 網路或 vsock） |

實作上需要：

- **Host**：跑 opencode API Server，綁在一個 guest 能連到的位址（例如 tap 的 IP `172.16.0.1`，或 vsock）。
- **Guest**：網路設好後，client 設定 **API base URL** 為 host 的位址（例如 `http://172.16.0.1:8080`）。
- **多租戶**：若多台 guest 同時打同一個 opencode API，需在 API 層區分「哪個 request 屬於哪個 user/session」（例如 API key、token、或 request header 帶 user_id）。

這樣的話：

- **Base rootfs 裡不必裝完整的 opencode**，只裝 **能呼叫 host API 的 client**（或輕量 CLI 包一層 HTTP）。
- **Skills**：若 skills 由 opencode 服務端讀取，則 **共用/私有 skills 可放在 host**（或 API Server 的設定裡），guest 只負責帶上 user/session 識別；若仍希望部分在 guest，可再討論（例如 guest 上傳或指定路徑，由 API 設計決定）。

請確認兩點：  
- 是否採用「opencode 只在 host 跑一份（或一組），所有 guest 共用這份 API」？  
- 多 user 辨識是要用 API key / token / user_id 還是其他方式？  
確認後，實作計畫會改成「host 跑 opencode API Server + guest 只裝 client + 網路與認證方式」。

---

## 請你確認的項目（再開始實作）

1. **Pool 策略**：改為「一律回收 VM process，pool 只負責預先準備 N 台 idle VM」是否接受？還是要保留「pool < 門檻不殺 process」？
2. **實作**：新建程式，不綁現有 `fc-pro-bench-02.py`。
3. **掛載方式**：開機掛載用 **rc.local / systemd oneshot / cloud-init** 你偏好哪一種？
4. **登入方式**：user 是 **只從 host SSH 到 guest**，還是需要 **從外網經 host 轉到 guest**（port forward）？
5. **opencode 發佈形式**：是單一 binary、套件（deb/npm/pip）、還是原始碼編譯？若有文件連結可一併提供。
6. **Skills 路徑**：若你有 opencode 的 skills 設定文件，可貼出；沒有我就依「支援多路徑或合併目錄」的假設寫。
7. **架構**：確認為 **opencode API Server 在 host，guest 內只有 client 呼叫 host API**；並簡述多 user 辨識方式（API key / token / user_id）。

你回覆確認後，我會依這七點更新 `IMPLEMENTATION-PLAN-OPENCODE-VM.md` 並開始寫實作（新建程式 + 文件更新）。

---

**User**

1. VM 一律回收。pool 負責「預先冷啟動好 100 台 VM 待命」
2. 請說明 "build 進 base rootfs 的 /etc/rc.local 或 systemd oneshot" 的差異
3. 請說明 "cloud-init"
4. 請說明 "預先建好 <user> 帳號" 的用意
5. 每台 VM 依 user 建立帳號。才能使用 SSH 登入。那第一點的 pool 是否需要改變?
6. 每個 user 連到 VM 會有自己的 apikey 以便使用 opencode 中的 LLM
7. VM 只從 host 連(後期做 port forward，也是 host 層的問題，與VM 無關)
8. "如何把 opencode 安裝到 base rootfs 內" 需要詳細說明 (step by step)
9. opencode 來自套件 npm。並且支援多路徑
10. 先不考慮這機制 "在 guest「外」以 API Server 執行 opencode，給 guest 內程式呼叫"

---

**Cursor**


先回答 2～5 的釐清，接著把 1、5～10 的結論收斂並更新實作計畫；第 8 點會用 step-by-step 寫進文件。



先回答 2～5，接著更新實作計畫並加入第 8 點的 step-by-step。



改為分段更新：



檔案已包含大部分更新。正在修正實體字元並補充 SSH 與「先不考慮 host API Server」的說明。



以下依你問的順序回答，並說明文件已如何更新。

---

## 1. Pool 回收策略（已採用「一律回收」）

- **策略**：VM **一律回收**（session 結束就殺 process）；pool 負責「預先冷啟動 100 台 VM 待命」。
- **Pool 不需改變**：pool 裡是 100 台「尚未綁定 user」的 VM；分配時才在 guest 內建帳號、掛 workspace、注入 API key。每台 VM 從取用到回收只服務一位 user。

已寫入 `IMPLEMENTATION-PLAN-OPENCODE-VM.md` 的「Warm Pool 與 VM 生命週期」。

---

## 2. rc.local 與 systemd oneshot 的差異

| | rc.local | systemd oneshot |
|---|----------|------------------|
| **是什麼** | 傳統開機腳本，init 在開機尾聲執行一次 | systemd 的 `Type=oneshot` unit，在進 multi-user 前跑一段腳本（如 mkdir + mount） |
| **優點** | 簡單、不依賴 systemd，適合精簡 rootfs | 可訂依賴（如等 `dev-vdb.device`）、重試、逾時，與 systemd 整合 |
| **缺點** | 發行版不一定有、順序難精確控制 | 要寫 unit、rootfs 需 systemd |

文件裡已有一節「開機掛載：rc.local / systemd oneshot / cloud-init 差異」，內含這三種的比較與建議（要依 user 動態掛載可選 cloud-init，先求簡單可用 systemd oneshot 或 rc.local）。

---

## 3. cloud-init 是什麼

- **用途**：開機時讀 **metadata**（由 hypervisor/host 提供，例如 NoCloud 的 config drive 或 ISO），依 YAML 做：改 hostname、建 user、寫 SSH key、掛載、執行 runcmd 等。
- **優點**：適合「每台 VM 參數不同」——user 名、IP、掛載點由 metadata 注入，開機即可建好帳號、掛好碟。
- **缺點**：base 要裝 cloud-init，host 要為每台 VM 準備 metadata，比單純腳本重一點。

同上，已寫在「開機掛載」那一節。

---

## 4. 「預先建好 user 帳號」的用意

- **預先建好**：在 **做 base rootfs 時**就建一個固定帳號（例如 `dev`），所有 VM 都用同一個登入帳號；區分靠 SSH key/密碼。
- **不預先建、改為依 user 建立**：base 裡**不**預建「最終 user」；**分配 VM 時**在該 VM 內建該 user（如 alice、bob）、設 SSH key 與 home。每人用自己的帳號登入，權限與目錄自然隔離。

本專案採用 **每台 VM 依 user 建立帳號**，所以不在 base 預先建好最終 user；base 只保留 root 或一個給 host 做 provisioning 用的管理帳號。已寫在「『預先建好 user 帳號』的用意」一節。

---

## 5. 每台 VM 依 user 建立帳號，pool 是否需要改變？

**不需要改變。**

- Pool 仍是「約 100 台已開機、未綁定 user」的 VM。
- **分配時**：從 pool 取出一台 → host 用 root/管理帳號 SSH 進該 guest → 在 guest 內建該 user、掛該 user 的 workspace、寫入該 user 的 API key → 把 SSH 連線方式交給 user。
- 因此 pool 邏輯不變，只是「取出的 VM」要再經過一段 provisioning（建帳號、掛碟、注入 key）。

已寫在「Warm Pool 與 VM 生命週期」與「User 帳號與 API key 注入（分配時）」。

---

## 6. 每個 user 自己的 API key

- 分配 VM 時，在該 user 的 home 下寫入 opencode 用的設定（例如 `~/.opencode/env` 或 `~/.config/opencode`），內容為**該 user 的 LLM API key**，供 guest 內的 opencode 呼叫 LLM。

已納入「已確認決策摘要」與「User 帳號與 API key 注入（分配時）」。

---

## 7. VM 只從 host 連；port forward 是 host 層

- **V1**：user **只從 host 連到 guest**（例如在 host 上 `ssh user@<guest_tap_ip>`）。
- **後期**：若要从外網連到 VM，在 **host** 做 port forward（例如 host:2222 → guest:22）；**VM 內不需為此改設定**。

已加一節「SSH 連線方式」並寫明上述兩點。

---

## 8. 如何把 opencode 安裝到 base rootfs（Step-by-Step）

已在文件裡寫成完整步驟，摘要如下：

1. 掛載 base rootfs（`mount -o loop base.rootfs.ext4 /mnt/rootfs`）。
2. 可選：掛載 proc/sys/dev、複製 resolv.conf，方便 chroot 內裝套件。
3. 在 base 內安裝 Node.js（chroot 後 `apt-get install nodejs npm` 或解壓 Node 二進位）。
4. 在 base 內執行 `npm install -g <opencode-npm-package-name>`（或裝在 `/opt/opencode` 再做 symlink）。
5. 建立 `/opt/opencode/skills`，並在 base 預設設定裡寫入 opencode 的 skills 多路徑。
6. 清理後卸載 rootfs。

詳細指令與兩種安裝方式（全域 vs `/opt/opencode`）都在「如何將 opencode 安裝到 base rootfs 內（Step-by-Step）」一節。

---

## 9. opencode 來自 npm、支援多路徑

- 已寫入決策摘要：opencode 來自 **npm 套件**，並支援多路徑。
- 設定為：共用 `/opt/opencode/skills`、私有 `~/workspace/.skills`（見 Step 5 與「OpenCode 模式」）。

---

## 10. 先不考慮「opencode 在 guest 外當 API Server」

- 已寫入決策摘要與「OpenCode 模式」：**先不考慮**「opencode 在 host 當 API Server、guest 內僅 client」的架構；現階段與後續目標都是 **opencode 在 guest 內**（CLI → 之後 guest 內 API Server）。

---

**總結**：2～5 的說明已寫進文件並在上文摘要；1、5～10 的結論也都已更新到 `IMPLEMENTATION-PLAN-OPENCODE-VM.md`（含 pool 一律回收、依 user 建帳號、API key 注入、只從 host SSH、opencode 安裝步驟、npm 與多路徑、不採用 host API Server）。若你確認沒有要再改的決策，我就依這份計畫開始做實作（新建程式與所需腳本/設定）。

---

**User**

請將相關結論更新到 @IMPLEMENTATION-PLAN-OPENCODE-VM.md 並檢查是否有重複

---

**Cursor**


正在更新文件：對齊已確認結論、移除矛盾並合併重複段落。



檢查是否還有與「一律回收」矛盾的敘述，並合併重複的 SSH/連線說明。



在 Warm Pool 一節加入對「User 帳號與 API key 注入」的交叉引用，避免重複描述。



精簡 Phase 3，改為引用上文以避免重複。



已更新 `IMPLEMENTATION-PLAN-OPENCODE-VM.md` 並檢查重複，摘要如下：

---

## 已對齊的結論

1. **決策摘要表**  
   - 將「Pool」與「Warm pool」合併為一列「Pool / 回收」，並寫明：預先冷啟動 100 台、一律回收、pool 少一台即補啟一台。

2. **一律回收**  
   - 狀態圖：刪除「Recycle → Idle」，改為「Recycle → [*]：一律回收」；pool 補啟改為圖旁註解。  
   - Phase 2：改為「session 結束一律回收該 VM」，移除「依 pool 門檻決定回收或放回 pool」。  
   - Phase 3：改為引用「Warm Pool 與 VM 生命週期」，不再重複描述回收策略。  
   - TO-DO：改為「一律回收、補啟補足」，移除「VM 歸還 pool」與「歸還前清理」。

3. **新建程式**  
   - 「與現有程式對齊」改為「Firecracker API 要點（新建程式）」；TO-DO 改為「**新建**腳本」，不再提擴充 `fc-pro-bench-02.py`。

4. **一句話總結**  
   - 重寫為與目前結論一致：pool 一律回收、補啟、SSH 僅從 host 連、opencode 來自 npm 與多路徑、先不考慮 host API Server。

---

## 重複處理

| 位置 | 處理方式 |
|------|----------|
| 決策表「Pool」與「Warm pool」 | 合併為一列「Pool / 回收」。 |
| Guest 目錄規劃與 OpenCode 的 skills 路徑 | 目錄表保留；「opencode 預設可設定為」改為「預設設定見『OpenCode 模式』」，避免重複列舉。 |
| Warm Pool 與 User 帳號注入 | 在 Warm Pool 的「User 請求 VM 時」加註「（細節見『User 帳號與 API key 注入』）」以交叉引用。 |
| Phase 3 與 Warm Pool 回收描述 | Phase 3 改為引用「Warm Pool 與 VM 生命週期」，不再重寫回收邏輯。 |
| TO-DO「擴充 fc-pro-bench」與「VM 歸還 pool 清理」 | 改為「新建腳本」與「分配時 provisioning」，與一律回收一致。 |

---

目前文件已與「一律回收、pool 100 台、依 user 建帳號、僅 host 連、opencode 在 guest、新建程式」等結論一致，並已去掉與舊策略相關的重複與矛盾。

---

**User**

1. opencode 安裝文件可以參考網址 https://opencode.ai/docs/zh-tw/
2. 請注意，你的使用者是 linux 和 firecracker 的初學者。所有相關指令需要一步一步指導，並且說明。
3. 請開始實作

---

**Cursor**

### 實作進度說明

已依你的前提（Linux / Firecracker 初學者、參考 `https://opencode.ai/docs/zh-tw/`）開始 Phase 1 的實作，先完成「在 base rootfs 內安裝 OpenCode」這一塊，並用一步一步、有說明的腳本包起來。

---

### 目前已實作的內容

在專案新增了一支腳本：

- **檔案**：`scripts/build-base-rootfs-opencode.sh`  
- **用途**：  
  - 對一顆 ext4 rootfs 映像檔（例如你從 `bionic.rootfs.ext4` 複製來的 `base.rootfs.ext4`）做以下動作：  
    - 以 loop 方式掛載  
    - 建立 chroot 環境（/proc, /sys, /dev, /dev/pts）  
    - 在映像內安裝 **Node.js + npm**（如果還沒裝）  
    - 在映像內執行 `npm install -g opencode-ai`，安裝 OpenCode  
    - 建立共用 skills 掛載點：`/opt/opencode/skills`  
    - 清理暫存並安全卸載  
  - 全程每一步都有文字說明，適合照著看＋照著學。

---

### 如何一步一步使用這支腳本

1. **確認你在專案根目錄**

```bash
cd /home/chad/firecracker-260312
```

2. **先複製一份 rootfs 當 base（避免動到原始檔）**

```bash
cp bionic.rootfs.ext4 base.rootfs.ext4
```

說明：  
- `bionic.rootfs.ext4` 是原來給 Firecracker 用的基礎映像。  
- 我們建議不要直接改這顆，而是先複製一份 `base.rootfs.ext4` 來改。

3. **確保腳本有執行權限**

```bash
chmod +x scripts/build-base-rootfs-opencode.sh
```

4. **用 root 身份執行腳本**

```bash
sudo ./scripts/build-base-rootfs-opencode.sh base.rootfs.ext4
```

執行過程中會看到：

- Step 0：檢查參數、檔案存在與 root 權限。  
- Step 1：建立掛載目錄並用 `mount -o loop` 掛上映像。  
- Step 2：掛載 `/proc`、`/sys`、`/dev`、`/dev/pts`，讓 chroot 內的作業系統像真的在跑一樣。  
- Step 3：在 chroot 裡執行 `apt-get update && apt-get install -y nodejs npm`（若原本沒有 node/npm）。  
- Step 4：在 chroot 裡執行 `npm install -g opencode-ai`，安裝 OpenCode（指令 `opencode`）。  
- Step 5：建立 `mkdir -p /opt/opencode/skills`，將來 shared skills 映像會掛在這裡。  
- Step 7：清理 `apt` 的暫存、刪掉 chroot 內的 `resolv.conf`，再卸載所有掛載。

完成後，這顆 `base.rootfs.ext4`：

- guest 開機登入後，應該可以直接在 VM 內執行：

  ```bash
  opencode
  ```

- 而且已經有 ` /opt/opencode/skills` 目錄，之後我們會把 shared skills 映像掛在這裡。

---

### 下一步建議（之後會實作）

接下來會依照計畫繼續實作並同樣用「一步一步＋說明」的方式包裝：

1. **製作 shared skills 映像**（例如 `shared-skills.ext4`）＋對應掛載腳本。  
2. **製作 per-user workspace 映像**＋掛載策略。  
3. **新建 Firecracker 啟動腳本**：  
   - 指定三顆碟：rootfs（已含 opencode）、shared skills、workspace。  
   - 指定 tap 網路（讓 VM 之後可以上網、或連 host）。  
4. **最小版「啟動單台 VM + 用 SSH 登入 + 執行 opencode」流程**。

如果你這邊確認 `build-base-rootfs-opencode.sh` 的設計 OK（或想調整例如 node 安裝方式、opencode 版本、rootfs 檔名），我下一步就會開始實作「shared skills 映像 + 掛載腳本」，一樣會用初學者友善的分步說明來寫。

---

**User**

/code-reviewer @scripts/build-base-rootfs-opencode.sh  請重新分析專案目錄與檔案，剛才做了修改。 

---

**Cursor**


撰寫完整 code review 報告。



完成比對與審查，產出結構化報告並修正一項重要問題。



修正審查報告中的 Important #1：在掛載前檢查掛載點是否已被使用。



已完成對 `scripts/build-base-rootfs-opencode.sh` 的審查，並依審查結果做了修正與紀錄。摘要如下。

---

## 專案目錄與對照

- **腳本**：`scripts/build-base-rootfs-opencode.sh`（Phase 1：在 base rootfs 內安裝 OpenCode）
- **計畫**：`docs/IMPLEMENTATION-PLAN-OPENCODE-VM.md`（「如何將 opencode 安裝到 base rootfs 內」）
- **Benchmark**：`src/fc-pro-bench-02.py`、`src/fc-pro-bench.py`（本實作為新建，不依賴兩者）

---

## 1. Plan Alignment（與計畫對齊）

- 掛載 rootfs、chroot 準備、安裝 Node/npm、`npm install -g opencode-ai`、建立 `/opt/opencode/skills`、清理與卸載均與計畫一致。
- 唯一未實作的是「寫入預設 skills 路徑設定檔」；計畫也註明依 opencode 文件，目前以說明與連結取代，可接受。

---

## 2. Code Quality（程式品質）

- `set -euo pipefail`、參數/檔案/root/指令檢查、`trap cleanup EXIT` 與卸載順序均正確。
- 步驟說明足夠，適合初學者依序操作；Step 3/4 具冪等（已安裝則略過）。

---

## 3. 已修正項目（依審查建議）

| 項目 | 處理方式 |
|------|----------|
| **Important：掛載點已在使用** | 在 Step 1 掛載前以 `mountpoint -q` 檢查；若已掛載則先卸載（子掛載點→本體），失敗則提示 `sudo umount /mnt/opencode-rootfs`。 |
| **Suggestion：計畫引用** | 檔頭加入「實作對應：docs/IMPLEMENTATION-PLAN-OPENCODE-VM.md『如何將 opencode 安裝到 base rootfs 內』」。 |
| **Suggestion：bionic / Node 版本** | 使用前必讀第 3 點註明：bionic 的 apt nodejs 可能過舊，若 OpenCode 需較新 Node 請改用 NodeSource 或 tarball。 |
| **Suggestion：skills 設定** | Step 6 補上官方文件連結，並說明「待確認設定檔格式後寫入 /etc/opencode/config 或 template」。 |

---

## 4. 剩餘建議（可之後補上）

- **Important #2**：若實際採用 bionic，可在腳本中加入「選用」邏輯（例如環境變數）改為以 NodeSource 或 Node 官方 tarball 安裝較新 Node，避免 OpenCode 因 Node 過舊無法使用。

---

## 5. 產出檔案

- **`docs/CODE-REVIEW-build-base-rootfs-opencode.md`**：完整審查報告（Plan alignment、Code quality、Architecture、Documentation、Issues 分級與建議、修正後狀態）。
- **`scripts/build-base-rootfs-opencode.sh`**：已套用上述修正（掛載前檢查、檔頭說明、Step 6 連結與註解）。

目前腳本可視為通過本次審查，並作為 Phase 1「製作含 opencode 的 base rootfs」的基準版本；若你之後要支援 bionic + 新 Node，再補環境變數與 NodeSource/tarball 邏輯即可。

---

**User**

"Suggestion：bionic / Node 版本" 這個問題，改成使用 "curl -fsSL https://opencode.ai/install | bash" 安裝指令是否可以解決?

---

**Cursor**

### 短答

**大致上可以，而且對「bionic / Node 版本過舊」這個問題是有效的解法。**

---

### 為什麼可以解決？

官方文件的安裝建議是：

```bash
curl -fsSL https://opencode.ai/install | bash
```

這支安裝腳本的特點通常是：

- 自己決定要裝哪種形式的 OpenCode（二進位或適合的套件），**而不是依賴系統現有的 node/npm 版本**。
- 會根據偵測到的環境幫你選擇合適的安裝方式，並處理 PATH / binary 放置位置。

如果我們在 **chroot 進 rootfs 裡面**，執行的就是 rootfs 內的 `bash` 和 `curl`，安裝腳本看到的是「guest 裡的環境」，會直接把 OpenCode 安裝到那個檔案系統。這樣就不再受限於：

- `apt-get install nodejs npm` 給的 Node 版本（例如 bionic 上的舊 Node）
- 你手動維護 node/npm 的版本問題

所以，將 Step 3/4 改成：

1. 在 chroot 裡先裝好 `curl`（如果沒有）：
   ```bash
   apt-get update
   apt-get install -y curl
   ```
2. 再在 chroot 裡跑：
   ```bash
   curl -fsSL https://opencode.ai/install | bash
   ```

理論上就可以讓 OpenCode 用它「官方支援」的方式安裝，繞開 bionic / Node 版本的問題。

---

### 需要注意的點

- **rootfs 內要有 curl + bash**：  
  - 多數 Debian/Ubuntu 類映像都會有 `bash`，但 `curl` 可能要你先用 `apt-get install -y curl`。
- **網路與 DNS**：  
  - 你目前腳本已經在 chroot 內掛了 `/proc`、`/sys`、`/dev` 並複製 `resolv.conf`，可以連外應該沒問題，這是安裝腳本成功的前提。
- **安裝位置與設定**：  
  - 官方安裝腳本可能會把 binary 放在 `/usr/local/bin` 或某個自訂目錄，也可能會幫你改 shell 設定檔（`~/.bashrc` 等）。這些都會發生在 rootfs 裡面，是你想要的行為，但未必和現在 `npm -g opencode-ai` 完全一樣。  
  - 之後在文件裡，要把「OpenCode 安裝方式」改成「透過官方 install script」，而不是「npm -g」。

---

### 建議做法

如果你想**徹底解掉 bionic + Node 版本問題，並且跟官方文件一致**，下一步可以把腳本這兩段調整成：

- Step 3：只安裝最小依賴（例如 `curl`，必要時加 `ca-certificates`）。
- Step 4：在 chroot 裡執行 `curl -fsSL https://opencode.ai/install | bash`，不再自己 `npm install -g opencode-ai`。

這樣基本上就可以不用再擔心「bionic 的 Node 太舊」這個 issue。

---

**User**

1. opencode 的 skills 目錄在 "~/.config/opencode/skills" (用來放 RO skills)。並且在專案目錄下可以建立 "project/skills" (用來放 專案、私有 skills)
2. 請實作建議做法。並更新對應文件


---

**Cursor**

Now update script to use curl installer, adjust comments, and update docs to switch skills paths to ~/.config/opencode/skills and project/skills, plus installation section to describe curl|bash instead of npm.

Script now uses curl-based official OpenCode installer, and prepares ~/.config/opencode/skills via /root and /etc/skel. Next I’ll align the design doc to use ~/.config/opencode/skills for RO skills and project/skills for per-project skills instead of /opt/opencode/skills and ~/workspace/.skills.

### 回覆你的兩點

1. **skills 路徑調整**  
   - 已將設計與實作改成符合你提供的 OpenCode 規則：  
     - **RO 共用 skills**：`~/.config/opencode/skills`（每個 user 的 home 下，由平台掛載 shared skills 映像）。  
     - **專案 / 私有 skills**：每個專案目錄下的 `project/skills`（例如 `~/workspace/my-project/skills`）。  
   - 在 `IMPLEMENTATION-PLAN-OPENCODE-VM.md` 中已更新：Guest 內目錄規劃、Firecracker API 掛載說明、OpenCode 模式說明、TO-DO List 都改成這兩個路徑組合。

2. **實作建議做法 + 更新文件**  
   - `scripts/build-base-rootfs-opencode.sh` 已改為使用 **官方 install script** 安裝 OpenCode：  
     - Step 3：在 chroot 內安裝 `curl`（若尚未安裝），用 `apt-get install -y curl`。  
     - Step 4：在 chroot 內執行 `curl -fsSL https://opencode.ai/install | bash`，安裝 OpenCode；若已存在 `opencode` 指令則略過。  
     - Step 5：建立 RO skills 預設目錄：  
       - `/root/.config/opencode/skills`（root 用）  
       - `/etc/skel/.config/opencode/skills`（未來新建 user 的 home，`useradd -m` 時會自動帶入 `~/.config/opencode/skills`）。  
   - `docs/IMPLEMENTATION-PLAN-OPENCODE-VM.md` 已同步更新：  
     - 安裝章節改寫為「在 chroot 內安裝 curl → 執行 `curl -fsSL https://opencode.ai/install | bash`」。  
     - skills 章節明確說明：共用 RO skills 在 `~/.config/opencode/skills`，專案 skills 在 `project/skills`。  
     - Firecracker 掛載與 TO-DO 也改成掛載 shared skills 映像到各 user 的 `~/.config/opencode/skills`，不再使用 `/opt/opencode/skills` 或 `~/workspace/.skills`。

---

**User**

@\home\chad\.cursor\projects\home-chad-firecracker-260312\terminals\1.txt:13-75  curl 的 error 是什麼原因?

---

**Cursor**

### 錯誤原因說明

終端輸出關鍵訊息是：

```text
curl: (77) error setting certificate verify locations:
  CAfile: /etc/ssl/certs/ca-certificates.crt
  CApath: /etc/ssl/certs
```

代表：

- 在 **chroot 內的 rootfs** 裡，`curl` 想要做 HTTPS 連線（`https://opencode.ai/...`）時，需要一份 **CA 憑證檔**（`/etc/ssl/certs/ca-certificates.crt`）。
- 但這顆 rootfs 裡 **沒有安裝 CA 憑證套件**，所以 `curl` 找不到憑證檔與憑證目錄，導致無法驗證 HTTPS 憑證，直接報錯「error setting certificate verify locations」。

換句話說：  
**rootfs 裡的 Linux 還是「很乾淨的最小系統」，只有 curl，沒有安裝 `ca-certificates` 這類套件，所以 curl 在 chroot 內做 HTTPS 時沒有信任的 CA。**

---

### 下一步會幫你做的事（修正方向）

要解決這個錯誤，有兩種正規方法（我們會走第 1 種）：

1. **在 chroot 裡安裝 CA 憑證套件（建議做法）**  
   - 在腳本的 Step 3/4 之間，加一個小步驟，於 chroot 執行類似：
     ```bash
     apt-get update
     DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates
     update-ca-certificates || true
     ```
   - 讓 rootfs 內的 `/etc/ssl/certs/ca-certificates.crt` 與 `/etc/ssl/certs` 被建立好，`curl` 就能正常驗證 HTTPS 憑證。

2. **綁定 host 的 `/etc/ssl/certs` 進 chroot（不如 1 乾淨）**  
   - 在 host 上 `mount --bind /etc/ssl/certs "$MNT/etc/ssl/certs"`。  
   - 這樣 chroot 內就直接用 host 的 CA 憑證。  
   - 不過這會讓 rootfs 對 host 有依賴性，沒有第 1 種乾淨。

我們會採用 **第 1 種：在 rootfs 裡安裝 `ca-certificates`**，之後你再跑一次：

```bash
sudo ./scripts/build-base-rootfs-opencode.sh bin/base.rootfs.ext4
```

`curl` 就能在 chroot 內順利跑 `https://opencode.ai/install` 了。

---

**User**

繼續

---

**Cursor**

### 已針對 curl 錯誤完成修正

我在 `scripts/build-base-rootfs-opencode.sh` 做了這些調整：

- **Step 3 調整為同時安裝 `curl` 與 `ca-certificates`**：
  - 說明文字改為：
    - 需要 `curl` 下載 `https://opencode.ai/install`
    - 也需要 `ca-certificates` 提供 `/etc/ssl/certs/ca-certificates.crt`，讓 `curl` 能驗證 HTTPS 憑證。
  - chroot 內實際執行改為：

    ```bash
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
    if command -v update-ca-certificates >/dev/null 2>&1; then
      update-ca-certificates || true
    fi
    ```

  - 並以條件判斷：只要 `curl` 不存在 **或** 沒有 `ca-certificates.crt` 就會執行上述安裝。

這樣 `curl` 在 chroot 內再呼叫 `https://opencode.ai/install` 時，就不會再因為找不到 CA 憑證而噴 `(77)` 錯誤。

### 接下來請你重新執行一次腳本

在專案根目錄下：

```bash
cd /home/chad/firecracker-260312
sudo ./scripts/build-base-rootfs-opencode.sh bin/base.rootfs.ext4
```

如果執行過程中還有新的錯誤訊息（特別是 Step 4 那段 `curl -fsSL ... | bash`），再把那一段貼出來，我會繼續幫你排查。

---

**User**

@\home\chad\.cursor\projects\home-chad-firecracker-260312\terminals\1.txt:76-123 

---

**Cursor**

### 這段錯誤在說什麼？

關鍵訊息：

```text
Reading package lists... Error!
E: flAbsPath on /var/lib/dpkg/status failed - realpath (2: No such file or directory)
E: Could not open file  - open (2: No such file or directory)
E: Problem opening 
E: The package lists or status file could not be parsed or opened.
```

意思是：

- 我們在 **chroot 進去 rootfs 裡面** 執行了：

  ```bash
  apt-get update
  apt-get install -y curl ca-certificates
  ```

- 但這顆 `bin/base.rootfs.ext4`（來自官方 `bionic.rootfs.ext4`）是給 Firecracker 用的 **超精簡 rootfs**，裡面 **沒有完整的 dpkg/apt 資料庫**（`/var/lib/dpkg/status` 不存在）。
- 對這種「minimal rootfs」，`apt-get` 沒辦法正常運作，所以直接在 chroot 裡跑 `apt-get` 會失敗，出現你看到的錯誤。

換句話說：  
**這顆 rootfs 裡根本沒有準備好當一般 Ubuntu 的 package-based 環境，我們不能在裡面用 apt 安裝 curl / ca-certificates。**

---

### 下一步要怎麼辦？（不要急著改，先說清楚選項）

我們現在有兩條路可以選（需要你選一條，我再幫你實作）：

#### 方案 A：換成「有 apt 的 rootfs」當 base

- 例如：使用 Ubuntu cloud image、或自己做一顆「完整一點」的 Ubuntu-rootfs 當 base。
- 優點：
  - 在 chroot 裡可以正常 `apt-get install curl ca-certificates`，甚至未來還可以 `apt install` 其他套件。
  - 架構比較乾淨、可維護。
- 缺點：
  - 要換 rootfs 來源（不是現在這顆 Firecracker demo 用的 bionic rootfs）。

#### 方案 B：不要在 chroot 裡跑 apt，改成「從 host 複製現成的工具進 rootfs」

- 作法概念：
  - 在 **host** 裡已經有 `curl` 和 `/etc/ssl/certs/...`。
  - 腳本改成：在掛載好 rootfs 後，直接把 host 的 `/usr/bin/curl`、`/etc/ssl/certs` 複製進 `${MNT_DIR}` 對應的位置。
- 優點：
  - 不需要在 rootfs 裡用 apt。
  - 保留目前這顆 bionic rootfs。
- 缺點：
  - rootfs 內的 curl / CA 憑證跟 host 綁在一起（host 升級可能有 ABI/相容性問題，但在一般 x86_64 Linux 上多半是可行的 hack）。

---

### 建議你怎麼選？

考量你目前是：

- Firecracker + WSL2 的實驗環境
- 重心在「VM 內能跑 OpenCode + skills」
- 這顆 rootfs 原本就是官方 Firecracker quickstart 用的精簡 bionic

我會建議：

- **短期（實驗 / PoC）**：採用 **方案 B**，從 host 複製 `curl + CA` 進 rootfs，讓我們可以先把「VM 內跑得動 opencode」這件事打通。
- **之後若要穩定長期運作**：再考慮改成 **方案 A**，選一顆正式的 Ubuntu cloud image 當 base，讓 VM 內有完整 apt 環境。

---

### 請你先選擇

你先告訴我：

- 你現在要：  
  1）**維持這顆 bionic.rootfs.ext4**，用「從 host 複製 curl+CA 進去」的方式（方案 B），  
  還是  
  2）**換一顆比較完整的 Ubuntu rootfs** 當 base（方案 A）？

我會依你選的方案，直接幫你：

- 修改 `build-base-rootfs-opencode.sh` 對應的實作方式
- 同時更新 `IMPLEMENTATION-PLAN-OPENCODE-VM.md` 裡「安裝 OpenCode 到 base rootfs」那一節的步驟說明。

---

**User**

1. host 的 /usr/bin/curl (是空目錄)、/etc/ssl/certs (有很多連結檔)
2. 採用 方案 B

---

**Cursor**

我會把腳本改成「偵測 rootfs 沒有 apt/dpkg 資料庫時，改用從 host 複製 curl + 依賴的 shared libraries + CA 憑證」這條路，讓 bionic 精簡 rootfs 也能跑 `https://opencode.ai/install`。同時把 Step 6 舊的 skills 路徑說明更新成你指定的 `~/.config/opencode/skills` 與 `project/skills`。

### 已改成「方案 B」並修好你遇到的 apt/dpkg 問題

你剛剛遇到的錯誤：

- `E: flAbsPath on /var/lib/dpkg/status failed ...`

代表這顆 Firecracker quickstart 的 `bionic.rootfs.ext4` **太精簡**，沒有 apt/dpkg 的資料庫，因此 **不能在 chroot 裡用 apt 安裝套件**。

所以我已把 `scripts/build-base-rootfs-opencode.sh` 改成：

- **若 rootfs 內 apt/dpkg 可用** → 走 apt 安裝（乾淨路徑）
- **若 rootfs 內 apt/dpkg 不可用（你現在的情況）** → 自動改走 **方案 B：從 host 複製 curl + curl 需要的 shared libraries + CA 憑證** 到 rootfs  
  - `curl`：複製 host 的 `/usr/bin/curl`  
  - `shared libraries`：用 host `ldd /usr/bin/curl` 列出所有 `/lib/...`、`/usr/lib/...`，逐一複製到 rootfs 同路徑  
  - `CA`：複製 `/etc/ssl/certs/ca-certificates.crt`，並用 `cp -aL /etc/ssl/certs` 把大量 symlink「跟隨成實體檔」複製進 rootfs

同時也把腳本內 Step 6 的 skills 路徑說明更新為你指定的：

- **RO skills**：`~/.config/opencode/skills`
- **專案 skills**：`project/skills`

並修正腳本結尾輸出的摘要（不再寫 npm/node 舊訊息）。

---

### 文件也已更新

`docs/IMPLEMENTATION-PLAN-OPENCODE-VM.md` 已加入「初學者常見坑」說明：

- 若 apt/dpkg 不可用（缺 `/var/lib/dpkg/status`）就會炸
- 改用 **方案 B（從 host 複製 curl + CA）**
- 並註明本專案已用 `scripts/build-base-rootfs-opencode.sh` 把方案 B 變成可直接跑的步驟

---

### 下一步你可以直接再跑一次腳本

```bash
cd /home/chad/firecracker-260312
sudo ./scripts/build-base-rootfs-opencode.sh bin/base.rootfs.ext4
```

這次在 Step 3 會自動走「方案 B 複製」而不是 apt；接著 Step 4 的：

- `curl -fsSL https://opencode.ai/install | bash`

應該就能正常執行了。

如果 Step 4 還有新錯誤（例如下載被擋、權限、或安裝位置），把 Step 4 的輸出貼上來，我會繼續帶你排。

---

**User**

@\home\chad\.cursor\projects\home-chad-firecracker-260312\terminals\1.txt:124-158 

---

**Cursor**

這個錯誤是「rootfs 內已存在一個『斷掉的 symlink』」，`cp` 不願意覆寫它。我要把複製函式改成：若目標是 dangling symlink 就先刪掉，再複製實體檔，讓方案 B 可以順利把 `ld-linux-x86-64.so.2` 等庫檔放進 rootfs。

### 這個錯誤原因是什麼？

你看到的：

```text
cp: not writing through dangling symlink '/mnt/opencode-rootfs/lib64/ld-linux-x86-64.so.2'
```

意思是：

- 在 **rootfs 映像**裡，`/lib64/ld-linux-x86-64.so.2` 這個路徑**已經存在**，但它是一個 **斷掉的 symlink（dangling symlink）**：指向的目標檔不存在。
- 我們方案 B 在複製 curl 依賴的 shared libraries 時，想把 host 的 `ld-linux-x86-64.so.2` 複製進去，但 `cp` 不會「穿透」去覆寫一個已經壞掉的 symlink，所以直接報錯退出。

---

### 我已修好

在 `scripts/build-base-rootfs-opencode.sh` 的 `_copy_file_with_dirs()` 裡新增處理：

- **如果目的地是 dangling symlink，就先 `rm -f` 刪掉它**
- 再把實體檔複製進 rootfs

這樣就能順利把 `ld-linux-x86-64.so.2` 等檔案放進去。

---

### 下一步你要做什麼？

請你再跑一次同一個指令：

```bash
cd /home/chad/firecracker-260312
sudo ./scripts/build-base-rootfs-opencode.sh bin/base.rootfs.ext4
```

如果接下來又卡在「複製其他 library」或 Step 4 的 `curl ... | bash`，把新的錯誤輸出貼出來，我會繼續往下排到成功安裝 OpenCode。

---

**User**

@\home\chad\.cursor\projects\home-chad-firecracker-260312\terminals\1.txt:159-209 

---

**Cursor**

你現在遇到的是「把 host 的 glibc/threads 函式庫複製進 rootfs」造成 ABI 不相容，導致 rootfs 內任何程式（連 `mkdir`）都跑不動。接下來我會把方案 B 改成**只複製 CA 憑證，不複製 curl 與 shared libraries**，並補上檢查：rootfs 內若沒有自己的 curl 就直接停下給明確指引；同時你需要先用乾淨的 rootfs 重新來過。

### 你現在這個錯誤是什麼原因？

你貼的錯誤：

```text
curl: symbol lookup error: /lib/x86_64-linux-gnu/libpthread.so.0: undefined symbol: __libc_vfork, version GLIBC_PRIVATE
mkdir: symbol lookup error: /lib/x86_64-linux-gnu/libpthread.so.0: undefined symbol: __libc_vfork, version GLIBC_PRIVATE
```

這代表：

- 我們先前「方案 B」把 **host 的 shared libraries（包含 glibc 相關檔）**複製進了 rootfs。
- 但 rootfs 內原本的 glibc 版本/佈局與 host 不一致，導致 `libpthread.so.0` 在載入時找不到 `GLIBC_PRIVATE` 的符號，結果 rootfs 裡的程式（連 `mkdir`）都壞掉了。

結論：**不能把 host 的 glibc / shared libraries 複製進 rootfs**。

---

### 我已改成正確的「方案 B」（不會再碰 glibc）

我已更新 `scripts/build-base-rootfs-opencode.sh`：

- **方案 B 改成：只複製 CA 憑證，不複製 curl、不複製任何 shared libraries**
- 並新增檢查：
  - 如果 rootfs 內**沒有自己的 curl**，又**不能 apt 安裝** → 腳本會停止並給你清楚的下一步（換完整 rootfs 或提供靜態 curl）

同時也更新 `docs/IMPLEMENTATION-PLAN-OPENCODE-VM.md` 的「方案 B」說明，強調：
- **只複製 CA 憑證**
- **避免複製 host 的 glibc / shared libraries**（會炸）

---

### 你接下來要先做的一件事：重新製作乾淨的 base rootfs

因為你先前那次已經把 rootfs 裡的 library 弄壞了，所以必須先重來一份乾淨的 base（這一步很重要）。

在專案根目錄執行：

```bash
cd /home/chad/firecracker-260312

# 建議直接重新複製一份乾淨的 base
cp bionic.rootfs.ext4 bin/base.rootfs.ext4
```

說明：
- 這會把原本乾淨的 `bionic.rootfs.ext4` 覆蓋成新的 `bin/base.rootfs.ext4`
- 讓我們從乾淨狀態開始，不會被剛剛壞掉的 glibc 影響

---

### 然後再跑一次腳本

```bash
sudo ./scripts/build-base-rootfs-opencode.sh bin/base.rootfs.ext4
```

這次流程會是：

- Step 3：偵測 apt/dpkg 不可用 → **只複製 CA 憑證**（不動 glibc）
- Step 4：用 rootfs 內的 curl 跑 `https://opencode.ai/install` 安裝 OpenCode

你跑完後，如果 Step 4 又有錯誤（例如 curl 連線、TLS、或 install script 內部錯誤），直接把 Step 4 的那段輸出貼上來，我會繼續帶你把 OpenCode 成功裝進 rootfs。

---

**User**

1. 改成方案A: 選一顆正式的 Ubuntu cloud image 當 base，讓 VM 內有完整 apt 環境。
2. 為什麼 base.rootfs.ext4 和 bionic.rootfs.ext4 一樣大小 ?

---

**Cursor**

## 1. 改成方案 A：用正式 Ubuntu cloud image 當 base（讓 apt 完整可用）

你要達成的目標是：**rootfs 內要有完整的 `dpkg/apt`（含 `/var/lib/dpkg/status`）**，這樣你才能在 VM 內（或 chroot 內）用 `apt-get install ...` 安裝 `curl/ca-certificates/openssh-server/node` 等套件。

### TO-DO List
- 選定 Ubuntu 版本（建議 `22.04 jammy` 或 `24.04 noble`）
- 下載對應的 cloud image（通常是 `qcow2`）
- 轉成 Firecracker 好用的 rootfs 形式（`raw`/`ext4`）
- 擴容 rootfs（避免空間不夠）
- 把 VM 可登入能力做起來（至少 sshd + user）
- 再回到安裝 OpenCode（用 `curl -fsSL https://opencode.ai/install | bash`）

### 關鍵提醒（先講清楚差異）
- **cloud image 常見格式是 `qcow2`**，但 Firecracker 最常用的是 **block device + rootfs**（raw/ext4）。所以需要「**下載 → 轉換 → 擴容/修檔案系統**」這段。

### 最小可行步驟（一步一步）
下面以 Ubuntu 22.04 為例（你要換 24.04 也可以，流程相同）。

1) 安裝轉換工具（在 host / WSL2）
```bash
sudo apt-get update
sudo apt-get install -y qemu-utils
```
說明：`qemu-img` 在 `qemu-utils` 裡，用來轉 qcow2 → raw。

2) 下載 Ubuntu cloud image（qcow2）
（你要哪個版本我之後可幫你固定 URL；先示範流程）
```bash
mkdir -p bin/images
cd bin/images
# 例：jammy cloudimg（實際 URL 後續會固定在文件/腳本）
wget -O ubuntu-jammy.qcow2 "<Ubuntu cloud image qcow2 URL>"
```

3) 轉換成 raw
```bash
qemu-img convert -f qcow2 -O raw ubuntu-jammy.qcow2 ubuntu-jammy.raw
```

4) 擴大 raw 檔案（例如 +10G）
```bash
qemu-img resize ubuntu-jammy.raw +10G
```

5) **把 raw 內的 ext4 檔案系統做 grow**
這步要能「掛載/操作」raw 裡的 partition/檔案系統。常見做法是 `qemu-nbd` 或 `libguestfs`。
- 在 WSL2 上 `nbd` 有時會不方便（kernel/module 限制），因此我會建議改用 **libguestfs-tools**（比較不依賴 kernel module）：

```bash
sudo apt-get install -y libguestfs-tools
```

接著用 `virt-resize` / `guestfish` 來 grow 與修改 rootfs（這段我會在你確認版本後，直接給你可跑的「固定指令」或寫成腳本，避免你踩 libguestfs 語法坑）。

6) 讓 VM 可登入（sshd + user）
- cloud image 通常搭配 cloud-init 注入 user/ssh key；但你也可以直接把 rootfs 掛載後在裡面 `apt-get install openssh-server`、建立 user、寫 `authorized_keys`。
- 因為你要「每台 VM 依 user 建帳號」，我會建議：base image 只確保 `sshd` 可用 + 有一個 provisioning 用的管理入口（例如 root 可用 key），分配時再建 user。

你確認 Ubuntu 版本（22.04 或 24.04）後，我下一步會把以上流程做成：
- `scripts/prepare-ubuntu-cloud-rootfs.sh`（完整一步一步含說明）
- 並同步更新 `docs/IMPLEMENTATION-PLAN-OPENCODE-VM.md`

---

## 2. 為什麼 `base.rootfs.ext4` 和 `bionic.rootfs.ext4` 一樣大小？

因為你做的是「**檔案層級的複製**」（例如 `cp bionic.rootfs.ext4 base.rootfs.ext4`）：

- **ext4 映像檔本質上是一個固定大小的“虛擬磁碟檔”**  
- `cp` 會把整個檔案逐位元複製，所以 **檔案大小會一模一樣**
- 這跟「映像檔裡面實際用了多少空間」是兩回事：  
  - 映像檔內可能只用到一小部分，其餘都是空的 blocks（但檔案容器大小仍固定）

你可以用這個觀念理解：
- **`ls -lh *.ext4` 看到的是容器大小**
- **在 VM 內 `df -h` 看到的是檔案系統可用/已用空間**

如果你希望 base rootfs “容量變大”，要做的是：
- 擴大檔案容器（例如 `truncate` / `qemu-img resize`）
- 再對 ext4 做 grow（`resize2fs` 或用 guestfish/virt-resize）

---

## 你先回覆我兩個選項（我就直接開始把方案 A 做成可跑腳本）
- **Ubuntu 版本**：你要 `22.04 (jammy)` 還是 `24.04 (noble)`？
- **你希望 rootfs 最終大小**：例如 10GB / 20GB？（會影響 resize 指令與後續空間）

---

**User**

 Ubuntu 版本 24.04
寫成腳本
---
+ 從 UGPTs 連接，使用者不會直接使用 mircoVM (只有測試階段需要驗證時會由我用到 SSH。使用者不會用到 SSH，所以不需要 SSH)
+ opencode 以API 方式提供服務(opencode serve --port 4096)，重點在每個人獨有的工作空間(session/workspace)
+ 完整的 skills 需要支援 scripts (JS/Python)。因此要有能力執行並下載 package
+ opencode 啟動時間需要測試驗證

---

**Cursor**

我會先確認 Ubuntu 24.04 是否有「官方 root tarball」可直接做成單一 ext4 rootfs（最適合 Firecracker），接著寫成一鍵腳本：下載→建立 ext4→解包→chroot 安裝 opencode 與必要工具→產出可用 rootfs。

我會新增一支「方案 A / Ubuntu 24.04（noble）正式 base rootfs」的一鍵腳本：從官方 `noble-server-cloudimg-amd64-root.tar.xz` 產生可用的 `ext4 rootfs`，在 chroot 內用 apt 安裝 JS/Python 工具鏈與 OpenCode，並預先放好 `~/.config/opencode/skills` 的 skeleton。接著同步更新 `IMPLEMENTATION-PLAN-OPENCODE-VM.md`，把 base rootfs 的來源與安裝流程改為方案 A。

### 已切換成方案 A（Ubuntu 24.04 noble）並寫成腳本 + 更新文件

你要求的方向（正式 Ubuntu cloud base、完整 apt、支援 JS/Python scripts、opencode 以 API 提供、需要量測啟動時間）我已先完成 **base rootfs 產生腳本** 與 **計畫文件同步更新**。

---

## 1) 新增腳本：產生 Ubuntu 24.04 base rootfs（有完整 apt/dpkg）

已新增：

- `scripts/prepare-ubuntu-noble-rootfs.sh`

它會一步一步做到：

- 下載 Ubuntu 24.04 的 root tarball（官方來源）  
  `noble-server-cloudimg-amd64-root.tar.xz`（來自 `cloud-images.ubuntu.com/noble/current/`）
- 建立一顆 **單一 ext4 rootfs**（適合 Firecracker）
- 掛載後解壓 rootfs
- chroot 進去用 apt 安裝：
  - `curl`, `ca-certificates`（HTTPS）
  - `git`
  - `python3`, `pip`, `venv`
  - `nodejs`, `npm`
  - `build-essential`（編譯 native dependencies）
- 在 rootfs 內跑官方安裝：
  - `curl -fsSL https://opencode.ai/install | bash`
- 建立 skills skeleton（符合你新規則）：
  - `~/.config/opencode/skills`（透過 `/etc/skel` 讓新 user 自動有）

---

## 2) 計畫文件已更新（符合你最新需求）

已更新：

- `docs/IMPLEMENTATION-PLAN-OPENCODE-VM.md`

重點改動：

- **Base rootfs**：改為 Ubuntu 24.04 noble 正式 cloud rootfs（完整 apt/dpkg）
- **OpenCode**：改成「主要用 API Server」`opencode serve --port 4096`
- **SSH**：標記為「僅測試/驗證用」，一般使用者不需 SSH
- **skills 目錄**：維持你指定的
  - RO：`~/.config/opencode/skills`
  - 專案：`project/skills`
- **TO-DO**：新增「量測 opencode 啟動時間」

---

## 3) 你問的「接下來怎麼跑」

產生 base rootfs（建議先做 12GB）：

```bash
cd /home/chad/firecracker-260312
sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 12
```

---

## 4) 下一步（我會繼續實作）

你接下來的需求核心是「opencode API per-user workspace/session」，以及「啟動時間測試驗證」。下一步我會開始做：

- 新建「啟動單台 VM」的腳本（用新的 noble base rootfs）
- 新建「在 VM 內啟 opencode serve:4096」並由 host 檢測 readiness 的測試腳本
- 把「opencode 啟動時間」記錄成可重跑的 benchmark（同一台機器上可比較）

你先跑一次 `prepare-ubuntu-noble-rootfs.sh`；如果中途遇到任何 apt / install script 失敗，把終端輸出貼上來，我會直接幫你修到能成功產出 rootfs。

---

**User**

為什麼 bionic.rootfs.ext4 size只有 3百多M，但 ubuntu-noble-base.rootfs.ext4 卻要 12G ?

---

**Cursor**

### 為什麼一個 300+MB、一個 12GB？

可以分兩層來看：「檔案本身的大小」和「裡面放了多少東西」。

---

### 1. `bionic.rootfs.ext4`：極度精簡的 demo rootfs

- 這顆是 Firecracker 官方 quickstart 用的 **最小 rootfs**：
  - 幾乎只有最基本的 userspace + 必要工具
  - 沒有完整 apt/dpkg 資料庫
  - 沒有開發工具、沒有 JS/Python toolchain、沒有 git、沒有 build-essential
- 所以整個 ext4 映像本身只有 **幾百 MB 等級**，適合「啟 VM 跑個 demo」，不適合當「可以長期安裝套件、跑 scripts 的開發環境」。

---

### 2. `ubuntu-noble-base.rootfs.ext4`：預留給「完整開發環境」用的容量

你現在的需求是：

- opencode 以 `serve`（API）方式跑
- skills 要能執行 JS / Python，**還會裝 npm/pip packages**
- VM 內要有 **完整 apt 環境**，可以隨時再裝工具
- 每人有自己的 workspace，裡面會有專案、快取、依賴

為了避免：

- 一開始 rootfs 做得太小，之後 npm/pip/apt 一裝就「磁碟爆滿」
- 之後還要再做麻煩的「擴容 + resize2fs」

我在腳本預設先抓了一個偏寬鬆的值：**`--size-gb 12`**  
這代表：

- ext4 「容器」大小先給你 **12GB 上限**
- 實際已使用空間（裡面裝的東西）會少很多，但有夠大的頭room 給未來的 apt/npm/pip 安裝。

你可以自己調整，例如：

```bash
sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 6
```

如果你覺得：

- 這顆 VM 不會放大專案、不會安裝太多東西
- 或你只是先做概念驗證

那可以改成 4G / 6G 之類的值。  
只是要記得：**越小，之後能裝的東西越少**，將來遇到「磁碟滿了」時就得再做一次擴容流程。

---

### 一句話總結

- `bionic.rootfs.ext4` 是「只夠 demo 的超精簡 rootfs」，所以幾百 MB。
- `ubuntu-noble-base.rootfs.ext4` 是「預留給完整 JS/Python/apt 開發環境 + user workspace」用的 rootfs，12GB 只是你現在抓的「上限容量」，不是實際已用空間；你可以依需求把 `--size-gb` 調小，但要在「未來會裝多少東西」和「磁碟空間」之間取捨。

---

**User**

繼續實作

---

**Cursor**

先補上兩個基礎腳本，讓後面的 API / 啟動時間測試有穩定基礎：

- `prepare-ubuntu-noble-rootfs.sh`：已能下載 Ubuntu 24.04 root tarball、建立 ext4 rootfs、chroot 安裝 curl/JS/Python/build-essential、執行 `opencode` 官方安裝、建立 `~/.config/opencode/skills` skeleton。
- `run-noble-vm-with-opencode.sh`：新增一支最小化啟動腳本，會用你指定的 `vmlinux` + `ubuntu-noble-base.rootfs.ext4` 啟一台 Firecracker VM，設好 tap 網路與 rootfs，後續再接「VM 內自動跑 `opencode serve --port 4096` + host 端量測啟動時間」的部分。

---

**User**

新建「啟動單台 VM」的腳本（用新的 noble base rootfs）
新建「在 VM 內啟 opencode serve:4096」並由 host 檢測 readiness 的測試腳本
把「opencode 啟動時間」記錄成可重跑的 benchmark（同一台機器上可比較）

---

**Cursor**

### 已完成你要的三項實作（腳本層級）

1. **啟動單台 VM（用 noble base rootfs）**

- 新增：`scripts/run-noble-vm-with-opencode.sh`  
- 功能：
  - 檢查 `--kernel`（vmlinux）、`--rootfs`（例如 `bin/ubuntu-noble-base.rootfs.ext4`）、`FC_BINARY`/`firecracker`、`/dev/kvm`
  - 建立 tap：`fc-<vm-id>`，host IP 預設 `172.30.0.1/24`
  - 啟動 Firecracker，設定：
    - `boot-source`：你給的 kernel
    - `drives/rootfs`：給 noble base rootfs（RW）
    - `network-interfaces/eth0`：綁 tap 裝置
  - 呼叫 `InstanceStart`，VM 開機

> 注意：`VM_IP=172.30.0.2` 是腳本裡的預設，**必須跟 VM 內的 netplan/cloud-init 設定一致**，之後你設定 guest IP 時要對齊這個值，host 才能成功打到 `:4096`。

---

2. **在 VM 內啟 `opencode serve:4096`（開機自動）**

- 在 `scripts/prepare-ubuntu-noble-rootfs.sh` 裡新增：

  - 用 apt 安裝完 core 工具與 OpenCode 後，建立 systemd 服務：

    ```ini
    [Unit]
    Description=OpenCode API Server
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/opencode serve --port 4096 --host 0.0.0.0
    Restart=on-failure
    RestartSec=2

    [Install]
    WantedBy=multi-user.target
    ```

  - 並在 chroot 內 `systemctl enable opencode-serve.service`

- 效果：
  - 只要用這顆 noble base rootfs 啟 VM，進入 `multi-user.target` 後，`systemd` 會自動啟動 `opencode serve --port 4096 --host 0.0.0.0`。
  - 這樣 host 可以直接對 `VM_IP:4096` 發 HTTP 請求檢查 readiness。

---

3. **由 host 檢測 readiness + 記錄啟動時間 benchmark**

- `run-noble-vm-with-opencode.sh` 已加入 **Step 5**：

  - 在送出 `InstanceStart` 時記錄毫秒時間戳 `START_TS`。
  - 之後 loop 直到 timeout（預設 90 秒）：
    - 用 `curl -s --max-time 1 http://${VM_IP}:4096/` 測試
    - 第一個成功回應時間記為 `READY_TS`
  - 啟動時間（毫秒）：
    ```text
    startup_ms = READY_TS - START_TS
    ```
  - 結果寫入 JSON 檔，路徑類似：
    - `logs/opencode-startup-<vm-id>-YYYYMMDD-HHMMSS.json`
    - 內容包含 `vm_id`, `kernel`, `rootfs`, `host_ip`, `vm_ip`, `instance_start_ts_ms`, `ready_ts_ms`, `startup_ms` 等欄位

- 這樣你可以在同一台機器上重複執行，直接比較不同設定下的 `startup_ms`。

---

**接下來你可以做的事：**

1. 用 `prepare-ubuntu-noble-rootfs.sh` 產出 rootfs。  
2. 確認 VM 內網路設定（netplan/cloud-init）把 eth0 設為 `172.30.0.2/24`，gateway `172.30.0.1`（或調整腳本裡 `VM_IP`/`HOST_IP`）。  
3. 用 `run-noble-vm-with-opencode.sh` 啟動 VM + 測量啟動時間。

---

**User**

1. OpenCode 直接做 API Server
2. 更新 @scripts/build-base-rootfs-opencode.sh 對應到 ubuntu-noble-base.rootfs.ext4

---

**Cursor**

1. **OpenCode 做 API Server**  
   - 在 `prepare-ubuntu-noble-rootfs.sh` 裡已加入 `systemd` 服務 `opencode-serve.service`，開機自動執行：  
     `opencode serve --port 4096 --host 0.0.0.0`  
   - 之後 VM 起來就會直接變成 OpenCode API Server，host 可以對 `VM_IP:4096` 做 readiness / benchmark。

2. **`build-base-rootfs-opencode.sh` 已改成 noble wrapper**  
   - 不再直接修改 `bionic.rootfs.ext4`，現在只是方便的入口：  
     ```bash
     sudo ./scripts/build-base-rootfs-opencode.sh
     ```  
     會等同執行：  
     ```bash
     sudo ./scripts/prepare-ubuntu-noble-rootfs.sh \
       --output bin/ubuntu-noble-base.rootfs.ext4 \
       --size-gb 12
     ```  
   - 腳本頭註解已改成解釋：這是「Ubuntu 24.04 noble base rootfs（含 OpenCode API Server 與 skills skeleton）」的建置 wrapper，實作細節都在 `prepare-ubuntu-noble-rootfs.sh`。

---

**User**

請將這個 seesion 的重點儲存到 260316-MEMORY.md 檔案中。今天到此結束工作。明天將重新開啟新的session。

---

**Cursor**

已將本次 session 的重點整理到 `260316-MEMORY.md`，包含：

- 從 bionic 精簡 rootfs 轉向 Ubuntu 24.04 noble cloud rootfs 的決策與原因。
- noble base rootfs 建置腳本：`prepare-ubuntu-noble-rootfs.sh`（apt + OpenCode + skills skeleton + systemd `opencode serve`）。
- VM 啟動與啟動時間量測腳本：`run-noble-vm-with-opencode.sh`（Firecracker 啟 VM、偵測 `:4096` readiness、寫 JSON benchmark）。
- 設計文件 `IMPLEMENTATION-PLAN-OPENCODE-VM.md` 已對齊的新架構與 skills/ workspace 約定。

明天開新 session 時可以直接從這份檔案抓回脈絡，繼續接 workspace 掛載與多 user/session 流程。

