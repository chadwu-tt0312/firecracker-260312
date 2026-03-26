### 大規模 AI Agent 沙箱環境建置驗證與技術評估報告

##### 1\. 執行摘要與專案背景 (Executive Summary)

在當前自主代理（AI Agents）的技術浪潮中，企業面臨一個嚴峻的現實：儘管 AI 代理的推理能力已達生產水平，但全球僅有  **5% 的企業**  真正將其部署至生產環境。阻礙大規模採用的核心瓶頸並非模型能力，而是「沙箱困境」（Sandboxing Problem）。這源於所謂的\*\*「收容悖論」（Containment Paradox）\*\*：AI 代理若要發揮商業價值，必須擁有廣泛的系統權限（執行代碼、存取檔案、調用 API）；然而，權限越高，受損後的風險就越大。2024 年  **Air Canada（加拿大航空）**  賠償判例已確立了法律先聲：企業必須為其 AI 代理的行為負起完全法律責任。因此，建立一個兼具「硬體級隔離」與「亞秒級響應」的沙箱環境，已從技術選項提升為企業自動化戰略的必備基礎設施。本報告旨在評估利用 Firecracker MicroVM 技術連結大規模 MinIO 儲存後端的技術可行性，目標為成千上萬的代理提供獨立 Workspace、持久化對話能力與低於 200ms 的冷啟動體驗。

##### 2\. 目前驗證與測試進度綜述 (Current Validation & Test Results)

本階段測試聚焦於 Firecracker 與 Ubuntu 24.04 (Noble) 映像檔的整合。我們捨棄了僅 300MB 的精簡版 Bionic，轉而採用  **12GB 的 Noble 完整開發映像** 。這是一項戰略決策：現代 AI 工具鏈（Node.js/Python）需要最新的 glibc 與完整的編譯環境，精簡映像無法支撐複雜的 Agent 任務。

###### *2.1 技術瓶頸與解決路徑 (Lessons Learned)*

在環境建置過程中，我們排除並記錄了關鍵的底層錯誤，這些經驗具備高度技術價值：

* **CA 憑證缺失 (Error 77)：**  在最小化 rootfs 中，curl 因缺少 /etc/ssl/certs/ca-certificates.crt 無法驗證 HTTPS，已透過 chroot 預裝 ca-certificates 解決。  
* **Dangling Symlink 衝突：**  發現 /lib64/ld-linux-x86-64.so.2 存在損壞的軟連結，導致 ABI 不相容；現已確立「優先由映像內 apt 安裝，嚴禁直接從 Host 複製動態庫」的規範。  
* **dpkg 資料庫缺失：**  針對缺少 /var/lib/dpkg/status 的極簡映像，我們驗證了「方案 B」：從 Host 僅精確複製 CA 憑證，而不觸及核心系統庫，以避免系統崩潰。

###### *2.2 效能數據分析*

評估指標,Bionic 基礎映像 (Demo),Noble 完整映像 (Production),戰略考量  
映像檔大小,\~300 MB,\~12 GB (Logical),為支持全套 Node/Python 工具鏈  
磁碟開銷,300 MB,\~1.5 GB (Physical),透過「稀疏文件」優化儲存成本  
啟動延遲,\< 100ms,\~150ms \- 500ms,受服務初始化（systemd）影響  
環境成熟度,嚴重殘缺,完整 apt/dpkg 環境,確保 AI Agent 可動態安裝依賴

##### 3\. 檔案分享與持久化機制深度解析 (File Sharing & Persistence Mechanisms)

為了在不犧牲性能的前提下處理大規模多租戶數據，我們選擇了  **JuiceFS \+ S3 (MinIO)**  的架構設計。

###### *3.1 儲存機制評估*

* **virtio-blk (優選)：**  提供硬體級塊設備穩定性。透過 JuiceFS 將 S3 映射為 .img 檔案，可直接掛載為 VM 的 RW 碟。  
* **9pfs / virtiofs：**  Firecracker 原生支援受限，且在大規模併發下 I/O 損耗顯著，不建議採用。  
* **sshfs / WebDAV：**  雖然易於實作，但在高頻隨機讀寫時存在嚴重延遲，無法支撐 AI Agent 的頻繁運算。

