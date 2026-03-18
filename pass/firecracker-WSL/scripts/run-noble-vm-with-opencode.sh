#!/usr/bin/env bash
#
# run-noble-vm-with-opencode.sh
#
# 目的：
#   用「新的 Ubuntu 24.04 noble base rootfs」啟動一台 Firecracker microVM，
#   在 VM 內啟動 `opencode serve --port 4096`，並由 host 測量「從下指令到 API 可用」的啟動時間。
#
# 前置條件：
#   1. 已執行過：
#        sudo ./scripts/prepare-ubuntu-noble-rootfs.sh --output bin/ubuntu-noble-base.rootfs.ext4 --size-gb 12
#   2. host 上已有：
#        - firecracker 二進位（環境變數 FC_BINARY 指向，或 PATH 中有 firecracker）
#        - noble kernel（例如 ubuntu 提供的 vmlinux，可先用 quickstart 的 vmlinux）
#   3. host 可以以 root 建立 tap 介面與 /dev/kvm
#
# 使用方式（一次只跑一台 VM）：
#   sudo ./scripts/run-noble-vm-with-opencode.sh \
#     --kernel bin/vmlinux.bin \
#     --rootfs bin/ubuntu-noble-base.rootfs.ext4 \
#     --vm-id noble-test-1
#
#   腳本會：
#     - 建立 tap 介面（簡單靜態 IP 拓樸）
#     - 啟動 Firecracker，指定 kernel + rootfs
#     - 在 VM 內啟動 opencode serve --port 4096
#     - 從 host 透過 curl 對 VM 測試 /health（示意）並量測啟動時間

set -euo pipefail

KERNEL_PATH=""
ROOTFS_PATH=""
RO_SKILLS_PATH=""
VM_ID="noble-test"
FC_BINARY="${FC_BINARY:-}"
ENABLE_NAT="true"

usage_vm() {
  cat <<'EOF'
用法：
  sudo ./scripts/run-noble-vm-with-opencode.sh \
    [--kernel <vmlinux 路徑>]   # 預設：bin/vmlinux.bin \
    [--rootfs <ubuntu-noble-base.rootfs.ext4 路徑>]   # 預設：bin/ubuntu-noble-base.rootfs.ext4 \
    [--ro-skills <ro-skills.ext4 路徑>]   # 可選：掛載為 guest /dev/vdb → ~/.config/opencode/skills \
    [--vm-id <id>] \
    [--no-nat]

前置：
  - 先用 prepare-ubuntu-noble-rootfs.sh 產生 rootfs
  - host 需有 /dev/kvm 且有權限
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kernel) KERNEL_PATH="${2:-}"; shift 2;;
    --rootfs) ROOTFS_PATH="${2:-}"; shift 2;;
    --ro-skills) RO_SKILLS_PATH="${2:-}"; shift 2;;
    --vm-id) VM_ID="${2:-}"; shift 2;;
    --no-nat) ENABLE_NAT="false"; shift;;
    -h|--help) usage_vm; exit 0;;
    *) echo "未知參數：$1"; usage_vm; exit 1;;
  esac
done

# 預設路徑（相對於專案根目錄，由呼叫者從專案根執行）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL_PATH="${KERNEL_PATH:-${ROOT_DIR}/bin/vmlinux.bin}"
ROOTFS_PATH="${ROOTFS_PATH:-${ROOT_DIR}/bin/ubuntu-noble-base.rootfs.ext4}"

# 讓本次執行的所有 console 輸出都落到 logs/run-noble-vm-<ts>.log
BENCH_LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "${BENCH_LOG_DIR}"
RUN_TAG="$(date +%y%m%d-%H%M%S)"
RUN_LOG_FILE="${BENCH_LOG_DIR}/run-noble-vm-${RUN_TAG}.log"
exec > >(tee -a "${RUN_LOG_FILE}") 2>&1

