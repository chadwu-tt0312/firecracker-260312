針對您建置「成千上萬個 VM 連接 MinIO S3 儲存桶以運行 OpenCode 與獨立 Workspace」的宏大目標，根據您提供的來源資料與測試紀錄，為您整理並總結如下：

### 1\. 目前做了哪些驗證與測試

在目前的實驗與建置過程中，主要進行了以下幾個核心領域的驗證：

* **併發與效能基準測試 (Benchmark)**：使用 fc-pro-bench.py 腳本，在 WSL2 環境下測試了併發啟動 50 甚至 1000 個 Firecracker VM 的效能，重點量測了 API 配置延遲、P99 尾端延遲，以及每個 VM 對宿主機的 RSS 實體記憶體開銷 1-3。  
* **Base Rootfs 的建置與優化**：經歷了從極簡的 bionic.rootfs.ext4 轉換到正式的 Ubuntu 24.04 (noble) cloud image 的測試。驗證了在 chroot 環境下安裝 Node.js、Python、編譯工具，並成功透過官方 curl 腳本將 OpenCode 安裝至 Rootfs 中 4-6。  
* **生命週期與 Warm Pool 策略**：設計並驗證了「一律回收 (Strict Recycle)」的 Warm Pool 機制。預先啟動 100 台 VM 待命，當 User session 結束後直接砍掉 VM 行程以確保環境乾淨，但保留其專屬 Workspace 磁碟以實現資料持久化 7, 8。  
* **網路隔離與 LLM Gateway 測試**：配置了 TAP 網路（如 172.30.0.1 對應 host，172.30.0.2 對應 guest），驗證了 VM 內不可信的 AI Agent 能夠透過 Host 上的統一 Gateway 來呼叫 LLM (Ollama / Gemini)，將 API Key 安全保留在 Host 或各 User Workspace 內 9-11。  
* **檔案分享機制測試**：嘗試使用 sshfs 將 Host 的 Workspace 目錄掛載至 VM 內進行雙向同步，藉此驗證動態資料掛載的可行性 12, 13。

### 2\. 這些驗證與測試的結果

* **效能開銷極低**：測試結果顯示，單個 Firecracker VM Process 的記憶體開銷 (RSS) 僅約 19.52 MB，啟動命令的平均延遲約在 141.50 ms 左右 2。這證明了單台實體機能夠輕易承載數千個 MicroVM，密度極高 14, 15。  
* **基礎映像檔 (Rootfs) 的完備性**：精簡版 bionic 映像因缺乏完整的 apt/dpkg 資料庫，導致 curl 無法驗證 CA 憑證而報錯 4, 16。改用 Ubuntu 24.04 (noble) 且容量上限設為 12GB 後，順利解決了相依性問題，讓 OpenCode 得以透過 systemd 在開機時自動以 API Server (opencode serve \--port 4096\) 的形式啟動 6, 17, 18。  
* **掛載測試遭遇 Kernel 限制**：在進行 sshfs 檔案同步測試時失敗。排查後發現，預設的 Guest Kernel (4.14.174) 內部並未編譯 CONFIG\_FUSE\_FS，導致 VM 內不存在 /dev/fuse 設備，因此所有依賴 FUSE 的掛載方案（包含 sshfs）皆無法直接運作 19, 20。這代表若要使用 FUSE 掛載，必須重新編譯 Guest Kernel 21。

### 3\. mount / sshfs / 9pfs / virtiofs 的檔案分享機制說明

在多租戶與 S3 (MinIO) 結合的架構下，檔案分享機制直接影響到 User Workspace 的效能與實作難度：

