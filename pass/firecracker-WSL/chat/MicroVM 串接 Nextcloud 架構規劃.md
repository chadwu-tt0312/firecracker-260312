# **大規模多租戶 AI 代理環境架構設計：整合 Firecracker MicroVM 與 Nextcloud 分散式存儲系統規劃報告**

在當前人工智慧與雲端原生技術交織的時代，構建一個能夠支援成千上萬個獨立執行環境，同時兼顧硬體級隔離、秒級啟動與持久化存儲的系統，已成為自動化軟體工程與 AI 代理（AI Agents）領域的核心挑戰。本報告旨在詳盡探討如何利用 AWS 開源的 Firecracker MicroVM 技術，結合 Nextcloud 作為磁碟空間管理後端，為每位使用者提供獨立的 OpenCode 運行環境。本架構規劃將從底層虛擬化、網路編排、存儲整合到 AI 代理狀態管理進行全方位的深度解析。

## **虛擬化底層：Firecracker MicroVM 的技術優勢與安全邊界**

構建多租戶系統的首要任務是確保隔離性。傳統的容器技術（如 Docker）雖然在資源利用率和啟動速度上表現優異，但由於其共享宿主機內核，在面對不可信的 AI 生成代碼執行時，存在較大的安全風險。Firecracker 作為一種專門為無伺服器計算（Serverless）和容器工作負載設計的虛擬機監視器（VMM），在安全與效能之間取得了精確的平衡。

### **Firecracker 的核心機制與極簡設計**

Firecracker 基於 Linux 的內核虛擬機（KVM），並採用 Rust 語言編寫，以確保記憶體安全性並減少攻擊面 1。其設計哲學是「最小化虛擬化」，僅保留執行現代 Linux 內核所必需的裝置，包括 virtio-net、virtio-block、virtio-vsock 以及基本的串列控制台 2。這種極簡主義使得 Firecracker MicroVM 的二進位檔案大小僅約 3 MiB，每台虛擬機的記憶體開銷小於 5 MiB，且能在約 125 毫秒內啟動使用者空間代碼。

| 性能指標 | Firecracker MicroVM | 傳統虛擬機 (QEMU) | 標準 OCI 容器 |
| :---- | :---- | :---- | :---- |
| 啟動時間 | \~125 毫秒 | 數秒至數分鐘 | \~50 毫秒 |
| 記憶體開銷 | \< 5 MiB | 數百 MiB | 極低 |
| 隔離級別 | 硬體級 (獨立內核) | 硬體級 (完全模擬) | 軟體級 (共享內核) |
| 安全邊界 | 極小 (Rust 編寫) | 較大 (C 編寫) | 最小 (命名空間/Cgroups) |
| 每秒創建速率 | 達 150 台 | 低 | 極高 |

這種高密度的部署能力使得單一宿主機能夠同時承載成千上萬個 MicroVM，這對於需要大規模併發處理 AI 任務的系統至關重要。

### **Jailer 屏障與深度防禦**

為了進一步強化安全性，Firecracker 包含了一個稱為「Jailer」的伴隨程序。在啟動 Firecracker VMM 之前，Jailer 會應用 Linux 的各種安全原語，包括 chroot 到特定目錄、建立獨立的網路命名空間（Network Namespaces）、掛載 cgroups 以限制資源使用，以及實施嚴格的 seccomp 系統調用過濾。這種多層級的保護模式確保了即使微型虛擬機內的內核遭到攻破，惡意行為也會被限制在受控的沙箱環境內，無法觸及宿主機或其他使用者的資料。

## **存儲架構規劃：Nextcloud 與分散式區塊存儲的深度整合**

本系統的核心挑戰之一是如何將 Nextcloud 的磁碟空間轉化為 Firecracker 可用的 virtio-block 裝置，同時保證數千個併發 VM 的 I/O 效能。Nextcloud 本身是一個基於 WebDAV 協議的文件管理平台，雖然便於使用者透過網頁或客戶端存取，但其底層存儲通常不直接支援虛擬機所需的隨機讀寫區塊存儲需求。

