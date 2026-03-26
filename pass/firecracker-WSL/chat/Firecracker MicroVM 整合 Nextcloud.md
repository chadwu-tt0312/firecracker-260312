# **大規模 Firecracker MicroVM 系統之雲端原生儲存與 AI Agent 持久化架構研究報告**

## **雲端運算範式轉移：從容器化到微虛擬機的演進背景**

在當代分佈式系統與無伺服器運算（Serverless Computing）的發展進程中，基礎設施的隔離性與啟動速度始終是一對核心矛盾。傳統容器技術如 Docker 雖然在開發效能與部署便捷性上取得了巨大成功，但其共享宿主機核心（Shared Kernel）的本質缺陷，使得在處理不可信代碼執行（Untrusted Code Execution）時面臨嚴峻的安全風險 1。任何核心級別的漏洞，如著名的 Dirty Pipe 或容器逃逸漏洞，都可能導致多租戶環境下的數據洩漏與系統崩潰 1。

為了應對這一挑戰，Amazon Web Services 於 2018 年推出了 Firecracker，這是一種基於 Linux 核心虛擬機（KVM）的虛擬機監視器（VMM），旨在提供傳統虛擬機的硬體級隔離，同時保有容器般的啟動速度與極低的資源開銷 3。Firecracker 的設計理念是極簡主義，它剔除了傳統虛擬機中繁雜的 BIOS、PCI 總線以及大量不必要的模擬硬體，僅保留了五個必要的模擬設備：virtio-net、virtio-block、virtio-vsock、序列主控台以及一個極簡的鍵盤控制器 4。

本報告將深入探討如何構建一個大規模的 Firecracker 系統，並整合 MinIO S3 儲存桶與 Nextcloud 平台。技術核心在於利用 JuiceFS 將物件儲存掛載為宿主機的高性能文件系統，進而映射為微虛擬機的 virtio-blk 工作空間。同時，本報告將詳細釐清 Unix Domain Socket 與 virtio-vsock 在通訊層級的本質區別，並參考 OpenManus 的分層架構，規劃 OpenCode 智能體在微虛擬機內的狀態持久化方案，最後針對 Nextcloud 在對接外部儲存時常見的一致性與同步瓶頸提出系統性對策。

## **儲存層基礎設施：MinIO 與 JuiceFS 的解耦架構實作**

在大規模微虛擬機部署中，傳統的本地磁碟（EBS 或本地 SSD）難以滿足彈性擴展與全局數據共享的需求。因此，構建以物件儲存為核心的統一資料平面成為必然選擇。

### **MinIO S3 兼容物件儲存的集群部署**

MinIO 作為高效能、S3 兼容的物件儲存解決方案，為大規模系統提供了可靠的底層存儲 6。在生產環境中，MinIO 通常採用糾刪碼（Erasure Coding）配置，以確保在多個節點或硬碟故障時數據仍能保持完整性 6。透過 mc（MinIO Client）管理工具，系統管理員可以精確控制儲存桶的存取權限與生命週期策略 7。

| 策略名稱 | 權限描述 | 適用場景 |
| :---- | :---- | :---- |
| readonly | 僅允許下載與列出物件 | 公共資源分發、靜態內容庫 |
| writeonly | 僅允許上傳與刪除物件 | 系統日誌歸檔、一次性上傳 |
| readwrite | 完整的 CRUD 權限 | 開發環境、動態應用儲存 |
| diagnostics | 訪問服務器診斷訊息 | 運維監控與效能排查 |

6

為了確保數據的安全傳輸，MinIO 集群應部署 Let's Encrypt 提供的 TLS 憑證，並透過 Prometheus 監控端點（如 /minio/v2/metrics/cluster）來追蹤集群的健康狀況與 I/O 吞吐量 6。

### **JuiceFS 的技術架構與數據處理流**

JuiceFS 是一種高性能的分散式文件系統，其核心設計在於將數據與元資料（Metadata）分離 9。這種設計完美契合了 Firecracker 對於高性能塊設備的需求。在 JuiceFS 的架構中，所有文件數據都被切割成 64 MiB 的邏輯「塊」（Chunks），進而細分為 4 MiB 的「片」（Slices），最終以物件形式存儲在 MinIO 等 S3 儲存中 11。

與此同時，文件的路徑、權限、大小等元資料則存儲在高性能的資料庫（元資料引擎）中，如 Redis、TiKV 或 PostgreSQL 10。