* **mount (Block Device)**：將映像檔格式化為 ext4 後，直接作為虛擬區塊設備 (virtio-blk) 掛載至 VM。  
* *特性*：效能最高、極度穩定、最符合 Firecracker 設計哲學 22, 23。  
* *對目標的影響*：針對您 MinIO S3 的目標，**最佳實踐是利用 JuiceFS 將 S3 轉化為 POSIX 檔案系統，並切分成稀疏檔案 (Sparse File) 映像，再透過 virtio-blk 以 Block Device 的形式掛載給微虛擬機** 24, 25。這能完美解決 S3 隨機讀寫效能差的問題，並保有強隔離性 26。  
* **sshfs**：透過 SSH 協定將 Host 的檔案系統掛載給 Guest。  
* *特性*：設定相對簡單，可實現即時雙向同步 23。  
* *對目標的影響*：效能受限於網路傳輸，且需依賴 Guest Kernel 支援 FUSE 19, 23。在成千上萬個 VM 的環境下，SSH 會有較大連線開銷，不適合做為高效能的持久化方案。  
* **9pfs (Plan 9\)**：傳統虛擬化的檔案共享協定。  
* *特性*：屬於檔案層級的共享，理論上支援即時同步 27。  
* *對目標的影響*：效能與穩定性通常較差，且 Firecracker 對此類傳統協定的支援度及最佳化不如 virtio-blk 27。  
* **virtiofs**：專為現代化虛擬機設計的高效能共享檔案系統。  
* *特性*：效能遠優於 9pfs，設計上就是為了取代 9pfs 27。  
* *對目標的影響*：整合成本極高。需要在 Host 運行 virtiofsd 守護行程，且 Guest Kernel 與 Hypervisor 皆須高度配合 27。Firecracker 雖對 virtio 支援良好，但架構複雜度會大幅上升。

### 4\. Firecracker 對比其他機制的技術差異與適用場景

針對您\*\*「執行不可信 AI Agent 代碼 (OpenCode)、成千上萬個獨立 Workspace」\*\*的需求，各技術的比較如下：

* **Docker (Containers)**：  
* *技術差異*：採用軟體級隔離 (Namespaces/cgroups)，所有容器共用宿主機 Kernel 28, 29。  
* *適用場景與限制*：適合內部受信任的微服務。但因為共享內核，極易遭受 Prompt Injection 引發的提權攻擊 (如 Dirty Pipe 逃逸)，**絕對不適合**用來執行生成式 AI 的不可信程式碼 28-30。  
* **gVisor**：  
* *技術差異*：由 Google 開發的應用程式內核 (Application Kernel)，在 User-space 攔截系統調用，阻斷對實體內核的直接存取 31。  
* *適用場景與限制*：適合中等安全需求的 AI 工作負載。雖然隔離性比 Docker 好，但攔截系統調用會帶來 10-20% 的效能損耗 (Overhead) 31, 32。  
* **Firecracker (MicroVM)**：  
* *技術差異*：基於 KVM 的硬體級虛擬化，每一台 VM 都有自己獨立的 Guest Kernel。剔除傳統硬體模擬 (BIOS/PCI)，將冷啟動壓縮至 125\~150 毫秒，且記憶體開銷低於 5MB 29, 30, 33。  
* *適用場景與限制*：**完美契合您的目標**。兼具傳統虛擬機的絕對安全性與容器的高密度特性，能安全地將 AI Agent (OpenCode) 放進強隔離沙箱中執行，即使被駭客攻破也無法影響宿主機或其他 User 30, 33。  
* **Kata Containers**：  
* *技術差異*：與 Firecracker 類似，底層使用輕量級 VM 來達到硬體隔離，但上層封裝成符合 OCI 標準的容器體驗 34, 35。  
* *適用場景與限制*：如果您**既有的基礎設施高度依賴 Kubernetes 且需要 VM 級別的隔離，Kata 是好選擇** 36。但若要追求極致的啟動速度與極簡架構，Firecracker 表現更佳 35。  
* **Kubernetes (K8s)**：  
* *技術差異*：K8s 是一套「編排系統」，本身不提供底層隔離技術（預設調度 Docker/containerd） 36。  
* *適用場景與限制*：用於管理大叢集非常成熟。但在「每建立一個對話就快速拉起一個沙箱」的 AI Agent 場景，K8s 的調度延遲較高、架構過重。針對您的目標，開發一個自訂的輕量級 Go/Python 控制平面來調度 Firecracker（並搭配 JuiceFS \+ MinIO）會是更敏捷且高效的設計 37。