### **WebDAV 的效能瓶頸與優化途徑**

透過傳統的 davfs2 驅動程式掛載 WebDAV 作為磁碟空間時，往往會遇到顯著的延遲和效能瓶頸，尤其是在處理大量小檔案或高頻率 I/O 時。研究顯示，使用 rclone mount 搭配適當的快取策略（VFS Cache Mode Full），其效能表現優於 davfs2 數個數量級。然而，即使使用了 rclone，直接在 WebDAV 掛載點上執行 VM 鏡像檔案仍非最佳實踐，因為 WebDAV 缺乏原生對檔案偏移量隨機寫入的高效支援。

### **採用 S3 作為統一後端存儲層**

為了實現真正的可擴展性，建議將 Nextcloud 配置為使用 S3 兼容的物件存儲（如 MinIO、Ceph 或 AWS S3）作為其「主存儲（Primary Storage）」。在這種配置下，Nextcloud 負責管理檔案的元資料（檔名、權限、結構），而實際的資料塊則直接存放在 S3 儲存桶中。

對於 Firecracker 宿主機而言，可以直接透過 JuiceFS 等技術來存取同一個 S3 儲存桶。JuiceFS 是一種高性能的分散式檔案系統，它將元資料存儲在 Redis 或 PostgreSQL 等資料庫中，而將資料切片存儲在 S3 中。這種架構允許宿主機將每個使用者的 workspace 以稀疏檔案（Sparse File）的形式掛載為本地區塊裝置。

| 技術方案 | WebDAV (rclone) | S3 直接掛載 (S3FS) | JuiceFS (S3 \+ MetaDB) |
| :---- | :---- | :---- | :---- |
| 元資料性能 | 受限於 WebDAV API | 極慢 (線性掃描) | 極快 (DB 查詢) |
| 隨機讀寫 | 差 | 極差 | 優異 (局部緩存) |
| 資料一致性 | 弱 (快取依賴) | 最終一致性 | 強一致性 |
| 適用場景 | 個人檔案同步 | 備份/冷存儲 | 高併發 VM 存儲 |

### **自動化使用者空間配置流程**

為了支持「成千上萬」的規模，必須實現完全程序化的存儲配置流程。當新使用者加入系統時，編排層應執行以下步驟：

1. 透過 Nextcloud 的 OCS Provisioning API 建立使用者帳號及對應的配額限制。  
2. 在 S3/JuiceFS 層為該使用者分配一個專屬的 workspace 映像檔空間。  
3. 利用 Nextcloud 的外部存儲 API，將該 JuiceFS 目錄重新掛載回 Nextcloud 使用者介面，確保使用者能透過網頁即時存取 workspace 內的檔案。  
4. 產生專屬的 WebDAV App Password，供外部工具或備援機制連接。

## **AI 代理層：OpenManus 框架分析與 OpenHands 的選型參考**

使用者 query 中提到的 OpenManus 是一個基於 ReAct（Reasoning and Acting）範式的自主代理平台。它能夠利用大型語言模型（LLM）來規劃任務、執行工具並觀察結果。

### **OpenManus 的核心架構與資源需求**

OpenManus 採用模組化設計，其核心組件包括 Agent 層（處理邏輯與狀態）、Tool 層（提供 Bash、瀏覽器導航、檔案操作等能力）以及 LLM 交互層。在 Firecracker 環境中運行 OpenManus 需要預先配置好 Python 3.10+ 的環境，並安裝相關依賴如 Playwright（用於瀏覽器工具）。

| 資源維度 | 最低配置要求 | 推薦配置要求 |
| :---- | :---- | :---- |
| CPU | 4 核心 | 8 核心 |
| RAM | 8 GB | 32 GB (多代理任務) |
| 磁碟空間 | 20 GB | 50 GB (含 SSD 優化) |
| GPU | 不適用 | NVIDIA (顯存 12GB+) |