#### **JuiceFS 的寫入機制與效能特點**

在大規模環境中，JuiceFS 的寫入性能主要受限於物件儲存的延遲（通常為 20-100 ms） 12。為了克服這一點，JuiceFS 提供了 \--writeback 選項，允許數據先寫入本地快取磁碟，再由客戶端異步上傳至物件儲存 10。

| 效能指標 | JuiceFS (快取命中) | AWS EFS | 標準 EBS (io2) |
| :---- | :---- | :---- | :---- |
| 元資料操作延遲 | 1-3 ms | 5-10 ms | \< 1 ms |
| 首字節讀取延遲 | \< 5 ms | 高延遲 | 極低 |
| 最大順序讀取 | 取決於網絡帶寬 | 受限於服務器配額 | 取決於 IOPS 配置 |
| 多節點共享訪問 | 支持 (強一致性) | 支持 (NFS 協議) | 不支持 (單節點掛載) |

11

透過 juicefs format 指令，可以將 MinIO 儲存桶格式化為 JuiceFS 文件系統，並指定 Redis 為元資料引擎。這為微虛擬機提供了一個 POSIX 兼容的掛載點，使得複雜的檔案操作（如 mmap 或軟連結）成為可能 9。

## **Firecracker 儲存映射：將 JuiceFS 轉化為 virtio-blk 設備**

Firecracker 虛擬機並不直接支持 FUSE 或網絡文件系統掛載，它僅支持映射宿主機上的塊設備文件 4。因此，建置核心在於如何將 JuiceFS 掛載點內的文件呈現給微虛擬機。

### **工作空間鏡像的創建與回環映射**

在大規模系統中，我們可以在掛載的 JuiceFS 目錄（例如 /mnt/jfs）下，為每個微虛擬機實例創建一個獨立的磁碟鏡像文件 17。為了節省物理儲存空間，應使用「稀疏文件」（Sparse Files）技術。

Bash

\# 創建一個邏輯大小為 5GB 的稀疏鏡像文件  
truncate \-s 5G /mnt/jfs/workspaces/vm\_001.img

\# 將鏡像文件格式化為 Ext4 檔案系統  
mkfs.ext4 /mnt/jfs/workspaces/vm\_001.img

17

由於 JuiceFS 本身底層就是物件儲存，這些鏡像文件實際上是以 4 MiB 碎片的形式分散在 MinIO 儲存桶中 11。這意味著即便鏡像文件邏輯上很大，但在實際寫入數據之前，它在 MinIO 中幾乎不佔用空間 17。

### **透過 Firecracker REST API 配置儲存**

在啟動微虛擬機時，宿主機的管理進程需透過 Firecracker 的 API Socket 發送 JSON 指令，將 JuiceFS 上的鏡像文件掛載為 virtio-blk 設備 3。

JSON

PUT /drives/rootfs  
{  
  "drive\_id": "rootfs",  
  "path\_on\_host": "/mnt/jfs/workspaces/vm\_001.img",  
  "is\_root\_device": true,  
  "is\_read\_only": false  
}

3

### **I/O 效能優化與 IOThreads 配置**

在大規模高負載場景下，單一的 I/O 處理線程可能成為 CPU 瓶頸。儘管 Firecracker 的模擬設備非常精簡，但在處理高頻率 I/O 時，仍需考慮多線程優化。參考傳統虛擬化技術（如 QEMU 9.0 引入的 iothread-vq-mapping），在高併發微虛擬機環境中，宿主機應配置足夠的核心來處理中斷請求 18。

同時，由於 Linux 核心 6.19 對回環設備（Loop Device）進行了 AIO 性能改進，利用 IOCB\_NOWAIT 避免了 AIO 命令進入工作隊列，使得掛載在 JuiceFS 上的回環鏡像性能能極大限度地接近物理硬體 20。

## **通訊層級剖析：釐清 API Socket 與 virtio-vsock 的職責**

在構建大規模 Firecracker 系統時，開發者常混淆用於「控制」的 Unix Domain Socket 與用於「數據傳輸」的 virtio-vsock。兩者雖在宿主機端均表現為文件形式的 Socket，但在架構深度與通訊機制上存在本質區別。

### **Unix Domain Socket (UDS) 控制接口**

Firecracker 的管理完全依賴於 API Socket（通常命名為 firecracker.socket） 16。