echo "==> Step 0. 檢查環境與參數"
if [[ $EUID -ne 0 ]]; then
  echo "錯誤：本腳本需要 root 權限（建立 tap、存取 /dev/kvm）。"
  echo "請改用：sudo $0 ..."
  exit 1
fi

if [[ -z "${KERNEL_PATH}" || -z "${ROOTFS_PATH}" ]]; then
  echo "錯誤：必須提供 --kernel 與 --rootfs"
  usage_vm
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

# 預設使用專案 bin/firecracker（sudo 不會繼承 FC_BINARY 環境變數）
if [[ -z "${FC_BINARY}" ]]; then
  FC_BINARY="${ROOT_DIR}/bin/firecracker"
  [[ ! -x "${FC_BINARY}" ]] && FC_BINARY="$(command -v firecracker || true)"
fi
if [[ -z "${FC_BINARY}" || ! -x "${FC_BINARY}" ]]; then
  echo "錯誤：找不到 firecracker 二進位。請設定 FC_BINARY 或將 firecracker 放入 PATH，或放置於 bin/firecracker。"
  exit 1
fi

if [[ ! -e /dev/kvm ]]; then
  echo "錯誤：/dev/kvm 不存在。請確認主機支援 KVM。"
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
VM_IP="172.30.0.2"   # 注意：需與 VM 內的網路設定一致（可用 cloud-init/netplan 設為固定 IP）
HOST_IP="172.30.0.1"
VCPU_COUNT="${VCPU_COUNT:-2}"
MEM_SIZE_MIB="${MEM_SIZE_MIB:-2048}"
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
  ip route show default 0.0.0.0/0 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

iptables_ensure() {
  if iptables "$@" 2>/dev/null; then
    return 0
  fi
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

  iptables_ensure -t nat -C POSTROUTING -s "${subnet}" -o "${uplink}" -j MASQUERADE
  iptables_ensure -C FORWARD -i "${tap}" -o "${uplink}" -s "${subnet}" -j ACCEPT
  iptables_ensure -C FORWARD -i "${uplink}" -o "${tap}" -d "${subnet}" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

cleanup_vm() {
  echo "==> 清理 VM：停止 Firecracker 與釋放資源"
  # Firecracker 不支援 InstanceStop；以 SIGTERM 結束 process 即可停止 VM
  if [[ -n "${FC_PID}" ]]; then
    kill "${FC_PID}" 2>/dev/null || true
  fi
  ip link del "${TAP_NAME}" 2>/dev/null || true
}
trap cleanup_vm EXIT

mkdir -p "${WORK_DIR}"

echo "  - VM ID：${VM_ID}"
echo "  - Firecracker：${FC_BINARY}"
echo "  - Kernel：${KERNEL_PATH}"
echo "  - Rootfs：${ROOTFS_PATH}"
[[ -n "${RO_SKILLS_PATH}" ]] && echo "  - RO skills：${RO_SKILLS_PATH}"
echo "  - Workdir：${WORK_DIR}"

echo
echo "==> Step 1. 建立 tap 介面（簡單單機網路拓樸）"
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

# MAC 須為 6 組十六進位位元組（如 52:54:00:1e:00:02），不可用 VM_ID 字元
GUEST_MAC="52:54:00:1e:00:02"
fc_put_json "/network-interfaces/eth0" "{
  \"iface_id\": \"eth0\",
  \"guest_mac\": \"${GUEST_MAC}\",
  \"host_dev_name\": \"${TAP_NAME}\"
}"

echo
echo "==> Step 4. 啟動 VM"
START_TS=$(date +%s%3N)
fc_put_json "/actions" '{ "action_type": "InstanceStart" }'

echo "  - VM 已啟動，等待 guest 開機並由 systemd 啟動 opencode-serve.service..."