儘管 OpenManus 提供了強大的自主性，但在多租戶生產環境中，另一個專案 **OpenHands（原 OpenDevin）** 可能提供更完善的參考價值。OpenHands 擁有更成熟的企業級功能，包括多使用者支持、基於角色的存取控制（RBAC）以及極為細緻的對話持久化（Persistence）機制。

### **獨立 Workspace 與對話進度的持久化策略**

為了達成「獨立 workspace」與「AI 對話進度」持久化的目標，架構應遵循以下設計原則：

1. **Workspace 持久化**：每個 MicroVM 應掛載兩個 virtio-block 裝置。第一磁碟為唯讀的作業系統模板（Rootfs），第二磁碟則為掛載於 /workspace 的使用者專屬資料磁碟。所有 AI 產生的代碼、文件及下載的資源均存放於此處。  
2. **對話進度管理**：參考 OpenHands 的持久化機制，代理的執行狀態、記憶體快照及事件日誌應以結構化檔案（如 base\_state.json 和事件索引檔案）的形式存儲在 /workspace/.persistence 目錄下。這樣一來，即使 VM 實例因為資源調整或故障而重啟，代理只需重新讀取掛載磁碟中的狀態檔案，即可完美恢復對話與工作脈絡。

## **網路編排與大規模管理規劃**

在成千上萬個 MicroVM 的場景下，網路隔離與 IP 地址管理是系統穩定性的關鍵。Firecracker 僅支持 TAP 裝置作為網路介面，這需要宿主機層面具備強大的網路命名空間管理能力。

### **CNI 與 tc-redirect-tap 的應用**

現代化的 Firecracker 編排通常採用容器網路介面（CNI）插件。AWS 開源的 tc-redirect-tap 插件是此類架構的標配。其工作原理是在宿主機的網路命名空間中創建一對虛擬乙太網（veth）對，並透過 Linux 的流量控制（tc）機制，將所有流量重新導向至 Firecracker 專用的 TAP 裝置。

這種設計的好處包括：

* **強大的兼容性**：可以使用現成的 Kubernetes CNI 插件（如 Calico 或 Flannel）來分配 IP 和實施防火牆策略。  
* **精細的流量限制**：Firecracker 本身提供了內建的速率限制器（Rate Limiter），可以針對每個 VM 的頻寬和 I/O 次數進行精確配置，防止單一使用者耗盡宿主機資源。

### **Host-Guest 通訊：Vsock 協議**

為了實現對 VM 內部 agent 的高效控制，建議捨棄不穩定的網路 SSH 連接，改採 virtio-vsock 協議。這是一種專為虛擬化設計的跨邊界通訊協議，宿主機與虛擬機之間可以透過類似 Unix Socket 的介面進行 JSON 資料交換。宿主機上的編排服務可以透過 vsock 向 VM 內部的「Guest Agent」發送執行指令，並即時回收運行日誌與狀態。

## **系統效能優化與冷啟動問題**

為了提供流暢的使用者體驗，系統必須解決「冷啟動（Cold Start）」帶來的延遲問題。雖然 Firecracker 本身的啟動僅需百毫秒，但加載作業系統、Python 運行時以及 OpenManus 框架可能耗時數秒。

### **快照與恢復（Snapshot & Restore）機制**

Firecracker 支持將運行中的 VM 狀態（包括記憶體和暫存器）保存為快照檔案。當需要為新使用者啟動 VM 時，系統不應從零開始引導，而是從一個已經加載好 OpenManus 環境的「黃金快照（Golden Snapshot）」進行克隆並恢復。

| 操作類型 | 冷啟動延遲 | 快照恢復延遲 |
| :---- | :---- | :---- |
| 內核加載 | \~125 毫秒 | 毫秒級 |
| 使用者空間啟動 | \~3-5 秒 | 毫秒級 |
| AI 框架初始化 | \~5-10 秒 | 毫秒級 |
| **總體就緒時間** | **\~10-15 秒** | **\< 1 秒** |