1. **機制**：它是宿主機上的一個進程間通訊（IPC）端點，運行 HTTP 協議 16。  
2. **範圍**：僅存在於宿主機環境中。管理程序（Orchestrator）透過此 Socket 發送 REST 指令來配置微虛擬機的 vCPU、內存、網絡與硬碟 16。  
3. **安全性**：API Socket 通常由 jailer 進程進一步限制，確保只有具備特定權限的用戶才能控制微虛擬機的生命週期 3。

### **Virtio-vsock：跨越隔離邊界的數據通道**

virtio-vsock 則是為了讓虛擬機內部的應用程序（如 OpenCode Agent）能與宿主機通訊而設計的雙向通道 16。

#### **VSOCK 通訊原理與握手協議**

與傳統的 TCP/IP 網絡不同，VSOCK 繞過了複雜的網絡協議棧，提供了更低的延遲與更高的安全性 23。Firecracker 在用戶空間模擬了 virtio-vsock 設備，並將其映射至宿主機的文件路徑（uds\_path） 16。

* **宿主機發起連接**：  
  1. 宿主機客戶端連接至 uds\_path 指定的 UDS 文件。  
  2. 發送文字指令 "CONNECT PORT\\n"，其中 PORT 為虛擬機內 Agent 監聽的端口（如 52） 16。  
  3. Firecracker 回應 "OK PORT\\n" 後，該 UDS 連接即被轉發至虛擬機內的 AF\_VSOCK 接口 16。  
* **虛擬機發起連接**：  
  1. 微虛擬機內的程序創建 AF\_VSOCK Socket，並連接至 CID 2（宿主機的保留 CID）與目標端口 16。  
  2. Firecracker 偵測到連接請求，將其轉發至宿主機上特定路徑的 UDS，路徑規則通常為 uds\_path\_PORT（例如 ./v.sock\_52） 16。

| 特性 | API Control Socket (API\_SOCK) | Virtio-vsock |
| :---- | :---- | :---- |
| **目標** | 控制 VMM 行為 | 應用層數據交換 |
| **傳輸協議** | HTTP over UDS | 原始字串 / JSON (自定義) |
| **宿主機路徑** | 單一固定路徑 | 多個路徑 (映射端口) |
| **主要參與者** | Orchestrator \<-\> Firecracker | Host App \<-\> Guest Agent |
| **多路復用** | 透過 HTTP 路由 | 透過 UDS 文件名/握手協議 |

1

在大規模部署中，virtio-vsock 的優勢在於其不需要為每個虛擬機分配獨立的 IP 地址，極大地簡化了網絡管理。研究顯示，透過調整緩衝區大小（最高可達 64 KB），virtio-vsock 的吞吐量在宿主機與虛擬機之間可達到 10 Gbps 以上 25。

## **OpenCode 智能體架構：運行、協作與持久化設計**

在構建 AI Agent 系統時，安全性與狀態一致性是關鍵。參考 OpenManus 的架構，我們可以將 OpenCode 智能體設計為一個具備「雙重執行模式」的系統，並運行在 Firecracker 提供的強隔離環境中 26。

### **分層 Agent 體系結構**

OpenCode 應繼承 OpenManus 的分層設計，以處理不同複雜度的任務 26。

1. **BaseAgent**：提供核心的 LLM 調用、記憶體管理與 is\_stuck 錯誤偵測機制 26。  
2. **ReActAgent**：實現「思考-行動-觀察」的循環（Reasoning-Action Loop），這是 AI Agent 解決問題的標準範式 26。  
3. **ToolCallAgent**：封裝對文件系統、Bash 指令與網絡存取的工具調用接口 26。

### **雙重執行機制 (Dual Execution Mechanism)**

* **直接代理執行 (Direct Agent Mode)**：透過 main.py 入口點，針對簡單、線性的任務。Agent 在微虛擬機內直接調用工具並返回結果 26。  
* **流程編排模式 (Flow Orchestration Mode)**：透過 run\_flow.py，針對複雜的工程任務。系統會先生成一個 PlanningFlow（初始計畫），然後動態選擇虛擬機內的執行器來逐步完成任務 26。

### **智能體在 VM 內的狀態持久化**

為了讓 OpenCode 在大規模環境中具備「記憶」與「續傳」能力，必須解決虛擬機短暫生命週期與狀態持久化之間的衝突。

#### **1\. 工作目錄映射與 virtio-blk**

