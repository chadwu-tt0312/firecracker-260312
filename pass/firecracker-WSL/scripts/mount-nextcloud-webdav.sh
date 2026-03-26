#!/usr/bin/env bash
#
# mount-nextcloud-webdav.sh
#
# 用途：在 Firecracker **guest（Ubuntu rootfs）** 內，將公司 Nextcloud 的 WebDAV
# 掛載為本機可寫目錄，作為使用者 workspace（可變檔案）來源。
#
# 前置：
#   - rootfs 已由 prepare-ubuntu-noble-rootfs.sh 安裝 rclone、fuse3
#   - guest 可連線至 Nextcloud（通常經由 attach/run 腳本啟用的 NAT）
#
# 環境變數（必填）：
#   NEXTCLOUD_WEBDAV_URL  例如：https://cloud.example.com/remote.php/dav/files/你的帳號/
#   NEXTCLOUD_USER        Nextcloud 帳號
#   NEXTCLOUD_PASS        建議使用「應用程式密碼 / App password」
#
# 環境變數（選填）：
#   MOUNT_POINT           預設：/root/workspace
#   RCLONE_EXTRA_ARGS     附加給 rclone mount 的參數（字串）
#
# 使用範例（guest 內）：
#   export NEXTCLOUD_WEBDAV_URL="https://nextcloud.example.com/remote.php/dav/files/alice/"
#   export NEXTCLOUD_USER="alice"
#   export NEXTCLOUD_PASS="xxxx-app-password-xxxx"
#   sudo ./mount-nextcloud-webdav.sh
#
# 注意：
#   - 勿將密碼寫進 git；生產環境請改由 control plane 注入 secret 或 systemd EnvironmentFile。
#   - 本腳本預設以前景方式掛載（適合手動驗證）；背景執行可改用：rclone mount ... --daemon（依需求調整）。
#

set -euo pipefail

NEXTCLOUD_WEBDAV_URL="${NEXTCLOUD_WEBDAV_URL:-}"
NEXTCLOUD_USER="${NEXTCLOUD_USER:-}"
NEXTCLOUD_PASS="${NEXTCLOUD_PASS:-}"
MOUNT_POINT="${MOUNT_POINT:-/root/workspace}"
RCLONE_EXTRA_ARGS="${RCLONE_EXTRA_ARGS:-}"

if [[ -z "${NEXTCLOUD_WEBDAV_URL}" || -z "${NEXTCLOUD_USER}" || -z "${NEXTCLOUD_PASS}" ]]; then
  echo "錯誤：請設定 NEXTCLOUD_WEBDAV_URL、NEXTCLOUD_USER、NEXTCLOUD_PASS" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "錯誤：掛載需要 root（或請自行調整權限與 MOUNT_POINT）。" >&2
  exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
  echo "錯誤：找不到 rclone。請用 scripts/prepare-ubuntu-noble-rootfs.sh 重建 rootfs。" >&2
  exit 1
fi

mkdir -p "${MOUNT_POINT}"

CFG="$(mktemp)"
chmod 600 "${CFG}"
PASS_OBSCURE="$(rclone obscure "${NEXTCLOUD_PASS}")"

cat > "${CFG}" <<EOF
[ncworkspace]
type = webdav
url = ${NEXTCLOUD_WEBDAV_URL}
vendor = nextcloud
user = ${NEXTCLOUD_USER}
pass = ${PASS_OBSCURE}
EOF

cleanup_cfg() {
  rm -f "${CFG}"
}
trap cleanup_cfg EXIT

# shellcheck disable=SC2086
exec rclone mount ncworkspace: "${MOUNT_POINT}" \
  --config "${CFG}" \
  --vfs-cache-mode writes \
  ${RCLONE_EXTRA_ARGS}