echo
echo "==> Step 5. 由 host 偵測 opencode serve readiness 並量測啟動時間"
cat <<EOF
說明：
  - 在 prepare-ubuntu-noble-rootfs.sh 中，我們已建立 systemd 服務：
      opencode-serve.service -> opencode serve --port 4096 --hostname 0.0.0.0
  - 這裡由 host 定期對 VM_IP:4096 嘗試 HTTP 連線，第一個成功回應即視為 ready。
  - 啟動時間（ms） = 從送出 InstanceStart 到第一次成功 HTTP 回應的差值。
EOF

READY_TS=""
TIMEOUT_MS=$((180 * 1000))   # 最多等 180 秒（首次開機與 systemd 初始化可能較慢）
SLEEP_INTERVAL_MS=500

while :; do
  NOW_TS=$(date +%s%3N)
  ELAPSED=$((NOW_TS - START_TS))
  if (( ELAPSED > TIMEOUT_MS )); then
    echo "錯誤：在 ${TIMEOUT_MS} ms 內未等到 opencode serve 回應。"
    break
  fi

  if curl -s --max-time 1 "http://${VM_IP}:4096/" >/dev/null 2>&1; then
    READY_TS="${NOW_TS}"
    break
  fi

  sleep 0.5
done

if [[ -n "${READY_TS}" ]]; then
  STARTUP_MS=$((READY_TS - START_TS))
  echo "✅ opencode serve 已就緒。啟動時間：約 ${STARTUP_MS} ms"

  TS_HUMAN=$(date -d "@$((START_TS/1000))" +"%Y-%m-%dT%H:%M:%S")
  BENCH_FILE="${BENCH_LOG_DIR}/opencode-startup-${VM_ID}-$(date +%Y%m%d-%H%M%S).json"
  cat > "${BENCH_FILE}" <<EOFJSON
{
  "vm_id": "${VM_ID}",
  "kernel": "${KERNEL_PATH}",
  "rootfs": "${ROOTFS_PATH}",
  "host_ip": "${HOST_IP}",
  "vm_ip": "${VM_IP}",
  "instance_start_ts_ms": ${START_TS},
  "ready_ts_ms": ${READY_TS},
  "startup_ms": ${STARTUP_MS},
  "instance_start_human": "${TS_HUMAN}"
}
EOFJSON
  echo "  - 已將啟動時間記錄到：${BENCH_FILE}"

  echo
  echo "==> Step 6. 取得目前所有可用的模型與 Provider（/config/providers）"
  PROVIDERS_JSON=""
  PROVIDERS_FILE="${WORK_DIR}/opencode-providers.json"
  PROVIDERS_CODE="$(curl -sS -o "${PROVIDERS_FILE}" -w "%{http_code}" \
    --max-time 5 \
    "http://${VM_IP}:4096/config/providers" || true)"
  STEP6_LOG_FILE="${BENCH_LOG_DIR}/Step6-${RUN_TAG}.json"
  if [[ "${PROVIDERS_CODE}" == "200" ]]; then
    PROVIDERS_JSON="$(< "${PROVIDERS_FILE}")"
    if command -v jq >/dev/null 2>&1; then
      echo "${PROVIDERS_JSON}" | jq .
    else
      echo "${PROVIDERS_JSON}"
    fi
  else
    echo "⚠️ 無法取得 /config/providers（HTTP ${PROVIDERS_CODE}）。"
  fi
  # 儲存 Step 6 原始回應（含 HTTP code 與 body）
  python3 - <<PY || true
import json, pathlib
log_path = pathlib.Path(${STEP6_LOG_FILE@Q})
body_path = pathlib.Path(${PROVIDERS_FILE@Q})
code = ${PROVIDERS_CODE@Q}
payload = {
  "step": 6,
  "vm_id": ${VM_ID@Q},
  "vm_ip": ${VM_IP@Q},
  "endpoint": "/config/providers",
  "url": f"http://{${VM_IP@Q}}:4096/config/providers",
  "http_code": code,
  "body": None,
}
try:
  raw = body_path.read_text(encoding="utf-8")
except Exception:
  raw = ""
if raw.strip():
  try:
    payload["body"] = json.loads(raw)
  except Exception:
    payload["body"] = raw