如前所述，微虛擬機的工作空間（/workspace）映射自掛載在 JuiceFS 上的 .img 文件 17。這意味著 OpenCode 產生的所有源代碼、中間構建產物以及日誌都直接持久化在 MinIO 儲存桶中。即便微虛擬機因為內存溢出或任務超時被銷毀，新的實例只需重新掛載該鏡像文件即可恢復所有文件 1。

#### **2\. Inbox 訊息傳遞與審計機制**

參考 OpenCode 的 multi-agent 協作設計，每個 Agent 都有一個獨立的 inbox 文件。

* **技術選型**：使用 JSONL (JSON Lines) 格式而非單一的 JSON 數組 28。  
* **優勢**：在分佈式文件系統（如 JuiceFS）中，追加寫入（Append-only）的效能遠優於「讀取-反序列化-修改-寫回」的循環（![][image1] vs ![][image2]） 28。這保證了在大規模 Agent 團隊協作時，訊息傳遞不會因為磁碟 I/O 鎖定而產生瓶頸。

#### **3\. PID 1 Guest Agent 實作**

在 Firecracker VM 內部，應運行一個以 Go 編寫的極簡 Guest Agent 作為 PID 1 1。

* **職責**：監聽 VSOCK 端口 52，接收來自宿主機的 JSON 指令（如執行的代碼內容），管理 Python 或 Node.js 執行環境，並負責孤兒進程的回收（Zombie Reaping） 1。  
* **安全隔離**：Guest Agent 使用 chroot 與 seccomp 限制子進程的行為，防止 AI 生成的代碼試圖攻擊虛擬機內核 1。

## **Nextcloud 與後端儲存的一致性與同步對策**

Nextcloud 作為用戶端的協作入口，當其對接基於 JuiceFS/MinIO 的外部儲存時，常面臨元資料同步不一致的問題。特別是當第三方進程（如微虛擬機內的 Agent）直接修改了底層 S3 存儲中的文件時，Nextcloud 的 Web UI 往往無法即時更新。

### **同步滯後的機制分析**

Nextcloud 維護著一個內部的元資料快取表 oc\_filecache 30。當文件繞過 Nextcloud 的 API（例如直接在 JuiceFS 掛載點寫入）被修改時，資料庫記錄就會失效。

* **傳統做法的缺陷**：執行 occ files:scan \--all 雖然能修復不一致，但對於擁有數百萬物件的大規模儲存桶，掃描速度極慢（約 20-50 檔案/秒），且會產生嚴重的資料庫 IOPS 負載 30。

### **事件驅動的一致性修復策略**

為了在大規模 Firecracker 環境中實現實時同步，必須從「被動輪詢」轉向「主動通知」。

#### **1\. S3 事件觸發 (Bucket Notifications)**

當微虛擬機內的 OpenCode 完成文件寫入並透過 JuiceFS 上傳至 MinIO 時，MinIO 可以觸發一個 S3 事件（s3:ObjectCreated:\*） 33。

* **流程**：MinIO \-\> Webhook \-\> 同步代理進程。  
* **動作**：同步代理進程解析事件中的路徑，並調用 Nextcloud 的 OCS API 觸發局部掃描 33。

#### **2\. 精確路徑掃描與 OCS API**

利用 occ 指令的 \--path 選項，僅掃描受影響的子目錄或單個文件，這能將掃描時間從幾小時壓縮至幾毫秒 35。

Bash

\# 僅掃描特定用戶的特定外部儲存路徑  
php occ files:scan \--path="/user\_id/files/workspace\_001/src"

36

#### **3\. 核心配置優化**

在 Nextcloud 的 config.php 中，應進行以下關鍵配置：

* **filesystem\_check\_changes**：設置為 1 或 true。這會強制 Nextcloud 在每次訪問目錄時檢查底層文件系統的變動（mtime/size），雖然會增加輕微的 I/O 開銷，但對於確保微虛擬機產出的結果即時可見至關重要 37。  
* **事務性文件鎖定 (Redis)**：必須配置高性能的 Redis 作為 memcache.locking。在大規模併發環境中，這能防止微虛擬機與 Nextcloud 同時寫入同一鏡像文件時產生的競爭條件 30。

## **大規模運維實踐：虛擬機池與效能監控**

當系統規模擴展至數千台 Firecracker 微虛擬機時，資源管理與冷啟動延遲成為主要挑戰。

### **微虛擬機池管理 (VM Pooling)**

為了將冷啟動延遲從秒級降低至毫秒級，系統應實施預熱機制 1。

