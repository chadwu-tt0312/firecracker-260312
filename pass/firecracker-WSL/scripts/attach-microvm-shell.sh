#!/usr/bin/env bash
#
# attach-microvm-shell.sh
#
# 目的：啟動 microVM 後取得互動式 shell（透過 SSH）。
# 前提：rootfs 內已安裝並啟用 openssh-server（prepare 時加 --enable-ssh）。
#
# Workspace（可變檔案）：
#   - 不採用 sshfs（專案腳本不提供、亦不建議）。
#   - 建議：guest 內掛載公司 Nextcloud WebDAV（/usr/local/bin/mount-nextcloud-webdav.sh）。
#   - 本機/測試：可選 --workspace-ext4 掛第三顆可寫 ext4（通常為 /dev/vdb 無 ro-skills 時，或 /dev/vdc 有 ro-skills 時）。
#   - virtio-fs：上游 Firecracker 目前無 virtio-fs API；若未來支援再改由 host virtiofsd 分享目錄。
#
# 使用方式：
#   sudo ./scripts/attach-microvm-shell.sh \
#     [--kernel <vmlinux>] \
#     [--rootfs <ubuntu-noble-base.rootfs.ext4>] \
#     [--ro-skills <ro-skills.ext4>] \
#     [--workspace-ext4 <writable.ext4>] \
#     [--vm-id <id>] \
#     [--detach] \
#     [--no-cleanup] \
#     [--vm-ip <IP>] \
#     [--user <user>]
#
# 預設：--vm-ip 172.30.0.2，--user root
#
# 若尚未在 rootfs 啟用 SSH，請在 prepare-ubuntu-noble-rootfs.sh 加上 --enable-ssh，
# 或 chroot 進 rootfs 後：apt install -y openssh-server && systemctl enable ssh
#

set -euo pipefail

KERNEL_PATH=""
ROOTFS_PATH=""
RO_SKILLS_PATH=""
WORKSPACE_EXT4_PATH=""
VM_ID="noble-test"
FC_BINARY="${FC_BINARY:-}"
VM_IP="${VM_IP:-172.30.0.2}"
HOST_IP="172.30.0.1"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="22"
VCPU_COUNT="${VCPU_COUNT:-2}"
MEM_SIZE_MIB="${MEM_SIZE_MIB:-2048}"
DETACH="false"
NO_CLEANUP="false"
ENABLE_NAT="true"

usage() {
  cat <<'EOF'
用法：
  sudo ./scripts/attach-microvm-shell.sh \
    [--kernel <vmlinux 路徑>] \
    [--rootfs <ubuntu-noble-base.rootfs.ext4 路徑>] \
    [--ro-skills <ro-skills.ext4 路徑>] \
    [--workspace-ext4 <可寫 workspace ext4>] \
    [--vm-id <id>] \
    [--detach] \
    [--no-cleanup] \
    [--no-nat] \
    [--vm-ip <IP>] \
    [--user <user>]

預設：
  - kernel=bin/vmlinux.bin
  - rootfs=bin/ubuntu-noble-base.rootfs.ext4
  - vm-id=noble-test
  - vm-ip=172.30.0.2
  - user=root

選項：
  --workspace-ext4  第三顆可寫 ext4（無 ro-skills 時 guest 多為 /dev/vdb；有 ro-skills 時多為 /dev/vdc）
  --detach     只啟動 VM 並等待 SSH port ready 後就退出（VM 背景保活；等同 --no-cleanup）
  --no-cleanup 腳本結束時不 kill firecracker、不刪 TAP（你需要用 stop-microvm.sh 手動停止）
  --no-nat     不自動設置 host 端 NAT/forward（預設會啟用，讓 VM 有外網）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel) KERNEL_PATH="${2:-}"; shift 2;;
    --rootfs) ROOTFS_PATH="${2:-}"; shift 2;;
    --ro-skills) RO_SKILLS_PATH="${2:-}"; shift 2;;
    --workspace-ext4) WORKSPACE_EXT4_PATH="${2:-}"; shift 2;;
    --vm-id) VM_ID="${2:-}"; shift 2;;
    --detach) DETACH="true"; shift;;
    --no-cleanup) NO_CLEANUP="true"; shift;;
    --no-nat) ENABLE_NAT="false"; shift;;
    --vm-ip) VM_IP="${2:-}"; shift 2;;
    --user) SSH_USER="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "未知參數：$1"; usage; exit 1;;
  esac