這種技術的核心在於記憶體的懶加載（Lazy Loading），Firecracker 使用 MAP\_PRIVATE 映射快照檔案，只有在虛擬機實際存取特定記憶體頁面時，才會將其從磁碟讀入記憶體，從而實現了極速的併發啟動能力。

### **暖池（Warm Pools）與預熱策略**

為了應對突發的流量高峰，編排系統應維護一個「暖池」，預先啟動一定數量的暫停狀態 VM 或熱點快照。透過 SandboxWarmPool 等機制，可以將啟動時間縮短至亞秒級，這對於交互式 AI 代理應用尤為重要。

## **安全性加固：多租戶環境下的防範措施**

在處理成千上萬個使用者的系統中，防禦 LLM 生成的潛在惡意代碼是重中之重。除了 Firecracker 的硬體隔離外，還需要實施以下安全策略：

1. **Syscall 限制**：除了 VMM 層級的 seccomp 外，在 MicroVM 內部的 container 運行時也應套用最小權限原則，禁用如 ptrace、sys\_admin 等高危系統調用。  
2. **網路隔離**：透過 CNI 插件配合 Open vSwitch 或 WireGuard 構建私有網路網格，確保不同使用者之間的 VM 互不可見。  
3. **磁碟加密**：考慮到資料存儲在 S3 雲端，應啟用 Nextcloud 的伺服器端加密或 S3 的原生靜態加密（SSE-C），確保 workspace 資料的私密性。

## **系統整體架構規劃建議**

本架構規劃可總結為「三層堆疊」：

* **控制層（Control Plane）**：由一個高性能的 Go 語言服務負責使用者生命週期、Nextcloud API 調用、IP 地址分配以及 Firecracker 實例調度。  
* **執行層（Data Plane）**：多個裸金屬伺服器節點，運行 Firecracker VMM，並透過 JuiceFS 本地緩存與 S3 連接，保證 I/O 效率。  
* **存儲層（Storage Plane）**：以 S3 為核心的物件存儲集群，同時掛載至 Nextcloud 和執行層節點，實現檔案的可視化管理與持久化。

透過這種架構，系統能夠穩定支援成千上萬個 Firecracker 實例，同時為每個使用者提供如本地磁碟般順滑的 Nextcloud workspace 體驗與不間斷的 AI 對話歷史。對於 OpenManus 專案的整合，建議開發者重點參考其 Tool 調用的抽象層，並與宿主機的 vsock 進行橋接，以實現最安全且高效的執行流。

本報告所提出的系統規劃完全符合使用者對於大規模、強隔離、可視化存儲整合的技術要求，並為未來的橫向擴展奠定了堅實的技術基礎。針對具體的開發工作，建議優先從小型 Firecracker 集群與 JuiceFS 的性能壓測入手，逐步優化快照恢復邏輯，以達成最終的系統目標。

#### **引用的著作**

