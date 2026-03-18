#!/usr/bin/env bash
#
# build-base-rootfs-opencode.sh（noble base rootfs wrapper）
#
# 目的：
#   早期版本是「在 bionic.rootfs.ext4 裡面直接裝 OpenCode」，
#   現在已改為「統一透過 Ubuntu 24.04 noble base rootfs」：
#     - 完整 apt/dpkg 環境
#     - JS/Python toolchain
#     - OpenCode 官方安裝 + systemd service（opencode serve --port 4096）
#     - skills skeleton：~/.config/opencode/skills
#
#   這支腳本只是一個「方便記憶的薄 wrapper」，
#   實際工作交給：scripts/prepare-ubuntu-noble-rootfs.sh
#
# 實作對應：docs/IMPLEMENTATION-PLAN-OPENCODE-VM.md
#
# 基本用法：
#   sudo ./scripts/build-base-rootfs-opencode.sh
#
#   等同於：
#   sudo ./scripts/prepare-ubuntu-noble-rootfs.sh \
#     --output bin/ubuntu-noble-base.rootfs.ext4 \
#     --size-gb 12

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "錯誤：本腳本需要 root 權限。"
  echo "請改用：sudo $0"
  exit 1
fi

ROOTFS_DEFAULT="bin/ubuntu-noble-base.rootfs.ext4"
RO_SKILLS_DEFAULT="bin/ro-skills.ext4"

echo "==> noble base rootfs wrapper"
echo "  - 即將呼叫：scripts/prepare-ubuntu-noble-rootfs.sh"
echo "  - 目標 rootfs：${ROOTFS_DEFAULT}"
echo "  - 預設大小：5 GB"
echo
read -r -p "按 Enter 繼續（或 Ctrl+C 中止）..." _

if [[ -f "${RO_SKILLS_DEFAULT}" ]]; then
  echo "==> 已存在 ${RO_SKILLS_DEFAULT}，略過 package-ro-skills.sh"
else
  "$(dirname "$0")/package-ro-skills.sh" \
    --source skills/ \
    --output "${RO_SKILLS_DEFAULT}" \
    --size-mb 64
fi

exec "$(dirname "$0")/prepare-ubuntu-noble-rootfs.sh" \
  --output "${ROOTFS_DEFAULT}" \
  --size-gb 5 \
  --disable-resolved \
  --enable-ssh