log_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"  - Step 6 JSON 已儲存：{log_path}")
PY

  echo
  echo "==> Step 7. 用對話方式詢問「目前使用的是哪個 LLM？」"
  # 透過 server API 建立暫時 session，送出一則訊息，印出回覆內容。
  # 這裡不指定 model/provider，讓 opencode 依其目前 config 的預設模型回覆。
  SESSION_ID="$(
    curl -sS --max-time 5 \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"llm-check-${VM_ID}\"}" \
      "http://${VM_IP}:4096/session" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true
  )"
  if [[ -z "${SESSION_ID}" ]]; then
    echo "⚠️ 無法建立 session（/session）。略過 Step 7。"
  else
    REPLY_JSON="$(
      curl -sS --max-time 30 \
        -H "Content-Type: application/json" \
        -d "$(cat <<'EOF'
{
  "parts": [
    {
      "type": "text",
      "text": "目前使用的是哪個 LLM？"
    }
  ]
}
EOF
)" \
        "http://${VM_IP}:4096/session/${SESSION_ID}/message" \
      || true
    )"

    STEP7_LOG_FILE="${BENCH_LOG_DIR}/Step7-${RUN_TAG}.json"
    if [[ -z "${REPLY_JSON}" ]]; then
      echo "⚠️ Step 7 未收到回覆（空回應）。"
    else
      # 儲存 Step 7 原始回應（message response JSON）
      python3 - <<PY || true
import json, pathlib
log_path = pathlib.Path(${STEP7_LOG_FILE@Q})
raw = ${REPLY_JSON@Q}
payload = {
  "step": 7,
  "vm_id": ${VM_ID@Q},
  "vm_ip": ${VM_IP@Q},
  "endpoint": "/session/:id/message",
  "url": f"http://{${VM_IP@Q}}:4096/session/{${SESSION_ID@Q}}/message",
  "body": None,
}
if raw.strip():
  try:
    payload["body"] = json.loads(raw)
  except Exception:
    payload["body"] = raw
log_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"  - Step 7 JSON 已儲存：{log_path}")
PY

      # 盡量抽出 text parts；抽不到就印原始 JSON 方便除錯
      if command -v jq >/dev/null 2>&1; then
        echo "${REPLY_JSON}" | jq -r '
          if (.parts and (.parts|type)=="array") then
            (.parts[] | select(.type=="text") | .text) // empty
          else
            empty
          end
        ' | sed '/^$/d' || echo "${REPLY_JSON}"
      else
        printf '%s' "${REPLY_JSON}" | python3 - <<'PY' || echo "${REPLY_JSON}"
import json,sys
raw = sys.stdin.read()
try:
  obj = json.loads(raw)
except Exception:
  # 解析失敗就交給 shell fallback 印原始 JSON，避免 traceback 汙染輸出
  raise SystemExit(1)
parts = obj.get("parts", [])
texts = [p.get("text","") for p in parts if p.get("type")=="text" and p.get("text")]
if texts:
  print("\n".join(texts))
else:
  # 找不到文字 parts 時，維持原始輸出方便除錯
  raise SystemExit(1)
