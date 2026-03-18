#!/usr/bin/env bash
#
# test-ro-skills.sh
#
# 目的：
#   1. 驗證「RO skills 映像」內容是否正確（掛載後列出 SKILL.md / 目錄結構）。
#   2. 可選：若 microVM 已啟動且 opencode serve 在跑，探測 API 並檢查是否可觸及
#      （例如 GET / 或 /health）；若 OpenCode 提供 skills 列表 API 可一併檢查。
#
# 使用方式：
#   ./scripts/test-ro-skills.sh [--image <path>] [--vm-ip <IP>]
#
# 預設：--image bin/ro-skills.ext4，--vm-ip 不設（僅驗證映像內容）
#

set -euo pipefail

IMAGE_PATH=""
VM_IP=""

usage() {
  cat <<'EOF'
用法：
  ./scripts/test-ro-skills.sh [--image <ro-skills.ext4 路徑>] [--vm-ip <microVM IP>]

  --image    RO skills 映像檔，預設 bin/ro-skills.ext4
  --vm-ip    若提供，會對該 IP:4096 做 opencode 探測（可選）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE_PATH="${2:-}"; shift 2;;
    --vm-ip) VM_IP="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "未知參數：$1"; usage; exit 1;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_PATH="${IMAGE_PATH:-${ROOT_DIR}/bin/ro-skills.ext4}"

echo "==> 1. 驗證 RO skills 映像內容"
if [[ ! -f "${IMAGE_PATH}" ]]; then
  echo "錯誤：找不到映像：${IMAGE_PATH}"
  echo "請先執行：sudo ./scripts/package-ro-skills.sh"
  exit 1
fi

NEED_SUDO=""
if [[ $EUID -ne 0 ]]; then
  NEED_SUDO="sudo"
fi

MNT=$(mktemp -d -t ro-skills-verify-XXXXXX)
cleanup() { ${NEED_SUDO} umount "${MNT}" 2>/dev/null || true; rm -rf "${MNT}"; }
trap cleanup EXIT

${NEED_SUDO} mount -o loop,ro "${IMAGE_PATH}" "${MNT}"

echo "  - 映像內目錄與 SKILL.md："
# 若用 sudo 掛載，find 也需用 sudo 才讀得到
${NEED_SUDO} find "${MNT}" -maxdepth 3 -type f -name "SKILL.md" 2>/dev/null | while read -r f; do
  echo "    - ${f#${MNT}/}"
done
${NEED_SUDO} find "${MNT}" -maxdepth 2 -type d 2>/dev/null | while read -r d; do
  [[ "$d" == "${MNT}" ]] && continue
  echo "    [dir] ${d#${MNT}/}"
done

# 檢查是否有預期的 skill（例如 CallTracker）
if ${NEED_SUDO} test -f "${MNT}/CallTracker/SKILL.md"; then
  echo "  - 找到 skill：CallTracker"
else
  echo "  - 注意：未找到 CallTracker/SKILL.md（可為正常，依你打包的 skills 而定）"
fi

echo "  - 映像內容驗證完成"
echo ""

if [[ -n "${VM_IP}" ]]; then
  echo "==> 2. 探測 microVM opencode serve（${VM_IP}:4096）"
  if curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://${VM_IP}:4096/" | grep -q 200; then
    echo "  - opencode serve 可連線（HTTP 200）"
    # 若未來 OpenCode 提供 /skills 或 /api/skills，可在此 curl 並 grep 預期 skill 名稱
  else
    echo "  - 無法連線或非 200（請確認 VM 已啟動且 opencode serve 在跑）"
  fi
else
  echo "==> 2. 略過 VM 探測（未指定 --vm-ip）"
  echo "  - 若要確認 VM 內 skills 是否被使用，可："
  echo "    1. 啟動 VM 時掛載 RO skills 映像（--ro-skills），並在 guest 掛到 ~/.config/opencode/skills"
  echo "    2. 使用 scripts/attach-microvm-shell.sh 進入 VM，執行 opencode 並觸發使用 skill，檢查輸出或日誌"
fi
