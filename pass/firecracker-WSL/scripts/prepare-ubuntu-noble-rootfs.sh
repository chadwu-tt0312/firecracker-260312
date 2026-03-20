#!/usr/bin/env bash
#
# prepare-ubuntu-noble-rootfs.sh
#
# 目的：
#   產生一顆「適合當 Firecracker base rootfs」的 Ubuntu 24.04 (noble) ext4 映像檔，
#   並在裡面預先安裝：
#     - curl + ca-certificates（HTTPS 必備）
#     - OpenCode（官方 install script）
#     - JS/Python 執行環境（供 skills scripts 使用）
#   同時建立 OpenCode 的 RO skills 目錄 skeleton：
#     - ~/.config/opencode/skills（由平台掛載 RO skills）
#
# 適用對象：
#   Linux / Firecracker 初學者。每一步都會用文字說明「為什麼要做」。
#
# 使用方式（建議用 sudo 跑，因為要 mount loop 與 chroot）：
#   sudo ./scripts/prepare-ubuntu-noble-rootfs.sh \
#     --output bin/ubuntu-noble-base.rootfs.ext4 \
#     --size-gb 5
#
# 你會得到：
#   - 一顆 ext4 rootfs（包含完整 apt/dpkg，可在 VM 內安裝/更新套件）
#   - 已安裝 opencode（可用於 `opencode serve --port 4096`）
#
# 來源：
#   Ubuntu Cloud Images（noble/current）中的 root tarball：
#     noble-server-cloudimg-amd64-root.tar.xz

set -euo pipefail

UBUNTU_ROOT_TAR_URL_DEFAULT="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-root.tar.xz"

OUTPUT_PATH=""
SIZE_GB="5"
ROOT_TAR_URL="${UBUNTU_ROOT_TAR_URL_DEFAULT}"
ENABLE_SSH="false"
DISABLE_RESOLVED="false"

usage() {
  cat <<'EOF'
用法：
  sudo ./scripts/prepare-ubuntu-noble-rootfs.sh [--output <path>] [--size-gb <n>] [--root-tar-url <url>] [--enable-ssh] [--disable-resolved]

參數：
  --output       產出的 ext4 rootfs 路徑，預設：bin/ubuntu-noble-base.rootfs.ext4
  --size-gb      rootfs 容量（GB），預設 5
  --root-tar-url Ubuntu root tarball URL（預設 noble/current 的 amd64 root.tar.xz）
  --enable-ssh   安裝並啟用 openssh-server，供 attach-microvm-shell.sh 驗證用（僅開發/測試）
  --disable-resolved  停用 systemd-resolved（mask），避免 microVM 在 resolved 初始化卡很久（建議僅內網/不需 DNS 時使用）

例子：
  sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 5
  sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 5 --enable-ssh
  sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 5 --disable-resolved
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="${2:-}"; shift 2;;
    --size-gb)
      SIZE_GB="${2:-}"; shift 2;;
    --root-tar-url)
      ROOT_TAR_URL="${2:-}"; shift 2;;
    --enable-ssh)
      ENABLE_SSH="true"; shift;;
    --disable-resolved)
      DISABLE_RESOLVED="true"; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "未知參數：$1"
      usage
      exit 1;;
  esac
done

# 預設 output 路徑（相對於專案根目錄）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_PATH="${OUTPUT_PATH:-${ROOT_DIR}/bin/ubuntu-noble-base.rootfs.ext4}"

echo "==> Step 0. 檢查參數與環境"
if [[ $EUID -ne 0 ]]; then
  echo "錯誤：本腳本需要 root 權限（會 mount loop 與 chroot）。"
  echo "請改用：sudo $0 [--output <path>]"
  exit 1
fi

# OUTPUT_PATH 已有預設值，無需再檢查空值

command -v curl >/dev/null 2>&1 || { echo "錯誤：host 缺少 curl，請先安裝：apt-get install -y curl"; exit 1; }
command -v xz >/dev/null 2>&1 || { echo "錯誤：host 缺少 xz（xz-utils），請先安裝：apt-get install -y xz-utils"; exit 1; }
command -v mkfs.ext4 >/dev/null 2>&1 || { echo "錯誤：host 缺少 mkfs.ext4（e2fsprogs），請先安裝：apt-get install -y e2fsprogs"; exit 1; }
command -v mount >/dev/null 2>&1 || { echo "錯誤：host 缺少 mount"; exit 1; }
command -v chroot >/dev/null 2>&1 || { echo "錯誤：host 缺少 chroot"; exit 1; }