done

if [[ "${DETACH}" == "true" ]]; then
  NO_CLEANUP="true"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL_PATH="${KERNEL_PATH:-${ROOT_DIR}/bin/vmlinux.bin}"
ROOTFS_PATH="${ROOTFS_PATH:-${ROOT_DIR}/bin/ubuntu-noble-base.rootfs.ext4}"

if [[ $EUID -ne 0 ]]; then
  echo "錯誤：本腳本需要 root 權限（建立 tap、存取 /dev/kvm）。"
  echo "請改用：sudo $0 ..."
  exit 1
fi

if [[ ! -e /dev/kvm ]]; then
  echo "錯誤：/dev/kvm 不存在。請確認主機支援 KVM。"
  exit 1
fi

if [[ ! -f "${KERNEL_PATH}" ]]; then
  echo "錯誤：找不到 kernel：${KERNEL_PATH}"
  exit 1
fi
if [[ ! -f "${ROOTFS_PATH}" ]]; then
  echo "錯誤：找不到 rootfs：${ROOTFS_PATH}"
  exit 1
fi
if [[ -n "${RO_SKILLS_PATH}" && ! -f "${RO_SKILLS_PATH}" ]]; then
  echo "錯誤：找不到 ro-skills 映像：${RO_SKILLS_PATH}"
  exit 1
fi
if [[ -n "${WORKSPACE_EXT4_PATH}" && ! -f "${WORKSPACE_EXT4_PATH}" ]]; then
  echo "錯誤：找不到 workspace ext4：${WORKSPACE_EXT4_PATH}"
  exit 1
fi

if [[ -z "${FC_BINARY}" ]]; then
  FC_BINARY="${ROOT_DIR}/bin/firecracker"
  [[ ! -x "${FC_BINARY}" ]] && FC_BINARY="$(command -v firecracker || true)"
fi
if [[ -z "${FC_BINARY}" || ! -x "${FC_BINARY}" ]]; then
  echo "錯誤：找不到 firecracker 二進位。請設定 FC_BINARY 或將 firecracker 放入 PATH，或放置於 bin/firecracker。"
  exit 1
fi

