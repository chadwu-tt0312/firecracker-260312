#!/usr/bin/env bash
#
# package-ro-skills.sh
#
# 目的：
#   將專案或指定目錄下的 skills 打包成「RO skills」映像檔（ext4），
#   供 microVM 掛載到 ~/.config/opencode/skills 使用。
#
# 使用方式（需 root，因涉及 mount/mkfs）：
#   sudo ./scripts/package-ro-skills.sh [--source <dir>] [--output <path>] [--size-mb <n>]
#
# 預設：
#   --source 專案根目錄的 skills/
#   --output bin/ro-skills.ext4
#   --size-mb 64
#
# 驗證打包結果：
#   ./scripts/test-ro-skills.sh [--image bin/ro-skills.ext4]
#

set -euo pipefail

SOURCE_DIR=""
OUTPUT_PATH=""
SIZE_MB="64"

usage() {
  cat <<'EOF'
用法：
  sudo ./scripts/package-ro-skills.sh [--source <skills 目錄>] [--output <映像路徑>] [--size-mb <MB>]

預設：source=專案 skills/，output=bin/ro-skills.ext4，size-mb=64
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE_DIR="${2:-}"; shift 2;;
    --output) OUTPUT_PATH="${2:-}"; shift 2;;
    --size-mb) SIZE_MB="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "未知參數：$1"; usage; exit 1;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${SOURCE_DIR:-${ROOT_DIR}/skills}"
OUTPUT_PATH="${OUTPUT_PATH:-${ROOT_DIR}/bin/ro-skills.ext4}"

if [[ $EUID -ne 0 ]]; then
  echo "錯誤：本腳本需要 root 權限（mount、mkfs）。請改用：sudo $0 ..."
  exit 1
fi

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "錯誤：找不到 skills 目錄：${SOURCE_DIR}"
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"
WORK_DIR="$(mktemp -d -t ro-skills-XXXXXX)"
MNT="${WORK_DIR}/mnt"

cleanup() {
  umount "${MNT}" 2>/dev/null || true
  rm -rf "${WORK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 建立 RO skills 映像"
echo "  - 來源：${SOURCE_DIR}"
echo "  - 輸出：${OUTPUT_PATH}"
echo "  - 大小：${SIZE_MB} MB"

rm -f "${OUTPUT_PATH}"
truncate -s "${SIZE_MB}M" "${OUTPUT_PATH}"
mkfs.ext4 -F "${OUTPUT_PATH}" >/dev/null
mkdir -p "${MNT}"
mount -o loop "${OUTPUT_PATH}" "${MNT}"
cp -a "${SOURCE_DIR}"/. "${MNT}/"
umount "${MNT}"

echo "  - 完成：${OUTPUT_PATH}"
echo ""
echo "下一步："
echo "  1. 驗證映像內容：./scripts/test-ro-skills.sh --image ${OUTPUT_PATH}"
echo "  2. 啟動 VM 時掛載（需在 run-noble-vm-with-opencode.sh 加上 --ro-skills 並在 guest 掛到 ~/.config/opencode/skills）"