PY
      fi
    fi
  fi

  echo
  echo "==> Step 8. 掛載 ro-skills.ext4 並要求 opencode 自動使用 calltracker（skills/CallTracker/SKILL.md）"
  if [[ -z "${RO_SKILLS_PATH}" ]]; then
    echo "⚠️ 未提供 --ro-skills，無法驗證 calltracker skills。略過 Step 8。"
  elif [[ -z "${SESSION_ID}" ]]; then
    echo "⚠️ Step 7 未建立 session，無法透過 API 執行 shell/對話。略過 Step 8。"
  else
    STEP8_LOG_FILE="${BENCH_LOG_DIR}/Step8-${RUN_TAG}.json"

    # 1) 在 guest 內確認 ro-skills 已掛載（rootfs 端已啟用 mount-ro-skills.service）
    STEP8_SHELL_FILE="${WORK_DIR}/step8-shell.json"
    STEP8_SHELL_CODE="$(curl -sS -o "${STEP8_SHELL_FILE}" -w "%{http_code}" \
      --max-time 20 \
      -H "Content-Type: application/json" \
      -d "$(cat <<'EOF'
{
  "agent": "build",
  "command": "set -euo pipefail; sudo test -d /root/.config/opencode/skills; sudo mountpoint -q /root/.config/opencode/skills; ls -la /root/.config/opencode/skills/CallTracker/SKILL.md"
}
EOF
)" \
      "http://${VM_IP}:4096/session/${SESSION_ID}/shell" || true)"

    # 2) 用對話要求它使用 calltracker skill 跑一次 tracker，留下紀錄
    # "text": "請自動使用 calltracker skills（對應 skills/CallTracker/SKILL.md）。\n\n任務：請用 calltracker 的 Record Call 執行一次追蹤，任務名稱用 \"step8-calltracker\"，agent 用 \"run-noble-vm-with-opencode\"，remarks 用 \"verify ro-skills mount + skill invocation\"。\n\n完成後請回覆：你執行了哪個命令、以及寫入的日誌檔位置。"

    STEP8_REPLY_FILE="${WORK_DIR}/step8-reply.json"
    STEP8_REPLY_CODE="$(curl -sS -o "${STEP8_REPLY_FILE}" -w "%{http_code}" \
      --max-time 60 \
      -H "Content-Type: application/json" \
      -d "$(cat <<'EOF'
{
  "agent": "build",
  "tools": {},
  "parts": [
    {
      "type": "text",
      "text": "請在 VM 內執行一個可稽核的落盤動作（不要只用文字描述）。\n\n需求：\n- 對檔案 `logs/audit_trails.jsonl` 追加 1 行 JSONL（單行 JSON）。\n- 該 JSON 必須包含欄位：timestamp、agent、task、remarks、status。\n- 值請填：task=「測試 Agent 呼叫流程」、agent=\"user_direct\"、remarks=「驗證自動判斷是否需使用工具/skills」、status=\"INFO\"。\n\n完成後請回覆兩段內容：\n1) 你追加的那一整行 JSONL（原樣貼出）\n2) 追加後 `logs/audit_trails.jsonl` 的最後一行（用任何方式讀回來驗證）"
    }
  ]
}
EOF
)" \
      "http://${VM_IP}:4096/session/${SESSION_ID}/message" || true)"

    # 3) 另外用 shell 再驗證一次檔案尾端（避免模型只口頭回覆）
    STEP8_VERIFY_FILE="${WORK_DIR}/step8-verify.json"
    STEP8_VERIFY_CODE="$(curl -sS -o "${STEP8_VERIFY_FILE}" -w "%{http_code}" \
      --max-time 20 \
      -H "Content-Type: application/json" \
      -d "$(cat <<'EOF'
{
  "agent": "build",
  "command": "set -euo pipefail; test -f logs/audit_trails.jsonl; tail -n 1 logs/audit_trails.jsonl"
}
EOF
)" \
      "http://${VM_IP}:4096/session/${SESSION_ID}/shell" || true)"

    # 儲存 Step 8 原始回應（含 HTTP code 與 body）
    python3 - <<PY || true