WORK_DIR="/tmp/fc-${VM_ID}"
API_SOCK="${WORK_DIR}/api.sock"
LOG_FILE="${WORK_DIR}/fc.log"
tap_name_for_vm_id() {
  local vm_id="$1"
  local candidate="fc-${vm_id}"
  if (( ${#candidate} <= 15 )); then
    echo "${candidate}"
    return 0
  fi
  # Linux ifname 最多 15 字元；用 hash 生成穩定短名（fc- + 11 = 14）
  echo "fc-$(printf '%s' "${vm_id}" | sha1sum | awk '{print $1}' | cut -c1-11)"
}

TAP_NAME="$(tap_name_for_vm_id "${VM_ID}")"
FC_PID=""

fc_put_json() {
  local path="$1"
  local json="$2"
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X PUT --unix-socket "${API_SOCK}" \
    -H "Content-Type: application/json" \
    -d "${json}" \
    "http://localhost${path}" || true)"
  if [[ "${code}" != "204" ]]; then
    echo "錯誤：Firecracker API PUT ${path} 失敗（HTTP ${code}）"
    echo "  - 請查看日誌：${LOG_FILE}"
    exit 1
  fi
}

fc_get_json() {
  local path="$1"
  curl -sS --unix-socket "${API_SOCK}" "http://localhost${path}"
}

detect_uplink_dev() {
  # 取 host 預設路由出口介面
  ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

iptables_ensure() {
  # 用 -C 檢查不存在才新增，確保可重複執行
  if iptables "$@" 2>/dev/null; then
    return 0
  fi
  # 將 -C 改成 -A（其餘參數不變）
  local args=("$@")
  local i
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "-C" ]]; then
      args[$i]="-A"
      break
    fi
  done
  iptables "${args[@]}"
}

ensure_nat() {
  local tap="$1"
  local subnet="172.30.0.0/24"
  local uplink
  uplink="$(detect_uplink_dev)"
  if [[ -z "${uplink}" ]]; then
    echo "⚠️ 無法偵測 host 預設路由出口介面，略過 NAT 設定。"
    return 0
  fi
  if ! command -v iptables >/dev/null 2>&1; then
    echo "⚠️ host 缺少 iptables，略過 NAT 設定。"
    return 0
  fi

  echo "==> Step 1b. 設定 host NAT（tap=${tap} uplink=${uplink} subnet=${subnet}）"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # NAT 出口
  iptables_ensure -t nat -C POSTROUTING -s "${subnet}" -o "${uplink}" -j MASQUERADE
  # 允許 VM -> 外網轉送
  iptables_ensure -C FORWARD -i "${tap}" -o "${uplink}" -s "${subnet}" -j ACCEPT
  # 允許回程流量
  iptables_ensure -C FORWARD -i "${uplink}" -o "${tap}" -d "${subnet}" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

cleanup_vm() {
  echo "==> 清理 VM：停止 Firecracker 與釋放資源"
  if [[ -n "${FC_PID}" ]]; then
    kill "${FC_PID}" 2>/dev/null || true
  fi
  ip link del "${TAP_NAME}" 2>/dev/null || true
}

if [[ "${NO_CLEANUP}" != "true" ]]; then
  trap cleanup_vm EXIT
fi

mkdir -p "${WORK_DIR}"

echo "==> Step 1. 建立 tap 介面（${TAP_NAME}）"
ip tuntap add dev "${TAP_NAME}" mode tap || true
# 可重複執行：先清掉舊 IP 再設新 IP，避免「Address already assigned」
ip addr flush dev "${TAP_NAME}" 2>/dev/null || true
ip addr add "${HOST_IP}/24" dev "${TAP_NAME}" || true
ip link set "${TAP_NAME}" up
if [[ "${ENABLE_NAT}" == "true" ]]; then
  ensure_nat "${TAP_NAME}"
fi

echo
echo "==> Step 2. 啟動 Firecracker process"
rm -f "${API_SOCK}" "${LOG_FILE}"
"${FC_BINARY}" --api-sock "${API_SOCK}" --id "${VM_ID}" >"${LOG_FILE}" 2>&1 &
FC_PID=$!

STATE_FILE="${WORK_DIR}/state.env"
cat > "${STATE_FILE}" <<EOF
VM_ID=${VM_ID}
FC_PID=${FC_PID}
API_SOCK=${API_SOCK}
LOG_FILE=${LOG_FILE}
TAP_NAME=${TAP_NAME}
HOST_IP=${HOST_IP}
VM_IP=${VM_IP}
SSH_PORT=${SSH_PORT}
EOF

echo "  - 等待 API socket 建立..."
for _ in $(seq 1 50); do
  [[ -S "${API_SOCK}" ]] && break
  sleep 0.1
done
if [[ ! -S "${API_SOCK}" ]]; then
  echo "錯誤：Firecracker API socket 未建立，請查看 log：${LOG_FILE}"
  exit 1
fi

echo
echo "==> Step 3. 設定 VM（kernel / rootfs / 網路）"
echo "  - machine-config：vcpu_count=${VCPU_COUNT} mem_size_mib=${MEM_SIZE_MIB}"
fc_put_json "/machine-config" "{
  \"vcpu_count\": ${VCPU_COUNT},
  \"mem_size_mib\": ${MEM_SIZE_MIB}
}"
echo "  - machine-config（readback）：$(fc_get_json "/machine-config")"

fc_put_json "/boot-source" "{
  \"kernel_image_path\": \"${KERNEL_PATH}\",
  \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off\"
}"