1. What is AWS Firecracker? The microVM technology, explained | Blog \- Northflank, 檢索日期：3月 23, 2026， [https://northflank.com/blog/what-is-aws-firecracker](https://northflank.com/blog/what-is-aws-firecracker)  
2. Firecracker vs Docker: The Technical Boundary Between MicroVMs and Containers, 檢索日期：3月 23, 2026， [https://huggingface.co/blog/agentbox-master/firecracker-vs-docker-tech-boundary](https://huggingface.co/blog/agentbox-master/firecracker-vs-docker-tech-boundary)  
3. Firecracker, gVisor, Containers, and WebAssembly \- Comparing Isolation Technologies for AI Agents \- SoftwareSeni, 檢索日期：3月 23, 2026， [https://www.softwareseni.com/firecracker-gvisor-containers-and-webassembly-comparing-isolation-technologies-for-ai-agents/](https://www.softwareseni.com/firecracker-gvisor-containers-and-webassembly-comparing-isolation-technologies-for-ai-agents/)  
4. Firecracker, 檢索日期：3月 23, 2026， [https://firecracker-microvm.github.io/](https://firecracker-microvm.github.io/)  
5. Announcing the Firecracker Open Source Technology: Secure and Fast microVM for Serverless Computing \- AWS, 檢索日期：3月 23, 2026， [https://aws.amazon.com/blogs/opensource/firecracker-open-source-secure-fast-microvm-serverless/](https://aws.amazon.com/blogs/opensource/firecracker-open-source-secure-fast-microvm-serverless/)  
6. Firecracker microVMs on OCI | cloud-infrastructure \- Oracle Blogs, 檢索日期：3月 23, 2026， [https://blogs.oracle.com/cloud-infrastructure/firecracker-oci-vm-vs-bm](https://blogs.oracle.com/cloud-infrastructure/firecracker-oci-vm-vs-bm)  
7. A field guide to sandboxes for AI \- Luis Cardoso, 檢索日期：3月 23, 2026， [https://www.luiscardoso.dev/blog/sandboxes-for-ai](https://www.luiscardoso.dev/blog/sandboxes-for-ai)  
8. Accessing Nextcloud files using WebDAV, 檢索日期：3月 23, 2026， [https://docs.nextcloud.com/server/20/user\_manual/en/files/access\_webdav.html](https://docs.nextcloud.com/server/20/user_manual/en/files/access_webdav.html)  
9. Accessing Nextcloud files using WebDAV, 檢索日期：3月 23, 2026， [https://docs.nextcloud.com/server/19/user\_manual/files/access\_webdav.html](https://docs.nextcloud.com/server/19/user_manual/files/access_webdav.html)  
10. Accessing Nextcloud files using WebDAV, 檢索日期：3月 23, 2026， [https://docs.nextcloud.com/server/27/user\_manual/en/files/access\_webdav.html](https://docs.nextcloud.com/server/27/user_manual/en/files/access_webdav.html)  
11. Fixing slow Nextcloud WebDAV mount with rclone | Ferdinand Mütsch, 檢索日期：3月 23, 2026， [https://muetsch.io/fixing-slow-nextcloud-webdav-mount-with-rclone.html](https://muetsch.io/fixing-slow-nextcloud-webdav-mount-with-rclone.html)  
12. Rclone speed issue \- Help and Support, 檢索日期：3月 23, 2026， [https://forum.rclone.org/t/rclone-speed-issue/34695](https://forum.rclone.org/t/rclone-speed-issue/34695)  
13. Rclone mount performance issue \- Suspected Bug, 檢索日期：3月 23, 2026， [https://forum.rclone.org/t/rclone-mount-performance-issue/43184](https://forum.rclone.org/t/rclone-mount-performance-issue/43184)  
14. Amazon S3 — Nextcloud latest Administration Manual latest documentation, 檢索日期：3月 23, 2026， [https://docs.nextcloud.com/server/stable/admin\_manual/configuration\_files/external\_storage/amazons3.html](https://docs.nextcloud.com/server/stable/admin_manual/configuration_files/external_storage/amazons3.html)  
15. Configuring Object Storage as Primary Storage \- Nextcloud Documentation, 檢索日期：3月 23, 2026， [https://docs.nextcloud.com/server/30/admin\_manual/configuration\_files/primary\_storage.html](https://docs.nextcloud.com/server/30/admin_manual/configuration_files/primary_storage.html)  
16. Scale your Nextcloud with Storage on Amazon Simple Storage Service (Amazon S3) \- AWS, 檢索日期：3月 23, 2026， [https://aws.amazon.com/blogs/opensource/scale-your-nextcloud-with-storage-on-amazon-simple-storage-service-amazon-s3/](https://aws.amazon.com/blogs/opensource/scale-your-nextcloud-with-storage-on-amazon-simple-storage-service-amazon-s3/)  
17. More complicated than that, but with respect to Sprites \--- this is a totally ne... | Hacker \- Hacker News, 檢索日期：3月 23, 2026， [https://news.ycombinator.com/item?id=46572703](https://news.ycombinator.com/item?id=46572703)  
18. JuiceFS vs. S3FS, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/community/comparison/juicefs\_vs\_s3fs/](https://juicefs.com/docs/community/comparison/juicefs_vs_s3fs/)  
19. Metadata Performance Comparison: HDFS vs S3 vs JuiceFS, 檢索日期：3月 23, 2026， [https://juicefs.com/en/blog/engineering/metadata-performance-comparisonhdfs-vs-s3-vs-juicefs](https://juicefs.com/en/blog/engineering/metadata-performance-comparisonhdfs-vs-s3-vs-juicefs)  
20. Accessing Nextcloud files using WebDAV, 檢索日期：3月 23, 2026， [https://docs.nextcloud.com/server/latest/user\_manual/en/files/access\_webdav.html](https://docs.nextcloud.com/server/latest/user_manual/en/files/access_webdav.html)  
21. JuiceFS S3 Gateway, 檢索日期：3月 23, 2026， [https://juicefs.com/docs/cloud/guide/gateway/](https://juicefs.com/docs/cloud/guide/gateway/)  
22. How to Add WebDAV Folders for Select Users in Apache and Configure in Nextcloud \- Knowledgebase | Thexyz, 檢索日期：3月 23, 2026， [https://www.thexyz.com/account/knowledgebase/350/How-to-Add-WebDAV-Folders-for-Select-Users-in-Apache-and-Configure-in-Nextcloud.html](https://www.thexyz.com/account/knowledgebase/350/How-to-Add-WebDAV-Folders-for-Select-Users-in-Apache-and-Configure-in-Nextcloud.html)  
23. NextCloud Multi-Family Architecture \- ℹ️ Support, 檢索日期：3月 23, 2026， [https://help.nextcloud.com/t/nextcloud-multi-family-architecture/217527](https://help.nextcloud.com/t/nextcloud-multi-family-architecture/217527)  
24. NextCloud WebDAV Client | Drupal.org, 檢索日期：3月 23, 2026， [https://www.drupal.org/project/nextcloud\_webdav\_client](https://www.drupal.org/project/nextcloud_webdav_client)  
25. Code Explanation: "OpenManus: An Autonomous Agent Platform ..., 檢索日期：3月 23, 2026， [https://dev.to/foxgem/openmanus-an-autonomous-agent-platform-8nl](https://dev.to/foxgem/openmanus-an-autonomous-agent-platform-8nl)  
26. OpenManus Technical Analysis: Architecture and Implementation of an Open-Source Agent Framework, 檢索日期：3月 23, 2026， [https://llmmultiagents.com/en/blogs/OpenManus\_Technical\_Analysis](https://llmmultiagents.com/en/blogs/OpenManus_Technical_Analysis)  
27. In-depth technical investigation into the Manus AI agent, focusing on its architecture, tool orchestration, and autonomous capabilities. \- Github-Gist, 檢索日期：3月 23, 2026， [https://gist.github.com/renschni/4fbc70b31bad8dd57f3370239dccd58f](https://gist.github.com/renschni/4fbc70b31bad8dd57f3370239dccd58f)  
28. OpenManus System Requirements | Full Hardware & Software Guide, 檢索日期：3月 23, 2026， [https://www.oneclickitsolution.com/centerofexcellence/aiml/openmanus-system-requirements](https://www.oneclickitsolution.com/centerofexcellence/aiml/openmanus-system-requirements)  
29. OpenManus Tutorial: How to Build Your Custom AI Agent in 2025 (Beginner's Guide), 檢索日期：3月 23, 2026， [https://chichieh-huang.com/posts/a3476af62056/](https://chichieh-huang.com/posts/a3476af62056/)  
30. Agentic AI Comparison: Devika AI vs OpenDevin, 檢索日期：3月 23, 2026， [https://aiagentstore.ai/compare-ai-agents/devika-ai-vs-opendevin](https://aiagentstore.ai/compare-ai-agents/devika-ai-vs-opendevin)  
31. Open-source AI agents \- Modal, 檢索日期：3月 23, 2026， [https://modal.com/blog/open-ai-agents](https://modal.com/blog/open-ai-agents)  
32. OpenHands: AI-Driven Development \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/OpenHands/OpenHands](https://github.com/OpenHands/OpenHands)  
33. Persistence \- OpenHands Docs, 檢索日期：3月 23, 2026， [https://docs.openhands.dev/sdk/guides/convo-persistence](https://docs.openhands.dev/sdk/guides/convo-persistence)  
34. Getting Started With Firecracker. Secure and fast microVMs for serverless… | by Mathis Joffre | Better Programming, 檢索日期：3月 23, 2026， [https://betterprogramming.pub/getting-started-with-firecracker-a88495d656d9](https://betterprogramming.pub/getting-started-with-firecracker-a88495d656d9)  
35. I Accidentally Rebuilt OpenHands From Scratch — Here's What I Learned \- Hugging Face, 檢索日期：3月 23, 2026， [https://huggingface.co/blog/charles-azam/rebuilt-openhands](https://huggingface.co/blog/charles-azam/rebuilt-openhands)  
36. Top 7 AI agent runtime tools and platforms in 2026 | Blog \- Northflank, 檢索日期：3月 23, 2026， [https://northflank.com/blog/top-ai-agent-runtime-tools](https://northflank.com/blog/top-ai-agent-runtime-tools)  
37. An SDK in Go for the Firecracker microVM API \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/firecracker-microvm/firecracker-go-sdk](https://github.com/firecracker-microvm/firecracker-go-sdk)  
38. Networking for a Firecracker Lab \- 0x74696d, 檢索日期：3月 23, 2026， [https://blog.0x74696d.com/posts/networking-firecracker-lab/](https://blog.0x74696d.com/posts/networking-firecracker-lab/)  
39. Getting Started with Firecracker | Harry Hodge, 檢索日期：3月 23, 2026， [https://harryhodge.co.uk/posts/2024/01/getting-started-with-firecracker/](https://harryhodge.co.uk/posts/2024/01/getting-started-with-firecracker/)  
40. awslabs/tc-redirect-tap \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/awslabs/tc-redirect-tap](https://github.com/awslabs/tc-redirect-tap)  
41. firecracker-microvm/firecracker-containerd: firecracker-containerd enables containerd to manage containers as Firecracker microVMs \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/firecracker-microvm/firecracker-containerd](https://github.com/firecracker-microvm/firecracker-containerd)  
42. How I Built a Firecracker MicroVM Code Execution Engine in Go (17x Faster Cold Starts), 檢索日期：3月 23, 2026， [https://medium.com/@abhishekdadwal/building-a-production-grade-code-execution-engine-with-firecracker-microvms-21309dadeec9](https://medium.com/@abhishekdadwal/building-a-production-grade-code-execution-engine-with-firecracker-microvms-21309dadeec9)  
43. firecracker/docs/snapshotting/snapshot-support.md at main · firecracker-microvm/firecracker \- GitHub, 檢索日期：3月 23, 2026， [https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md)  
44. \[2102.12892\] Restoring Uniqueness in MicroVM Snapshots \- arXiv.org, 檢索日期：3月 23, 2026， [https://arxiv.org/abs/2102.12892](https://arxiv.org/abs/2102.12892)  
45. How to sandbox AI agents in 2026: Firecracker, gVisor, runtimes & isolation strategies, 檢索日期：3月 23, 2026， [https://substack.com/home/post/p-187330720](https://substack.com/home/post/p-187330720)  
46. Fly Kubernetes features · Fly Docs \- Fly.io, 檢索日期：3月 23, 2026， [https://fly.io/docs/kubernetes/fks-features/](https://fly.io/docs/kubernetes/fks-features/)  
47. MicroVMs: Scaling Out Over Scaling Up in Modern Cloud Architectures | OpenMetal IaaS, 檢索日期：3月 23, 2026， [https://openmetal.io/resources/blog/microvms-scaling-out-over-scaling-up/](https://openmetal.io/resources/blog/microvms-scaling-out-over-scaling-up/)