import json, pathlib
log_path = pathlib.Path(${STEP8_LOG_FILE@Q})
shell_path = pathlib.Path(${STEP8_SHELL_FILE@Q})
reply_path = pathlib.Path(${STEP8_REPLY_FILE@Q})
verify_path = pathlib.Path(${STEP8_VERIFY_FILE@Q})
payload = {
  "step": 8,
  "vm_id": ${VM_ID@Q},
  "vm_ip": ${VM_IP@Q},
  "session_id": ${SESSION_ID@Q},
  "shell": {
    "endpoint": "/session/:id/shell",
    "url": f"http://{${VM_IP@Q}}:4096/session/{${SESSION_ID@Q}}/shell",
    "http_code": ${STEP8_SHELL_CODE@Q},
    "body": None,
  },
  "message": {
    "endpoint": "/session/:id/message",
    "url": f"http://{${VM_IP@Q}}:4096/session/{${SESSION_ID@Q}}/message",
    "http_code": ${STEP8_REPLY_CODE@Q},
    "body": None,
  },
  "verify": {
    "endpoint": "/session/:id/shell",
    "url": f"http://{${VM_IP@Q}}:4096/session/{${SESSION_ID@Q}}/shell",
    "http_code": ${STEP8_VERIFY_CODE@Q},
    "body": None,
  },
}
def load_body(p: pathlib.Path):
  try:
    raw = p.read_text(encoding="utf-8")
  except Exception:
    return None
  if not raw.strip():
    return None
  try:
    return json.loads(raw)
  except Exception:
    return raw
payload["shell"]["body"] = load_body(shell_path)
payload["message"]["body"] = load_body(reply_path)
payload["verify"]["body"] = load_body(verify_path)
log_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"  - Step 8 JSON 已儲存：{log_path}")
PY

    # 仍印出 Step 8 的 message 文字回覆到 console（同時會被 tee 到 run log）
    STEP8_REPLY_JSON=""
    if [[ -f "${STEP8_REPLY_FILE}" ]]; then
      STEP8_REPLY_JSON="$(< "${STEP8_REPLY_FILE}")"
    fi
    if [[ -z "${STEP8_REPLY_JSON}" ]]; then
      echo "⚠️ Step 8 未收到回覆（空回應）。"
    else
      if command -v jq >/dev/null 2>&1; then
        echo "${STEP8_REPLY_JSON}" | jq -r '
          if (.parts and (.parts|type)=="array") then
            (.parts[] | select(.type=="text") | .text) // empty
          else
            empty
          end
        ' | sed '/^$/d' || echo "${STEP8_REPLY_JSON}"
      else
        printf '%s' "${STEP8_REPLY_JSON}" | python3 - <<'PY' || echo "${STEP8_REPLY_JSON}"
import json,sys
raw = sys.stdin.read()
try:
  obj = json.loads(raw)
except Exception:
  raise SystemExit(1)
parts = obj.get("parts", [])
texts = [p.get("text","") for p in parts if p.get("type")=="text" and p.get("text")]
if texts:
  print("\n".join(texts))
else:
  raise SystemExit(1)
PY
      fi
    fi
  fi
else
  echo "⚠️ 未成功量測啟動時間（可能是 VM 內網路或 opencode 服務未正常啟動）。"
  echo
  echo "==> 診斷（協助判斷是 VM 未起來或 opencode 未啟動）："
  # 1. VM 是否可達（ping）
  if ping -c 1 -W 2 "${VM_IP}" >/dev/null 2>&1; then
    echo "  - 網路：VM ${VM_IP} 可 ping 通（guest 已取得 IP）。"
  else
    echo "  - 網路：VM ${VM_IP} 無法 ping 通（guest 可能未開機或未設好 IP）。"
  fi
  # 2. 埠 4096 是否可連
  if timeout 2 bash -c "echo >/dev/tcp/${VM_IP}/4096" 2>/dev/null; then
    echo "  - 埠 4096：可連線（opencode 可能已 listen，但 HTTP 檢查未過）。"
  else
    echo "  - 埠 4096：無法連線（opencode 可能未啟動或未 listen）。"
  fi
  # 3. Firecracker 日誌最後幾行（可看到 kernel/guest 輸出）
  echo "  - Firecracker 日誌（最後 40 行，路徑：${LOG_FILE}）："
  if [[ -f "${LOG_FILE}" ]]; then
    tail -n 40 "${LOG_FILE}" | sed 's/^/      /'
  else
    echo "      （無日誌檔）"
  fi
  echo "  - 完整日誌可查閱：${LOG_FILE}"
fi