###### *3.2 經濟性與一致性設計*

* **稀疏文件 (Sparse Files) 的經濟學：**  雖然 Noble 映像邏輯上呈現 12GB，但利用 Sparse File 特性，在 MinIO 中僅占用實際寫入的 1\~2GB。這使我們能為 Agent 提供充足空間，同時降低 80% 的實體儲存成本。  
* **元資料管理：**  必須引入  **Redis 或 PostgreSQL**  作為 JuiceFS 的元資料引擎。這對架構師至關重要，因為它確保了在跨節點調度 VM 時，Workspace 數據具備強一致性。

##### 4\. 技術架構對比：Firecracker vs. 競爭方案 (Competitive Technology Analysis)

在選擇隔離技術時，我們必須在安全、效能與運維複雜度間取得平衡。

| 技術方案 | 隔離機制 | 冷啟動 | 系統調用損耗 | 業界標竿 |
| ------ | ------ | ------ | ------ | ------ |
| **Firecracker** | KVM 硬體級虛擬化 | **\~150ms** | 極低 | **E2B**  (最優安全防禦) |
| **gVisor** | 系統調用攔截層 | \~150ms | **10-20%** | **Modal**  (適合輕量任務) |
| **Docker** | Namespace 隔離 | \~50ms | 0% | 不建議用於不可信代碼 |
  
**關鍵分析：**  gVisor 的 10-20% 系統調用開銷在處理「運算密集型」任務（如本地模型微調或複雜代碼編譯）時會顯著拖慢 Agent。相比之下，Firecracker 雖有稍高的內存開銷，但其提供的硬體級邊界是防禦  **CVE-2025-53773**  等逃逸漏洞的唯一可靠手段。

##### 5\. 建議之大規模多租戶架構 (Proposed Production-Scale Architecture)

為了支持成千上萬使用者並規避  **Air Canada 式的法律風險** ，我們提出以下三層堆疊規劃：

###### *5.1 三層堆疊與 Warm Pool 策略*

1. **控制層 (Go 服務)：**  管理 VM 生命週期。  
2. **執行層 (Firecracker)：**  實施  **"Warm Pool" 策略** ，預熱 100 台「匿名且未綁定」的 VM。當使用者請求發起時，動態注入 API Key 並掛載 JuiceFS 磁碟，確保感知延遲  **\< 200ms** 。  
3. **儲存層 (JuiceFS/S3)：**  提供持久化 Workspace。

##### 6\. 結論與決策建議 (Conclusion & Strategic Recommendations)

###### *6.1 繼續運行之理由*

技術驗證已證明 Firecracker 在 Ubuntu 24.04 (Noble) 環境下運作良好，且能成功執行 OpenCode API。結合 Sparse Files 技術，我們已解決了映像檔過大導致的存儲經濟性問題。

###### *6.2 關鍵風險與風險對策*

* **資源耗盡經濟學 (Resource Exhaustion)：**  一個惡意代理可能在短時間內產生數萬次循環，導致數千美元的雲端帳單。 **建議 Phase 2 必須實施「單一沙箱資源配額 (Quotas)」** ，針對 CPU/記憶體/頻寬進行硬性限制。  
* **網路編排挑戰：**  大規模 TAP 裝置的管理極其複雜，下一階段需評估 tc-redirect-tap 的性能極限。

###### *6.3 下一階段路線圖 (Roadmap)*

* **Phase 1 (已完成)：**  單機驗證、Noble 映像建置。  
* **Phase 2 (開發中)：**  實作  **"Snapshot & Restore" (MAP\_PRIVATE)** 。這將是達成 sub-second readiness 的關鍵，能讓開發者等級的 VM 在毫秒間從快照中復原，而非重新引導。  
* **Phase 3 (生產化)：**  整合 MCP 觀測與自動化預熱池管理。**結論：**  基於 Firecracker 的沙箱架構是目前唯一能同時滿足「Air Canada 等級安全合規」與「生產級效能」的方案。建議立即啟動 Phase 2 預熱池與快照技術的開發。