1. **預先啟動 (Pre-booting)**：在後台維持一定數量的空閒微虛擬機，這些虛擬機已完成內核加載與 Guest Agent 初始化 1。  
2. **健康追蹤**：Orchestrator 持續透過 VSOCK 端口進行健康檢查。若虛擬機無回應，則自動將其銷毀並補充新實例 1。

### **資源超賣與限制 (Rate Limiting)**

Firecracker 內置了精確的速率限制器（Rate Limiters），允許針對網絡帶寬與磁碟 IOPS 進行細粒度控制 4。

* **配置策略**：為每個 OpenCode 執行任務設置突發容量（Burst Capacity）與平均帶寬。這能防止單一「惡意」或「失控」的 AI Agent 耗盡宿主機的所有 I/O 資源，影響其他租戶的穩定性 4。

### **監控與觀測性 (Observability)**

大規模系統必須具備完善的監控。

* **宿主機層級**：監控 /dev/kvm 資源利用率與 JuiceFS 快取命中率 10。  
* **虛擬機層級**：透過 Guest Agent 暴露 /metrics 端點，收集代碼執行持續時間、內存消耗與失敗率等自定義指標 1。

## **結論**

建置大規模 Firecracker 微虛擬機系統是一項複雜的系統工程，要求對虛擬化、分佈式儲存與網路通訊有深刻的理解。透過 JuiceFS 將 MinIO 物件儲存轉化為高效、POSIX 兼容的 virtio-blk 設備，解決了微虛擬機在無狀態架構下的持久化難題。

本研究釐清了通訊層的核心差異：API Socket 負責生命週期控制，而 virtio-vsock 則是高效數據交換的生命線。參考 OpenManus 的架構設計，OpenCode 智能體能夠在強隔離的環境中，利用 JSONL 追加寫入與磁碟鏡像映射，實現穩定且可審計的狀態持久化。

針對 Nextcloud 的同步瓶頸，採用「事件驅動」的局部掃描機制與 filesystem\_check\_changes 配置，成功平衡了海量物件存儲與前端展示的即時性。這套整合方案不僅為 AI Agent 的安全運行提供了堅固的沙盒，也為下一代雲端原生開發環境奠定了高性能的數據基礎。

#### **引用的著作**