fc_put_json "/drives/rootfs" "{
  \"drive_id\": \"rootfs\",
  \"path_on_host\": \"${ROOTFS_PATH}\",
  \"is_root_device\": true,
  \"is_read_only\": false
}"

if [[ -n "${RO_SKILLS_PATH}" ]]; then
  fc_put_json "/drives/ro_skills" "{
    \"drive_id\": \"ro_skills\",
    \"path_on_host\": \"${RO_SKILLS_PATH}\",
    \"is_root_device\": false,
    \"is_read_only\": true
  }"
fi

if [[ -n "${WORKSPACE_EXT4_PATH}" ]]; then
  fc_put_json "/drives/workspace" "{
    \"drive_id\": \"workspace\",
    \"path_on_host\": \"${WORKSPACE_EXT4_PATH}\",
    \"is_root_device\": false,
    \"is_read_only\": false
  }"
fi

GUEST_MAC="52:54:00:1e:00:02"
fc_put_json "/network-interfaces/eth0" "{
  \"iface_id\": \"eth0\",
  \"guest_mac\": \"${GUEST_MAC}\",
  \"host_dev_name\": \"${TAP_NAME}\"
}"

echo
echo "==> Step 4. 啟動 VM"
fc_put_json "/actions" '{ "action_type": "InstanceStart" }'

echo
echo "==> Step 5. 等待 SSH 可連線（${VM_IP}:${SSH_PORT}）"
TIMEOUT_S=90
START_S=$(date +%s)
while :; do
  if timeout 1 bash -c "echo >/dev/tcp/${VM_IP}/${SSH_PORT}" 2>/dev/null; then
    break
  fi
  NOW_S=$(date +%s)
  if (( NOW_S - START_S > TIMEOUT_S )); then
    echo "錯誤：等待 ${TIMEOUT_S}s 仍無法連到 ${VM_IP}:${SSH_PORT}"
    echo "請查看 guest 開機日誌：${LOG_FILE}"
    exit 1
  fi
  sleep 1
done

echo "  - VM 狀態檔：${STATE_FILE}"
if [[ -n "${WORKSPACE_EXT4_PATH}" ]]; then
  if [[ -n "${RO_SKILLS_PATH}" ]]; then
    echo "  - 已掛載 workspace ext4：guest 內通常為 /dev/vdc（請自行 mkfs/mount）"
  else
    echo "  - 已掛載 workspace ext4：guest 內通常為 /dev/vdb（請自行 mkfs/mount）"
  fi
fi

if [[ "${DETACH}" == "true" ]]; then
  echo
  echo "==> 已完成啟動（背景保活）"
  echo "  - 連線：ssh ${SSH_USER}@${VM_IP}"
  echo "  - 停止：sudo ./scripts/stop-microvm.sh --vm-id ${VM_ID}"
  echo "  - 日誌：${LOG_FILE}"
  exit 0
fi

echo
echo "==> 連線至 microVM（${SSH_USER}@${VM_IP}）"
echo "  - 提示：若你用 prepare 的 --enable-ssh，root 密碼預設為 opencode（僅開發/測試用）"
echo "  - 本腳本會強制用 password auth（避免只嘗試 publickey 而被拒絕）"
echo ""

exec ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 \
  -o PreferredAuthentications=password,keyboard-interactive \
  -o PubkeyAuthentication=no \
  "${SSH_USER}@${VM_IP}"
