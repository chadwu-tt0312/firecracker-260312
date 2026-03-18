#!/usr/bin/env bash
#
# stop-microvm.sh
#
# 目的：停止並清理由 attach-microvm-shell.sh 啟動的 microVM（背景保活用）。
#
# 使用方式：
#   sudo ./scripts/stop-microvm.sh --vm-id <id>
#

set -euo pipefail

VM_ID=""
STOP_ALL="false"

usage() {
  cat <<'EOF'
用法：
  sudo ./scripts/stop-microvm.sh --vm-id <id>
  sudo ./scripts/stop-microvm.sh --all

說明：
  - 會讀取 /tmp/fc-<id>/state.env 取得 FC_PID/TAP_NAME 等資訊
  - 會 kill firecracker PID，並刪除 TAP 介面
  - --all 會掃描 /tmp/fc-*/state.env，逐一停止並清理所有 microVM
EOF
}

stop_one() {
  local vm_id="$1"
  local work_dir="/tmp/fc-${vm_id}"
  local state_file="${work_dir}/state.env"
  local hashed_tap="fc-$(printf '%s' "${vm_id}" | sha1sum | awk '{print $1}' | cut -c1-11)"

  if [[ ! -f "${state_file}" ]]; then
    echo "==> 找不到狀態檔，改用 vm-id 強制清理（vm-id=${vm_id}）"
    if command -v pgrep >/dev/null 2>&1; then
      while read -r pid; do
        [[ -z "${pid}" ]] && continue
        kill "${pid}" 2>/dev/null || true
      done < <(pgrep -f "firecracker .*--id ${vm_id}" || true)

      # 依慣例嘗試同 workdir 的 api.sock
      local guessed_api_sock="${work_dir}/api.sock"
      while read -r pid; do
        [[ -z "${pid}" ]] && continue
        kill "${pid}" 2>/dev/null || true
      done < <(pgrep -f "firecracker .*--api-sock ${guessed_api_sock}" || true)
    fi

    ip link del "fc-${vm_id}" 2>/dev/null || true
    ip link del "${hashed_tap}" 2>/dev/null || true
    rm -rf "${work_dir}" 2>/dev/null || true
    echo "  - 完成"
    return 0
  fi

  # shellcheck disable=SC1090
  source "${state_file}"

  echo "==> 停止 microVM（vm-id=${vm_id}）"
  echo "  - FC_PID=${FC_PID:-}"
  echo "  - API_SOCK=${API_SOCK:-}"
  echo "  - TAP_NAME=${TAP_NAME:-}"

  if [[ -n "${FC_PID:-}" ]]; then
    kill "${FC_PID}" 2>/dev/null || true
  fi

  # 有時會殘留多個 firecracker process（同 vm-id / 同 api.sock）；額外掃描並一併清掉
  if command -v pgrep >/dev/null 2>&1; then
    while read -r pid; do
      [[ -z "${pid}" ]] && continue
      [[ "${pid}" == "${FC_PID:-}" ]] && continue
      kill "${pid}" 2>/dev/null || true
    done < <(pgrep -f "firecracker .*--id ${vm_id}" || true)

    if [[ -n "${API_SOCK:-}" ]]; then
      while read -r pid; do
        [[ -z "${pid}" ]] && continue
        [[ "${pid}" == "${FC_PID:-}" ]] && continue
        kill "${pid}" 2>/dev/null || true
      done < <(pgrep -f "firecracker .*--api-sock ${API_SOCK}" || true)
    fi
  fi

  if [[ -n "${TAP_NAME:-}" ]]; then
    ip link del "${TAP_NAME}" 2>/dev/null || true
  else
    # 相容舊狀態檔或異常情境：至少依慣例嘗試刪除 fc-<vm-id>
    ip link del "fc-${vm_id}" 2>/dev/null || true
  fi

  rm -rf "${work_dir}" 2>/dev/null || true
  echo "  - 完成"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-id) VM_ID="${2:-}"; shift 2;;
    --all) STOP_ALL="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "未知參數：$1"; usage; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "錯誤：本腳本需要 root 權限。請改用：sudo $0 --vm-id <id>"
  exit 1
fi

if [[ "${STOP_ALL}" == "true" ]]; then
  shopt -s nullglob
  state_files=(/tmp/fc-*/state.env)
  if (( ${#state_files[@]} == 0 )); then
    echo "==> 未找到任何 /tmp/fc-*/state.env，可停止的 microVM 為 0"
    exit 0
  fi
  for f in "${state_files[@]}"; do
    vm_id="$(basename "$(dirname "$f")" | sed 's/^fc-//')"
    stop_one "${vm_id}"
  done
  exit 0
fi

if [[ -z "${VM_ID}" ]]; then
  echo "錯誤：必須提供 --vm-id 或 --all"
  usage
  exit 1
fi

stop_one "${VM_ID}"