1. How I Built a Firecracker MicroVM Code Execution Engine in Go (17x Faster Cold Starts), 檢索日期：3月 23, 2026， [https://medium.com/@abhishekdadwal/building-a-production-grade-code-execution-engine-with-firecracker-microvms-21309dadeec9](https://medium.com/@abhishekdadwal/building-a-production-grade-code-execution-engine-with-firecracker-microvms-21309dadeec9)  
2. Firecracker microVMs : the power behind AWS Lambda \- Antho's blog, 檢索日期：3月 23, 2026， [https://www.anthony-balitrand.fr/2025/08/12/firecracker-microvms-the-power-behind-aws-lambda/](https://www.anthony-balitrand.fr/2025/08/12/firecracker-microvms-the-power-behind-aws-lambda/)  
3. What is AWS Firecracker? The microVM technology, explained | Blog \- Northflank, 檢索日期：3月 23, 2026， [https://northflank.com/blog/what-is-aws-firecracker](https://northflank.com/blog/what-is-aws-firecracker)  
4. Firecracker microVMs, 檢索日期：3月 23, 2026， [https://firecracker-microvm.github.io/](https://firecracker-microvm.github.io/)  
5. Firecracker vs QEMU: Which one should you use? | Blog \- Northflank, 檢索日期：3月 23, 2026， [https://northflank.com/blog/firecracker-vs-qemu](https://northflank.com/blog/firecracker-vs-qemu)  
6. How to Set Up MinIO for S3-Compatible Storage \- OneUptime, 檢索日期：3月 23, 2026， [https://oneuptime.com/blog/post/2026-01-27-minio-s3-compatible-storage/view](https://oneuptime.com/blog/post/2026-01-27-minio-s3-compatible-storage/view)  
7. JuiceFS S3 Gateway, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/cloud/guide/gateway/](https://juicefs.com/docs/cloud/guide/gateway/)  
8. JuiceFS S3 Gateway | JuiceFS Document Center, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/community/guide/gateway/](https://juicefs.com/docs/community/guide/gateway/)  
9. How to Set Up Object Storage | JuiceFS Document Center, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/community/reference/how\_to\_set\_up\_object\_storage/](https://juicefs.com/docs/community/reference/how_to_set_up_object_storage/)  
10. 6 Essential Tips for JuiceFS Users, 檢索日期：3月 23, 2026， [https://juicefs.medium.com/6-essential-tips-for-juicefs-users-46489c7462c5](https://juicefs.medium.com/6-essential-tips-for-juicefs-users-46489c7462c5)  
11. Shared Block Device | JuiceFS Document Center, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/cloud/guide/block-device/](https://juicefs.com/docs/cloud/guide/block-device/)  
12. FAQ | JuiceFS Document Center, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/community/faq/](https://juicefs.com/docs/community/faq/)  
13. Distributed Mode | JuiceFS Document Center, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/community/getting-started/for\_distributed/](https://juicefs.com/docs/community/getting-started/for_distributed/)  
14. Performance Evaluation Guide | JuiceFS Document Center, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/community/performance\_evaluation\_guide/](https://juicefs.com/docs/community/performance_evaluation_guide/)  
15. JuiceFS Enterprise, 檢索日期：3月 23, 2026， [https://juicefs.com/en/product/enterprise-edition](https://juicefs.com/en/product/enterprise-edition)  
16. firecracker/docs/vsock.md at main \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/firecracker-microvm/firecracker/blob/main/docs/vsock.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/vsock.md)  
17. Scaling Firecracker: Using OverlayFS to Save Disk Space \- E2B, 檢索日期：3月 23, 2026， [https://e2b.dev/blog/scaling-firecracker-using-overlayfs-to-save-disk-space](https://e2b.dev/blog/scaling-firecracker-using-overlayfs-to-save-disk-space)  
18. Improve virtio-blk device performance using iothread-vq-mapping | linux \- Oracle Blogs, 檢索日期：3月 23, 2026， [https://blogs.oracle.com/linux/virtioblk-using-iothread-vq-mapping](https://blogs.oracle.com/linux/virtioblk-using-iothread-vq-mapping)  
19. Improve virtio-blk device performance using iothread-vq-mapping \- Proxmox Support Forum, 檢索日期：3月 23, 2026， [https://forum.proxmox.com/threads/improve-virtio-blk-device-performance-using-iothread-vq-mapping.154823/](https://forum.proxmox.com/threads/improve-virtio-blk-device-performance-using-iothread-vq-mapping.154823/)  
20. A Very Big Performance Optimization For Loop Block Devices Heading To Linux 6.19, 檢索日期：3月 23, 2026， [https://www.phoronix.com/news/Linux-6.19-Faster-Loop-Block](https://www.phoronix.com/news/Linux-6.19-Faster-Loop-Block)  
21. Firecracker for Students: Launch Your First MicroVM on Any OS \- Tutorials Dojo, 檢索日期：3月 23, 2026， [https://tutorialsdojo.com/firecracker-for-students-launch-your-first-microvm-on-any-os/](https://tutorialsdojo.com/firecracker-for-students-launch-your-first-microvm-on-any-os/)  
22. firecracker-microvm/firecracker: Secure and fast microVMs for serverless computing. \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/firecracker-microvm/firecracker](https://github.com/firecracker-microvm/firecracker)  
23. AF\_VSOCK is another one to consider these days. It's a kind of hybrid of loopbac... | Hacker News, 檢索日期：3月 23, 2026， [https://news.ycombinator.com/item?id=37467894](https://news.ycombinator.com/item?id=37467894)  
24. Attacking Firecracker \- AWS' microVM Monitor Written in Rust \- chompie at the bits, 檢索日期：3月 23, 2026， [https://chomp.ie/Blog+Posts/Attacking+Firecracker+-+AWS'+microVM+Monitor+Written+in+Rust](https://chomp.ie/Blog+Posts/Attacking+Firecracker+-+AWS'+microVM+Monitor+Written+in+Rust)  
25. KVM Forum 2019: virtio-vsock in QEMU, Firecracker and Linux \- Stefano Garzarella, 檢索日期：3月 23, 2026， [https://stefano-garzarella.github.io/posts/2019-11-08-kvmforum-2019-vsock/](https://stefano-garzarella.github.io/posts/2019-11-08-kvmforum-2019-vsock/)  
26. OpenManus Architecture Deep Dive: Enterprise AI Agent ..., 檢索日期：3月 23, 2026， [https://dev.to/jamesli/openmanus-architecture-deep-dive-enterprise-ai-agent-development-with-real-world-case-studies-5hi4](https://dev.to/jamesli/openmanus-architecture-deep-dive-enterprise-ai-agent-development-with-real-world-case-studies-5hi4)  
27. How to Install OpenCode: Step-by-Step Setup Guide (2026) \- NxCode, 檢索日期：3月 23, 2026， [https://www.nxcode.io/resources/news/opencode-install-guide-step-by-step-2026](https://www.nxcode.io/resources/news/opencode-install-guide-step-by-step-2026)  
28. Building Agent Teams in OpenCode: Architecture of Multi-Agent Coordination, 檢索日期：3月 23, 2026， [https://dev.to/uenyioha/porting-claude-codes-agent-teams-to-opencode-4hol](https://dev.to/uenyioha/porting-claude-codes-agent-teams-to-opencode-4hol)  
29. Firecracker – Lightweight Virtualization for Serverless Computing | AWS News Blog, 檢索日期：3月 23, 2026， [https://aws.amazon.com/blogs/aws/firecracker-lightweight-virtualization-for-serverless-computing/](https://aws.amazon.com/blogs/aws/firecracker-lightweight-virtualization-for-serverless-computing/)  
30. \[Bug\]: occ files:scan and Web UI fail with 504 Timeouts when indexing massive S3 External Storage buckets · Issue \#58549 · nextcloud/server \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/nextcloud/server/issues/58549](https://github.com/nextcloud/server/issues/58549)  
31. Configuring External Storage (GUI) \- Nextcloud Documentation, 檢索日期：3月 23, 2026， [https://docs.nextcloud.com/server/20/admin\_manual/configuration\_files/external\_storage\_configuration\_gui.html?highlight=files%20scan](https://docs.nextcloud.com/server/20/admin_manual/configuration_files/external_storage_configuration_gui.html?highlight=files+scan)  
32. \[Bug\]: Nextcloud does not see file change in S3 external storage unless occ files:scan · Issue \#53249 \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/nextcloud/server/issues/53249](https://github.com/nextcloud/server/issues/53249)  
33. Advanced Nextcloud Workflows with Amazon Simple Storage Service (Amazon S3) | AWS Open Source Blog, 檢索日期：3月 23, 2026， [https://aws.amazon.com/blogs/opensource/advanced-nextcloud-workflows-with-storage-on-amazon-simple-storage-service-amazon-s3-2/](https://aws.amazon.com/blogs/opensource/advanced-nextcloud-workflows-with-storage-on-amazon-simple-storage-service-amazon-s3-2/)  
34. Using S3 triggers to maintain a list of files in DynamoDB \- Simon Willison: TIL, 檢索日期：3月 23, 2026， [https://til.simonwillison.net/aws/s3-triggers-dynamodb](https://til.simonwillison.net/aws/s3-triggers-dynamodb)  
35. How can use run "files:scan \--path=" when the user folders are located on a "local" external storage using "$user" in the path? : r/NextCloud \- Reddit, 檢索日期：3月 23, 2026， [https://www.reddit.com/r/NextCloud/comments/10ugln7/how\_can\_use\_run\_filesscan\_path\_when\_the\_user/](https://www.reddit.com/r/NextCloud/comments/10ugln7/how_can_use_run_filesscan_path_when_the_user/)  
36. How to use occ files:scan to scan a path on external storage \- Nextcloud community, 檢索日期：3月 23, 2026， [https://help.nextcloud.com/t/how-to-use-occ-files-scan-to-scan-a-path-on-external-storage/194000](https://help.nextcloud.com/t/how-to-use-occ-files-scan-to-scan-a-path-on-external-storage/194000)  
37. Automatically do a files:scan on that specific file when a new file is added \- ℹ️ Support, 檢索日期：3月 23, 2026， [https://help.nextcloud.com/t/automatically-do-a-files-scan-on-that-specific-file-when-a-new-file-is-added/95448](https://help.nextcloud.com/t/automatically-do-a-files-scan-on-that-specific-file-when-a-new-file-is-added/95448)  
38. Announcing the Firecracker Open Source Technology: Secure and Fast microVM for Serverless Computing \- AWS, 檢索日期：3月 23, 2026， [https://aws.amazon.com/blogs/opensource/firecracker-open-source-secure-fast-microvm-serverless/](https://aws.amazon.com/blogs/opensource/firecracker-open-source-secure-fast-microvm-serverless/)  
39. Let's Learn Firecracker MicroVM with Go Firecracker SDK\! \- Tutorials Dojo, 檢索日期：3月 23, 2026， [https://tutorialsdojo.com/lets-learn-firecracker-microvm-with-go-firecracker-sdk/](https://tutorialsdojo.com/lets-learn-firecracker-microvm-with-go-firecracker-sdk/)

[image1]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACgAAAAZCAYAAABD2GxlAAACOklEQVR4Xu2WPWtVQRCGx2/jtxFBxA8EwcKPgJpKsAiopQqKqFhbCYKohZDCQrAQwRAIaKMIWggWFhaBdIFU/gl/iL4Pe1fnzN1zzl65gmAeeLncmd3ZObO7c47ZKv8e66SJaOxh1PENNkvbpTXRUYCx96Wp6OjhvKW5I3Fb+ip9kN5J36Sb0iY/yMECj6RL0eHYZe3zmVuV5AbpmnRV2uLsx6Qv0oK0x9kzF6Rn1pzjIeaydDw6BjCXGK3slJ5bqlTbFnFWGPM9OsS8tC3YOBbYqMys9MPaE2QcMW5FR+aBpQA3osOxVrpnaZxnh6Xt76IvQSDGe2kyOoCqcN5K2+e5a2mh9c52Qjrl/peoSZAY5EG8BpSXya3lHbDRfi/kE7wi7Xf/S9QkeEBatBSvAaX9aC2ldfBkPKHf4px0Xy+rSXCrNGdp7C9Y4In01NpbQIYKswjnJJMT5LeLmgRzrKEEs7FrEc4mZ5RFLjs7N5QW0TUX/jhB4OD3JcjtZoFX1mwn46wgO8hODiV40dLecwbaoD/SqA8Ge04w9sBITYK8Ut9aOnJDkABvid3ORqM9Y+lm7XX2yIx0JBoDLywlOG3pg6IEMVakc9EBPNknaUm6Y+mqvx7YzrpxJQ5bOahvS1GlSrKT7NK+6MhQMXrRaemkNavZBRfloTV746gwlxiPLX0PjJ3P1vHkFTCXGBTnr8DleSMdio5KmBsv4NjhK+il1R+NDOP73uVj46gV3qUdcKOvR+Mq/w0/ASAUWvfz2K06AAAAAElFTkSuQmCC>

[image2]: <data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACoAAAAZCAYAAABHLbxYAAACaUlEQVR4Xu2W3asOURTGH/n+DiWJCykRITmlSPKVCxdSEiVJUtwpJKVcUOdKceNCiajTueBSUpJSSrnzF/hDeJ6z3nXeNWv2zJyGt5Tzq6dp1t6zZ81eH3uAWf59FlFzs3GGLM6GmaIXLqOWUwvSWImD1Hn0d/Qoejz7gPpIvaReUd+oTZUZdcZhH9YXOXlxcO1kJXWD2kHNCXaF5Tu1K9gia6gt2diDZ2h+xxQbqDfUU2pVGnNOUb+oc8m+jnqbbH3xtfbkAec+9ZMaywOB7TBHFeKY+MrNiXD/J8ynblM3qXlpbAo58BBWtU24oy9gBSa0mBa965MSKsK4phdo0YkBipw+fHUekEEOaGfaOIy6o7rq/pJPChyBpdJ76gJ1mnoNK84vsA5RYif1A4Wcv4p6OEs8gTl6Odi2wVJGi2eOY7jjmpPHtFYJ1csH2JxpFJp7MGe70FfqheoIjqeDrpm11ArqOWwjIoqA1ivhjlaK1h29Eo0NlPK4zVGh3vsV1dRQ5OS4PqCEO1rxyUPT5ageVh/NedPlqId4b7C58zGFIu7oiTygKmtsB7Bdv0MdywMYvlSFlvFNeEetD3aFVGHfSu3GsDCdYo46yr1rqJ7pC2E7/Yk6FOyRpbAiK+V4KezKWzV0zdfJdyCMOftR/7hp1Jp0tqvVaIevw1qIrrV+llAI5WxmH+rF5+e5+uStwX1G67V2IYVqMyyfdI2724Yc+ZyNMCeaXrYE5cPFI3QyD/wNdNI8zsaeKG8nYWf+SNDunc3GHjyC/cGNFHWG1l+0DvTXtjEbR4HajM70Pjuiv6Yz2TjLf89vu8NdwocpnJEAAAAASUVORK5CYII=>
