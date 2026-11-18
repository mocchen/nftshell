#!/usr/bin/env bash
# ==============================================================================
# nft-forward-remote.sh
# 远程启动器：下载 nft-forward.sh 到临时文件，检查后执行。
#
# 用法：
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward-remote.sh)"
#   sudo bash /tmp/nft-forward-remote.sh add --listen 8080 --dest 192.168.1.10 --dest-port 80
# ==============================================================================

set -Eeuo pipefail

readonly RAW_URL="https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward.sh"

TMP_FILE=""

cleanup() {
    if [[ -n "$TMP_FILE" && -e "$TMP_FILE" ]]; then
        rm -f -- "$TMP_FILE" || true
    fi
}
trap cleanup EXIT

die() {
    printf '[错误] %s\n' "$*" >&2
    exit 1
}

download_script() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 \
            "$RAW_URL" -o "$TMP_FILE"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$TMP_FILE" "$RAW_URL"
    else
        die "未找到 curl 或 wget，无法下载远程脚本"
    fi
}

main() {
    command -v bash >/dev/null 2>&1 || die "未找到 bash"
    command -v mktemp >/dev/null 2>&1 || die "未找到 mktemp"

    TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/nft-forward.XXXXXX") ||
        die "无法创建临时文件"

    printf '[*] 下载 nft-forward.sh ...\n' >&2
    if ! download_script; then
        die "下载失败：$RAW_URL"
    fi
    if [[ ! -s "$TMP_FILE" ]]; then
        die "下载的脚本为空"
    fi

    printf '[*] 检查脚本语法 ...\n' >&2
    if ! bash -n "$TMP_FILE"; then
        die "下载的脚本未通过 bash -n 检查"
    fi

    printf '[*] 启动 nft-forward.sh ...\n\n' >&2
    bash "$TMP_FILE" "$@"
}

main "$@"