OUT_DIR="$(dirname "${OUTPUT_PATH}")"
mkdir -p "${OUT_DIR}"

# Step 1 下載的 tarball 快取於 bin/，檔名由 URL 推得，存在則略過下載
ROOT_TAR_CACHE="${ROOT_DIR}/bin/$(basename "${ROOT_TAR_URL}")"
WORK_DIR="$(mktemp -d -t noble-rootfs-XXXXXX)"
MNT_DIR="${WORK_DIR}/mnt"
ROOT_TAR_XZ="${WORK_DIR}/root.tar.xz"

cleanup() {
  echo "==> 清理：卸載與刪除暫存目錄"
  umount "${MNT_DIR}/dev/pts" 2>/dev/null || true
  umount "${MNT_DIR}/dev" 2>/dev/null || true
  umount "${MNT_DIR}/sys" 2>/dev/null || true
  umount "${MNT_DIR}/proc" 2>/dev/null || true
  umount "${MNT_DIR}" 2>/dev/null || true
  rm -rf "${WORK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "  - 目標 rootfs：${OUTPUT_PATH}"
echo "  - rootfs 容量：${SIZE_GB} GB"
echo "  - Ubuntu root tarball：${ROOT_TAR_URL}"
echo "  - disable-resolved：${DISABLE_RESOLVED}"
echo "  - 暫存目錄：${WORK_DIR}"

echo
echo "==> Step 1. 下載 Ubuntu 24.04 root tarball"
echo "說明：我們下載的是 'root.tar.xz'（純 root filesystem），最適合用來做成單一 ext4 rootfs。快取於 bin/，存在則略過下載。"
if [[ -f "${ROOT_TAR_CACHE}" ]]; then
  echo "  - 使用既有快取：${ROOT_TAR_CACHE}"
  ROOT_TAR_XZ="${ROOT_TAR_CACHE}"
else
  mkdir -p "${ROOT_DIR}/bin"
  curl -fL "${ROOT_TAR_URL}" -o "${ROOT_TAR_CACHE}"
  ROOT_TAR_XZ="${ROOT_TAR_CACHE}"
fi

echo
echo "==> Step 2. 建立 ext4 映像檔容器（固定大小）"
echo "說明：ext4 映像檔本質上是『一個檔案形式的虛擬磁碟』，大小固定；裡面用多少空間要進到檔案系統裡看。"
rm -f "${OUTPUT_PATH}"
truncate -s "${SIZE_GB}G" "${OUTPUT_PATH}"
mkfs.ext4 -F "${OUTPUT_PATH}" >/dev/null

echo
echo "==> Step 3. 掛載 rootfs 映像檔並解壓 root tarball"
mkdir -p "${MNT_DIR}"
mount -o loop "${OUTPUT_PATH}" "${MNT_DIR}"

echo "  - 解壓縮中（可能需要一點時間）..."
tar -xJf "${ROOT_TAR_XZ}" -C "${MNT_DIR}"

echo
echo "==> Step 4. 準備 chroot（讓我們可以在 rootfs 裡用 apt 安裝套件）"
mount -t proc none "${MNT_DIR}/proc"
mount -t sysfs none "${MNT_DIR}/sys"
mount --bind /dev "${MNT_DIR}/dev"
mount --bind /dev/pts "${MNT_DIR}/dev/pts"
# Ubuntu cloud 映像內 /etc/resolv.conf 常為 symlink，先刪除再寫入一般檔供 chroot 用
rm -f "${MNT_DIR}/etc/resolv.conf"
cp -L /etc/resolv.conf "${MNT_DIR}/etc/resolv.conf"

echo
echo "==> Step 5. 在 rootfs 內安裝必要套件（JS/Python + build 能力）"
cat <<'EOF'
說明：
  - 你要求 skills 需要支援 scripts（JS/Python），並且要能下載 packages。
  - 因此我們在 base rootfs 內安裝：
      - curl, ca-certificates（HTTPS）
      - git（常見 dependency 來源）
      - python3 + pip + venv + uv（Python skills）
      - nodejs + npm（JS skills；可再視需求升級到較新版本）
      - build-essential（某些套件需要編譯 native module）
EOF

chroot "${MNT_DIR}" /bin/bash -c "
set -e
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl git \
  kmod fuse3 \
  python3 python3-pip python3-venv \
  nodejs npm \
  build-essential
apt-get clean || true
"

echo
echo "==> Step 5b. 在 rootfs 內安裝 uv（Astral 的 Python 套件/虛擬環境工具）"
chroot "${MNT_DIR}" /bin/bash -c "
set -e
if command -v uv >/dev/null 2>&1; then
  echo '[rootfs] 已存在 uv，略過安裝。'
else
  UV_INSTALL_DIR=/usr/local/bin curl -LsSf https://astral.sh/uv/install.sh | sh
fi
"

echo
echo "==> Step 6. 在 rootfs 內安裝 OpenCode（官方 install script）"
cat <<'EOF'
說明：
  - 依官方文件：https://opencode.ai/docs/zh-tw/
    使用：curl -fsSL https://opencode.ai/install | bash
  - 我們在 chroot 內執行，讓 base rootfs 開機後即可使用 opencode。
EOF

chroot "${MNT_DIR}" /bin/bash -c "
set -e
need_install=true
if [[ -x /usr/local/bin/opencode ]]; then
  echo '[rootfs] 已存在 /usr/local/bin/opencode，略過下載安裝。'
  need_install=false
elif [[ -x /root/.opencode/bin/opencode ]] || [[ -x /root/.local/bin/opencode ]]; then
  echo '[rootfs] 偵測到既有 opencode 二進位目錄，略過下載安裝。'
  need_install=false
fi
if [[ \"\${need_install}\" == true ]]; then
  curl -fsSL https://opencode.ai/install | bash
fi
# 做法 A：確保 systemd 可用固定路徑啟動（官方安裝多在 /root/.opencode/bin，不會進預設 PATH）
if [[ ! -x /usr/local/bin/opencode ]]; then
  OPENCODE_REAL=
  for cand in /root/.opencode/bin/opencode /root/.local/bin/opencode; do
    if [[ -x \"\${cand}\" ]]; then OPENCODE_REAL=\"\${cand}\"; break; fi
  done
  if [[ -z \"\${OPENCODE_REAL}\" ]]; then
    echo '錯誤：rootfs 內找不到可執行的 opencode。'
    exit 1
  fi
  ln -sf \"\${OPENCODE_REAL}\" /usr/local/bin/opencode
  echo \"  - 已建立 symlink：/usr/local/bin/opencode -> \${OPENCODE_REAL}\"
fi
"

echo
echo "==> Step 7. 建立 OpenCode skills skeleton（RO skills 位置）"
cat <<'EOF'
說明：
  - 你指定 RO skills 目錄位於：~/.config/opencode/skills
  - 我們用 /etc/skel 讓『未來新建的使用者』自動帶入該目錄結構。
EOF

chroot "${MNT_DIR}" /bin/bash -c "
set -e
mkdir -p /etc/skel/.config/opencode/skills
mkdir -p /root/.config/opencode/skills
"

echo
echo "==> Step 8. 建立 systemd 服務：開機自動啟動 opencode serve --port 4096"
cat <<'EOF'
說明：
  - 你希望 opencode 以 API 方式提供服務：opencode serve --port 4096。
  - 這裡建立一個 systemd service，讓 VM 開機後自動執行：
      opencode serve --port 4096 --hostname 0.0.0.0
    （官方參數為 --hostname，誤用 --host 會導致程序立刻以 exit code 1 結束。）
    讓 host 或其他 VM 可以透過網路偵測 readiness 並進行 benchmark。
EOF

chroot "${MNT_DIR}" /bin/bash -c "
set -e
cat > /etc/systemd/system/opencode-serve.service <<'UNIT'
[Unit]
Description=OpenCode API Server
After=network.target mount-ro-skills.service
Wants=network.target

[Service]
Type=simple
Environment=HOME=/root
WorkingDirectory=/root
ExecStart=/usr/local/bin/opencode serve --port 4096 --hostname 0.0.0.0
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable opencode-serve.service || true
"

echo
echo "==> Step 8b. 設定 guest 靜態 IP 與 networkd-wait-online 逾時（供 Firecracker TAP 拓樸）"
cat <<'EOF'
說明：
  - run-noble-vm-with-opencode.sh 使用 TAP 與 172.30.0.1/24（host）、172.30.0.2（guest）。
  - 此處在 guest 內設定 eth0 靜態 172.30.0.2/24，否則 guest 無 DHCP 會一直等不到「network online」。
  - 並為 systemd-networkd-wait-online 加上逾時，避免無限期卡住。
EOF

mkdir -p "${MNT_DIR}/etc/netplan"
# 檔名 99- 確保在 cloud-init 的 50- 之後套用，覆蓋 DHCP 為靜態 IP
cat > "${MNT_DIR}/etc/netplan/99-fc-eth0.yaml" <<'YAML'
# Firecracker 單機 TAP 拓樸：host 172.30.0.1，guest 172.30.0.2
# dhcp4: false 明確覆蓋 cloud-init 的 DHCP，避免合併後仍嘗試 DHCP
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses: [172.30.0.2/24]
      routes:
        - to: default
          via: 172.30.0.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
YAML

# 讓 hostname（如 ubuntu）可解析，避免 sudo 等出現「unable to resolve host」
HOST_SHORT="$(tr -d '\r\n' < "${MNT_DIR}/etc/hostname" 2>/dev/null || true)"
if [[ -n "${HOST_SHORT}" ]] && ! grep -qE "[[:space:]]${HOST_SHORT}([[:space:]]|$)" "${MNT_DIR}/etc/hosts" 2>/dev/null; then
  echo "127.0.1.1 ${HOST_SHORT}" >> "${MNT_DIR}/etc/hosts"
  echo "  - 已補上 /etc/hosts：127.0.1.1 ${HOST_SHORT}"
fi

mkdir -p "${MNT_DIR}/etc/systemd/system/systemd-networkd-wait-online.service.d"
cat > "${MNT_DIR}/etc/systemd/system/systemd-networkd-wait-online.service.d/timeout.conf" <<'UNIT'
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --timeout=15
UNIT

echo
echo "==> Step 8bb. 縮短 systemd-random-seed 啟動逾時（避免熵不足導致開機卡住）"
cat <<'EOF'
說明：
  - 在 microVM（特別是沒有 virtio-rng / 熵來源不足）環境，systemd-random-seed 可能會等很久（預設 10 分鐘）。
  - 這會拖慢 multi-user.target，連帶讓 ssh/opencode 等服務延後啟動。
  - 這裡用 drop-in 把 TimeoutStartSec 縮短到 15 秒，避免開機長時間卡住。
EOF
mkdir -p "${MNT_DIR}/etc/systemd/system/systemd-random-seed.service.d"
cat > "${MNT_DIR}/etc/systemd/system/systemd-random-seed.service.d/timeout.conf" <<'UNIT'
[Service]
TimeoutStartSec=15s
UNIT

echo
echo "==> Step 8bc. 縮短 systemd-resolved 啟動逾時（加速開機，opencode 不依賴 DNS）"
cat <<'EOF'
說明：
  - 在隔離網段/無 DNS 的 microVM，systemd-resolved 可能初始化很久（你已觀察到 >1 分鐘）。
  - opencode serve 主要提供本機/內網 HTTP 服務，通常不需要 DNS 才能先 listen。
  - 這裡將 resolved 的啟動逾時縮短到 15 秒，避免拖慢整體 boot path。
EOF
mkdir -p "${MNT_DIR}/etc/systemd/system/systemd-resolved.service.d"
cat > "${MNT_DIR}/etc/systemd/system/systemd-resolved.service.d/timeout.conf" <<'UNIT'
[Service]
TimeoutStartSec=15s
UNIT

if [[ "${DISABLE_RESOLVED}" == "true" ]]; then
  echo
  echo "==> Step 8bd. 停用 systemd-resolved（mask）並固定 resolv.conf（避免 stub 127.0.0.53）"
  cat <<'EOF'
說明：
  - 在 microVM/隔離網段環境，systemd-resolved 可能造成開機卡住或拖慢。
  - 這裡直接 mask 掉 systemd-resolved，讓它不會被啟動。
  - 同時將 /etc/resolv.conf 固定成一般檔案（非 symlink），避免指向 127.0.0.53 的 stub 設定。
EOF

  chroot "${MNT_DIR}" /bin/bash -c "
    set -e
    systemctl mask --now systemd-resolved.service || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'RESOLV'
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV
  "
fi

if [[ "${ENABLE_SSH}" == "true" ]]; then
  echo
  echo "==> Step 8c. 安裝並啟用 openssh-server（供 attach-microvm-shell.sh 驗證用，僅開發/測試）"
  chroot "${MNT_DIR}" /bin/bash -c "
    set -e
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    # 明確使用 ssh.service（避免 socket activation 造成 banner exchange timeout 等不易診斷問題）
    systemctl disable ssh.socket || true
    systemctl enable ssh.service || true
    systemctl enable ssh || true
    # 預先產生 host keys，避免 microVM 因熵不足而在首次 SSH 連線時卡住（banner exchange timeout）
    ssh-keygen -A
    # Ubuntu 24.04 可能透過 /etc/ssh/sshd_config.d/* 覆蓋預設值；用 drop-in 最可靠
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-opencode.conf <<'SSHD'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
SSHD
    echo 'root:opencode' | chpasswd
  "
  echo "  - 已設定 root 密碼為 opencode（僅供本機測試，勿用於對外環境）"
fi

echo
echo "==> Step 8d. 建立開機掛載 RO skills 磁碟的 systemd 服務（可選用）"
cat <<'EOF'
說明：
  - 當 run-noble-vm-with-opencode.sh 以 --ro-skills 掛上第二顆磁碟時，guest 內為 /dev/vdb。
  - 此服務在開機時若存在 /dev/vdb，則掛載至 /root/.config/opencode/skills（覆蓋空目錄）。
EOF
mkdir -p "${MNT_DIR}/root/.config/opencode/skills"
chroot "${MNT_DIR}" /bin/bash -c "
  set -e
  cat > /etc/systemd/system/mount-ro-skills.service <<'UNIT'
[Unit]
Description=Mount RO skills disk at /root/.config/opencode/skills
After=local-fs.target
Before=opencode-serve.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'if [ -b /dev/vdb ]; then mount -o ro /dev/vdb /root/.config/opencode/skills; fi'
UNIT
  systemctl enable mount-ro-skills.service || true
"

echo
echo "==> Step 9. （選用）放入提示檔：project/skills 的約定"
cat <<'EOF'
說明：
  - 你指定專案/私有 skills 放在各專案目錄的 project/skills。
  - 這是 runtime 使用習慣，不一定要在 base rootfs 做任何事。
  - 我們先在 /etc/skel 放一個 README，讓初學者進 VM 時能看到約定。
EOF

cat > "${MNT_DIR}/etc/skel/README-opencode-skills.txt" <<'EOF'
OpenCode skills 目錄約定：
  - RO（平台共用）skills：~/.config/opencode/skills
  - 專案/私有 skills：<project>/skills  （例如：~/workspace/my-project/skills）
EOF

echo
echo "==> Step 10. 收尾：清理 resolv.conf，卸載 rootfs"
if [[ "${DISABLE_RESOLVED}" != "true" ]]; then
  rm -f "${MNT_DIR}/etc/resolv.conf" || true
fi

echo
echo "==> 完成"
echo "  - 已產生可用 rootfs：${OUTPUT_PATH}"
echo "  - 內含：apt/dpkg（可用 apt 安裝套件）"
echo "  - 內含：OpenCode（已安裝）"
echo "  - 已建立：/etc/skel/.config/opencode/skills（新 user 預設）"
echo
echo "下一步（之後會做）："
echo "  - 啟動 microVM 後，在 VM 內用：opencode serve --port 4096"
echo "  - 並量測 opencode 啟動到可服務的時間（startup time）"

