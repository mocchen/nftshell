#!/usr/bin/env bash
# ==============================================================================
# nft-forward.sh
# 基于 nftables 的 IPv4/IPv6 端口转发管理脚本
#
# 功能：
#   - 启动时自动检测 Linux / root / nft / 内核 nftables 接口 / IPv4/IPv6 转发 / systemd
#   - nftables 缺失时自动调用包管理器安装
#   - 单端口、多端口、端口范围、端口组合转发
#   - TCP / UDP / 两者
#   - 默认 DNAT + SNAT，可按规则关闭 SNAT
#   - 可限制入口网卡；菜单自动列出网卡及绑定 IP
#   - 规则持久化到 /etc/nft-forward/rules.conf
#   - 添加规则自动安装并启用 systemd 开机自启
#   - 交互式菜单（直接运行脚本或执行 menu）
#
# 支持 IPv4/IPv6。所有规则放在独立表 ip/ip6 nftfwd 中，不会改动其他 nftables 表。
# ==============================================================================

set -Eeuo pipefail
umask 022

readonly PROG_NAME="nft-forward"
readonly SCRIPT_VERSION="1.2.1"
readonly TABLE_NAME="nftfwd"
readonly TABLE_FAMILIES=("ip" "ip6")
readonly STATE_DIR="/etc/nft-forward"
readonly STATE_FILE="${STATE_DIR}/rules.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-nft-forward.conf"
readonly SERVICE_NAME="nft-forward.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly INSTALL_PATH="/usr/local/sbin/nft-forward"
readonly LOCK_FILE="/run/nft-forward.lock"
readonly MAX_PAIR_PORTS=4096
readonly SELF_RAW_URL="https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward.sh"
AUTO_INSTALL_NFT="${NFTF_AUTO_INSTALL:-1}"

CLEANUP_FILES=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_BLUE=$'\033[34m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_RESET=$'\033[0m'
else
    C_BLUE=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_RESET=""
fi

# ------------------------------------------------------------------------------
# 基础输出和清理
# ------------------------------------------------------------------------------

info() { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() {
    local f
    if ((${#CLEANUP_FILES[@]})); then
        for f in "${CLEANUP_FILES[@]}"; do
            if [[ -n "$f" && -e "$f" ]]; then
                rm -f -- "$f" || true
            fi
        done
    fi
}
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

require_root() {
    if ! is_root; then
        err "需要 root 权限才能修改 nftables 规则。"
        if have sudo; then
            info "请使用：sudo $0 $*"
        else
            info "请切换到 root 用户后重试。"
        fi
        exit 1
    fi
}

usage() {
    cat <<'EOF'
nft-forward.sh - 基于 nftables 的 IPv4/IPv6 端口转发管理脚本

用法：
  nft-forward.sh <命令> [选项]

命令：
  add         添加转发规则
  remove      按规则 ID 删除规则
  list        列出当前规则
  flush       清空所有规则
  apply       重新应用状态文件中的规则
  down        仅删除运行时 nftables 表（保留规则配置）
  check       检查运行环境、依赖和权限
  status      显示当前运行状态
  menu        打开交互式菜单（无参数时会自动尝试打开）
  install     安装为 systemd 服务（开机自动恢复）
  uninstall   卸载 systemd 服务
  version     显示版本

添加规则：
  # 单端口
  nft-forward.sh add --listen 8080 --dest 192.168.1.10 --dest-port 80

  # 简写：监听端口 目标地址 目标端口
  nft-forward.sh add 8080 192.168.1.10 80

  # 多端口：每个监听端口都转到同一个目标端口
  nft-forward.sh add --listen 80,443,8000-8010 --dest 192.168.1.10 --dest-port 80

  # 端口组合：一一对应（监听 3 个，目标也 3 个）
  nft-forward.sh add --listen 80,443,8000-8002 --dest 192.168.1.10 --dest-port 8080,8443,9000-9002

  # 多个不同目标，--rule 可重复
  nft-forward.sh add --rule 80:192.168.1.10:80 --rule 443:192.168.1.20:443

  # IPv6 目标：直接写地址；--rule 中 IPv6 地址需要方括号
  nft-forward.sh add --listen 8443 --dest 2001:db8::10 --dest-port 443
  nft-forward.sh add --rule '8443:[2001:db8::10]:443'

  # TCP + UDP
  nft-forward.sh add --listen 25565 --dest 192.168.1.10 --dest-port 25565 --proto both

  # 只接受来自 eth0 的流量；SNAT 默认开启
  nft-forward.sh add --listen 8080 --dest 192.168.1.10 --dest-port 80 \
      --iface eth0

  # 如目标回程会经过本机，可关闭 SNAT，保留客户端源 IP
  nft-forward.sh add --listen 8080 --dest 192.168.1.10 --dest-port 80 \
      --no-masquerade

  # 只预览生成的 nftables 规则，不修改系统
  nft-forward.sh add --listen 8080 --dest 192.168.1.10 --dest-port 80 --dry-run

add 选项：
  -l, --listen PORTS       监听端口：80 / 80,443 / 8000-8010 / 80,443,8000-8010
  -d, --dest ADDR          目标 IPv4 或 IPv6 地址
  -p, --dest-port PORTS    目标端口：单个端口，或与监听端口数量相同的组合
  -r, --rule L:ADDR:P      直接指定“监听端口:目标地址:目标端口”，可重复；IPv6 地址写作 [addr]
      --proto PROTO        tcp（默认）、udp、both
  -i, --iface NAME         仅转发从指定网卡进入的流量
      --masquerade         SNAT（默认开启）
      --no-masquerade      关闭 SNAT
  -n, --dry-run            只打印 nftables 规则，不写入系统

其他：
  remove <ID> [ID...]      删除一个或多个规则，ID 由 list 查看
  flush --yes              清空所有规则
  apply [--dry-run]        重新应用状态文件；--dry-run 只打印规则
  check                    退出码 0 表示环境检查通过
  install                  手动安装/修复 systemd 开机服务（add 会自动安装）
  uninstall [--purge] [--yes]
                           卸载服务；--purge 同时删除状态和 sysctl 配置

说明：
  - 新规则默认同时做 DNAT 和 SNAT。
  - 添加规则成功后会自动安装并启用 systemd 服务，实现开机自启。
  - 端口组合会按从小到大排序后一一对应。
  - 目标端口只有一个时，所有监听端口都转发到该端口。
  - 目标端口组合必须与监听端口数量一致。
  - 规则默认只转发 TCP；需要 UDP 时显式加 --proto udp 或 --proto both。
  - 脚本只创建/删除自己的表 ip/ip6 nftfwd，不会 flush 系统其他防火墙规则。
  - 支持 IPv4 和 IPv6；目标地址必须是 IP，不支持域名。
EOF
}

version() {
    printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"
}

# ------------------------------------------------------------------------------
# 系统信息
# ------------------------------------------------------------------------------

OS_NAME="Linux"
OS_ID=""
OS_LIKE=""

detect_os() {
    OS_NAME="Linux"
    OS_ID=""
    OS_LIKE=""
    if [[ -r /etc/os-release ]]; then
        local rel
        rel=$(
            # shellcheck source=/dev/null
            . /etc/os-release
            printf '%s\t%s\t%s' \
                "${PRETTY_NAME:-${NAME:-Linux}}" "${ID:-}" "${ID_LIKE:-}"
        )
        if [[ -n "$rel" ]]; then
            IFS=$'\t' read -r OS_NAME OS_ID OS_LIKE <<< "$rel"
        fi
    fi
}

print_install_hint() {
    local hint="请使用发行版的包管理器安装 nftables"
    case " ${OS_ID} ${OS_LIKE} " in
        *debian*|*ubuntu*) hint="apt-get update && apt-get install -y nftables" ;;
        *rhel*|*fedora*|*centos*|*rocky*|*alma*) hint="dnf install -y nftables" ;;
        *alpine*) hint="apk add nftables" ;;
        *arch*) hint="pacman -S --needed nftables" ;;
        *suse*) hint="zypper install -y nftables" ;;
    esac
    printf '  安装示例：%s\n' "$hint" >&2
}

systemd_available() {
    [[ -d /run/systemd/system ]] && have systemctl
}

version_lt() {
    local -a va=() vb=()
    local i av bv
    IFS='.' read -r -a va <<< "$1"
    IFS='.' read -r -a vb <<< "$2"
    for i in 0 1 2; do
        av="${va[i]:-0}"
        bv="${vb[i]:-0}"
        if ((10#$av < 10#$bv)); then return 0; fi
        if ((10#$av > 10#$bv)); then return 1; fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# 端口解析
# ------------------------------------------------------------------------------

P_START=()
P_END=()
PORT_COUNT=0

is_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    local n=$((10#$1))
    ((n >= 1 && n <= 65535))
}

parse_ports() {
    local spec="$1"
    local label="${2:-端口}"
    local token s e i j n
    local -a starts=() ends=()
    local -a ms=() me=()

    P_START=()
    P_END=()
    PORT_COUNT=0

    [[ -n "$spec" ]] || die "${label}不能为空"
    [[ "$spec" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] \
        || die "${label}格式错误：'${spec}'（示例：80,443,8000-8010）"

    local IFS=','
    for token in $spec; do
        if [[ "$token" == *-* ]]; then
            s="${token%%-*}"
            e="${token#*-}"
        else
            s="$token"
            e="$token"
        fi
        if ! is_port "$s" || ! is_port "$e"; then
            die "${label}包含非法端口：'${token}'（有效范围 1-65535）"
        fi
        s=$((10#$s))
        e=$((10#$e))
        if ((s > e)); then
            die "${label}范围起始端口大于结束端口：'${token}'"
        fi
        starts+=("$s")
        ends+=("$e")
    done

    # 按起始端口插入排序
    n=${#starts[@]}
    for ((i = 1; i < n; i++)); do
        s="${starts[i]}"
        e="${ends[i]}"
        j=$((i - 1))
        while ((j >= 0 && starts[j] > s)); do
            starts[j + 1]="${starts[j]}"
            ends[j + 1]="${ends[j]}"
            j=$((j - 1))
        done
        starts[j + 1]="$s"
        ends[j + 1]="$e"
    done

    # 合并重叠或相邻区间
    for ((i = 0; i < n; i++)); do
        s="${starts[i]}"
        e="${ends[i]}"
        if ((${#ms[@]} == 0)); then
            ms+=("$s")
            me+=("$e")
        else
            j=$((${#ms[@]} - 1))
            if ((s <= me[j] + 1)); then
                if ((e > me[j])); then
                    me[j]="$e"
                fi
            else
                ms+=("$s")
                me+=("$e")
            fi
        fi
    done

    P_START=("${ms[@]}")
    P_END=("${me[@]}")
    for ((i = 0; i < ${#P_START[@]}; i++)); do
        PORT_COUNT=$((PORT_COUNT + P_END[i] - P_START[i] + 1))
    done
}

ports_expr() {
    local n=${#P_START[@]}
    local i out=""
    if ((n == 0)); then
        return 0
    fi
    if ((n == 1)); then
        if ((P_START[0] == P_END[0])); then
            printf '%s' "${P_START[0]}"
        else
            printf '%s-%s' "${P_START[0]}" "${P_END[0]}"
        fi
        return 0
    fi
    out="{ "
    for ((i = 0; i < n; i++)); do
        if ((i > 0)); then out+=", "; fi
        if ((P_START[i] == P_END[i])); then
            out+="${P_START[i]}"
        else
            out+="${P_START[i]}-${P_END[i]}"
        fi
    done
    out+=" }"
    printf '%s' "$out"
}

# ------------------------------------------------------------------------------
# 地址、网卡、协议检查
# ------------------------------------------------------------------------------

is_ipv4() {
    local ip="$1"
    local o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    for o in $ip; do
        [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        ((10#$o <= 255)) || return 1
    done
    return 0
}

is_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^(([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,7}:|([0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,5}(:[0-9A-Fa-f]{1,4}){1,2}|([0-9A-Fa-f]{1,4}:){1,4}(:[0-9A-Fa-f]{1,4}){1,3}|([0-9A-Fa-f]{1,4}:){1,3}(:[0-9A-Fa-f]{1,4}){1,4}|([0-9A-Fa-f]{1,4}:){1,2}(:[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:((:[0-9A-Fa-f]{1,4}){1,6})|:((:[0-9A-Fa-f]{1,4}){1,7}|:))$ ]]
}

family_of_addr() {
    if [[ "$1" == *:* ]]; then
        printf 'ip6'
    else
        printf 'ip'
    fi
}

is_iface_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.:@-]{1,15}$ ]]
}

proto_overlap() {
    [[ "$1" == "both" || "$2" == "both" || "$1" == "$2" ]]
}

iface_overlap() {
    [[ -z "$1" || -z "$2" || "$1" == "$2" ]]
}

proto_match() {
    [[ "$1" == "both" || "$1" == "$2" ]]
}

specs_overlap() {
    local a="$1"
    local b="$2"
    local i j
    local -a as=() ae=() bs=() be=()

    parse_ports "$a" "监听端口"
    as=("${P_START[@]}")
    ae=("${P_END[@]}")
    parse_ports "$b" "监听端口"
    bs=("${P_START[@]}")
    be=("${P_END[@]}")

    for ((i = 0; i < ${#as[@]}; i++)); do
        for ((j = 0; j < ${#bs[@]}; j++)); do
            if ((as[i] <= be[j] && bs[j] <= ae[i])); then
                return 0
            fi
        done
    done
    return 1
}

validate_spec() {
    local listen="$1"
    local addr="$2"
    local dports="$3"
    local iface="$4"
    local family="$5"
    local lc dc

    parse_ports "$listen" "监听端口"
    lc=$PORT_COUNT
    parse_ports "$dports" "目标端口"
    dc=$PORT_COUNT

    if ((dc != 1 && dc != lc)); then
        die "目标端口 '$dports' 有 $dc 个端口，必须为 1 个，或与监听端口数量 ($lc) 相同"
    fi
    if ((dc > 1 && lc > MAX_PAIR_PORTS)); then
        die "一一映射最多支持 $MAX_PAIR_PORTS 个端口（当前 $lc），请拆分为多条规则"
    fi
    if [[ "$family" != "ip" && "$family" != "ip6" ]]; then
        die "地址族 '$family' 不合法"
    fi
    if [[ "$family" == "ip" ]]; then
        if ! is_ipv4 "$addr"; then
            die "目标地址 '$addr' 不是合法 IPv4 地址"
        fi
        if [[ "$addr" == "0.0.0.0" ]]; then
            die "目标地址不能是 0.0.0.0"
        fi
        if [[ "$addr" == 127.* ]]; then
            warn "目标地址 $addr 是回环地址；DNAT 到本机回环地址通常不可用，请确认路由配置"
        fi
        if [[ "$addr" =~ ^2(2[4-9]|3[0-9])\. ]]; then
            warn "目标地址 $addr 属于组播地址段，通常不能作为普通转发目标"
        fi
    else
        if ! is_ipv6 "$addr"; then
            die "目标地址 '$addr' 不是合法 IPv6 地址"
        fi
        if [[ "$addr" == "::" ]]; then
            die "目标地址不能是未指定地址 ::"
        fi
        if [[ "$addr" == "::1" ]]; then
            warn "目标地址 ::1 是 IPv6 回环地址，通常不能作为普通转发目标"
        fi
        if [[ "$addr" =~ ^[fF][fF] ]]; then
            warn "目标地址 $addr 属于 IPv6 组播地址段，通常不能作为普通转发目标"
        fi
    fi
    if [[ -n "$iface" ]] && ! is_iface_name "$iface"; then
        die "网卡名 '$iface' 不合法（只允许字母、数字、_ . : @ -，最长 15 字符）"
    fi
    if [[ -n "$iface" ]] && have ip; then
        if ! ip link show dev "$iface" >/dev/null 2>&1; then
            warn "网卡 '$iface' 当前不存在；如果它会在稍后创建，可以忽略此警告"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 状态文件
# ------------------------------------------------------------------------------

R_ID=()
R_FAMILY=()
R_PROTO=()
R_LISTEN=()
R_ADDR=()
R_DPORTS=()
R_IFACE=()
R_MASQ=()

state_reset() {
    R_ID=()
    R_FAMILY=()
    R_PROTO=()
    R_LISTEN=()
    R_ADDR=()
    R_DPORTS=()
    R_IFACE=()
    R_MASQ=()
}

ensure_state_dir() {
    if [[ ! -d "$STATE_DIR" ]]; then
        mkdir -p "$STATE_DIR" || die "无法创建状态目录 $STATE_DIR"
        chmod 0755 "$STATE_DIR" 2>/dev/null || true
    fi
}

state_load() {
    local file="$1"
    local id proto listen addr dports iface masq family seen=" "
    local n=0 lc dc

    state_reset
    [[ -e "$file" ]] || return 0
    [[ -r "$file" ]] || die "无法读取状态文件：$file"

    while IFS='|' read -r id proto listen addr dports iface masq family || [[ -n "${id:-}" ]]; do
        n=$((n + 1))
        masq="${masq%$'\r'}"
        family="${family%$'\r'}"
        if [[ -z "$id" || "$id" == \#* ]]; then
            continue
        fi
        if [[ ! "$id" =~ ^[1-9][0-9]*$ ]]; then
            die "状态文件第 $n 行：规则 ID 非法"
        fi
        if [[ "$seen" == *" $id "* ]]; then
            die "状态文件第 $n 行：规则 ID 重复"
        fi
        seen+="$id "
        # v1 状态没有 family 字段，默认按 IPv4 处理。
        if [[ -z "$family" ]]; then
            family="ip"
        fi
        case "$family" in
            ip|ip6) ;;
            *) die "状态文件第 $n 行：地址族 '$family' 非法" ;;
        esac
        case "$proto" in
            tcp|udp|both) ;;
            *) die "状态文件第 $n 行：协议 '$proto' 非法" ;;
        esac
        if [[ -n "$iface" ]] && ! is_iface_name "$iface"; then
            die "状态文件第 $n 行：网卡名 '$iface' 非法"
        fi
        if [[ "$family" == "ip" ]]; then
            if ! is_ipv4 "$addr"; then
                die "状态文件第 $n 行：目标 IPv4 地址 '$addr' 非法"
            fi
            if [[ "$addr" == "0.0.0.0" ]]; then
                die "状态文件第 $n 行：目标地址不能是 0.0.0.0"
            fi
        else
            if ! is_ipv6 "$addr"; then
                die "状态文件第 $n 行：目标 IPv6 地址 '$addr' 非法"
            fi
            if [[ "$addr" == "::" ]]; then
                die "状态文件第 $n 行：目标地址不能是 ::"
            fi
        fi
        if [[ "$masq" != "0" && "$masq" != "1" ]]; then
            die "状态文件第 $n 行：masquerade 标记非法"
        fi

        parse_ports "$listen" "监听端口"
        lc=$PORT_COUNT
        parse_ports "$dports" "目标端口"
        dc=$PORT_COUNT
        if ((dc != 1 && dc != lc)); then
            die "状态文件第 $n 行：目标端口数量与监听端口数量不匹配"
        fi

        R_ID+=("$id")
        R_FAMILY+=("$family")
        R_PROTO+=("$proto")
        R_LISTEN+=("$listen")
        R_ADDR+=("$addr")
        R_DPORTS+=("$dports")
        R_IFACE+=("$iface")
        R_MASQ+=("$masq")
    done < "$file"
}

state_write() {
    local file="$1"
    local i
    {
        printf '# nft-forward state v2\n'
        for ((i = 0; i < ${#R_ID[@]}; i++)); do
            printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "${R_ID[i]}" "${R_PROTO[i]}" "${R_LISTEN[i]}" \
                "${R_ADDR[i]}" "${R_DPORTS[i]}" "${R_IFACE[i]}" "${R_MASQ[i]}" "${R_FAMILY[i]}"
        done
    } > "$file"
    chmod 0644 "$file" 2>/dev/null || true
}

state_append() {
    R_ID+=("$1")
    R_PROTO+=("$2")
    R_LISTEN+=("$3")
    R_ADDR+=("$4")
    R_DPORTS+=("$5")
    R_IFACE+=("$6")
    R_MASQ+=("$7")
    R_FAMILY+=("$8")
}

state_has_ipv6() {
    local i
    for ((i = 0; i < ${#R_ID[@]}; i++)); do
        if [[ "${R_FAMILY[i]}" == "ip6" ]]; then
            return 0
        fi
    done
    return 1
}

next_id() {
    local max=0 id
    if ((${#R_ID[@]})); then
        for id in "${R_ID[@]}"; do
            if ((id > max)); then
                max=$id
            fi
        done
    fi
    printf '%s' "$((max + 1))"
}

check_conflict() {
    local family="$1"
    local proto="$2"
    local listen="$3"
    local iface="$4"
    local i

    if ((${#R_ID[@]} == 0)); then
        return 0
    fi
    for ((i = 0; i < ${#R_ID[@]}; i++)); do
        if [[ "$family" == "${R_FAMILY[i]}" ]] &&
            proto_overlap "$proto" "${R_PROTO[i]}" &&
            iface_overlap "$iface" "${R_IFACE[i]}" &&
            specs_overlap "$listen" "${R_LISTEN[i]}"; then
            die "监听端口冲突：$family '$listen' 与规则 #${R_ID[i]}（${R_FAMILY[i]} ${R_PROTO[i]} ${R_LISTEN[i]} -> ${R_ADDR[i]}:${R_DPORTS[i]}）重叠"
        fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# 规则渲染
# ------------------------------------------------------------------------------

render_dnat_target() {
    local family="$1"
    local addr="$2"
    local port="$3"
    if [[ "$family" == "ip6" ]]; then
        printf '[%s]:%s' "$addr" "$port"
    else
        printf '%s:%s' "$addr" "$port"
    fi
}

render_one_rule() {
    local idx="$1"
    local family="${R_FAMILY[idx]}"
    local proto="${R_PROTO[idx]}"
    local addr="${R_ADDR[idx]}"
    local iface="${R_IFACE[idx]}"
    local lexpr dcount prefix target
    local -a ls=() le=() ds=() de=() lports=() dports=()
    local r v p i n

    parse_ports "${R_LISTEN[idx]}" "监听端口"
    ls=("${P_START[@]}")
    le=("${P_END[@]}")
    lexpr=$(ports_expr)

    parse_ports "${R_DPORTS[idx]}" "目标端口"
    ds=("${P_START[@]}")
    de=("${P_END[@]}")
    dcount=$PORT_COUNT

    prefix=""
    if [[ -n "$iface" ]]; then
        prefix="iifname \"${iface}\" "
    fi

    if ((dcount == 1)); then
        target=$(render_dnat_target "$family" "$addr" "${ds[0]}")
        for p in tcp udp; do
            if proto_match "$proto" "$p"; then
                printf '        %s%s dport %s dnat to %s\n' \
                    "$prefix" "$p" "$lexpr" "$target"
            fi
        done
        return 0
    fi

    for ((r = 0; r < ${#ls[@]}; r++)); do
        for ((v = ls[r]; v <= le[r]; v++)); do
            lports+=("$v")
        done
    done
    for ((r = 0; r < ${#ds[@]}; r++)); do
        for ((v = ds[r]; v <= de[r]; v++)); do
            dports+=("$v")
        done
    done

    n=${#lports[@]}
    if ((${#dports[@]} != n)); then
        die "内部错误：目标端口数量与监听端口数量不一致"
    fi
    for ((i = 0; i < n; i++)); do
        target=$(render_dnat_target "$family" "$addr" "${dports[i]}")
        for p in tcp udp; do
            if proto_match "$proto" "$p"; then
                printf '        %s%s dport %s dnat to %s\n' \
                    "$prefix" "$p" "${lports[i]}" "$target"
            fi
        done
    done
}

render_masq_rule() {
    local idx="$1"
    local family="${R_FAMILY[idx]}"
    local proto="${R_PROTO[idx]}"
    local addr="${R_ADDR[idx]}"
    local dexpr p
    local l3="ip"

    if [[ "$family" == "ip6" ]]; then
        l3="ip6"
    fi

    parse_ports "${R_DPORTS[idx]}" "目标端口"
    dexpr=$(ports_expr)
    for p in tcp udp; do
        if proto_match "$proto" "$p"; then
            printf '        %s daddr %s %s dport %s ct status dnat masquerade\n' \
                "$l3" "$addr" "$p" "$dexpr"
        fi
    done
}

render_table() {
    local family="$1"
    local i count=0

    for ((i = 0; i < ${#R_ID[@]}; i++)); do
        if [[ "${R_FAMILY[i]}" == "$family" ]]; then
            count=$((count + 1))
        fi
    done
    if ((count == 0)); then
        return 0
    fi

    printf 'table %s %s {\n' "$family" "$TABLE_NAME"
    printf '    chain owner {\n'
    printf '    }\n'
    printf '    chain prerouting {\n'
    printf '        type nat hook prerouting priority -100; policy accept;\n'
    for ((i = 0; i < ${#R_ID[@]}; i++)); do
        if [[ "${R_FAMILY[i]}" == "$family" ]]; then
            render_one_rule "$i"
        fi
    done
    printf '    }\n'
    # 即使没有 SNAT 规则也保留 postrouting 链：
    # 4.18 之前的内核需要注册双向 NAT 链，DNAT 的回程流量才能正确解 NAT。
    printf '    chain postrouting {\n'
    printf '        type nat hook postrouting priority 100; policy accept;\n'
    for ((i = 0; i < ${#R_ID[@]}; i++)); do
        if [[ "${R_FAMILY[i]}" == "$family" ]] && ((R_MASQ[i] == 1)); then
            render_masq_rule "$i"
        fi
    done
    printf '    }\n'
    printf '}\n'
}

render_ruleset() {
    local statefile="$1"
    local outfile="$2"
    local family

    state_load "$statefile"
    : > "$outfile"
    for family in "${TABLE_FAMILIES[@]}"; do
        render_table "$family" >> "$outfile"
    done
}

preview_state_file() {
    local statefile="$1"
    local nftfile
    nftfile=$(mktemp "${TMPDIR:-/tmp}/nft-forward-preview.XXXXXX") || die "无法创建临时文件"
    CLEANUP_FILES+=("$nftfile")
    render_ruleset "$statefile" "$nftfile"
    if [[ -s "$nftfile" ]]; then
        cat "$nftfile"
    else
        printf '# 空规则集：应用后会删除表 ip/ip6 %s\n' "$TABLE_NAME"
    fi
}

# ------------------------------------------------------------------------------
# nftables 应用
# ------------------------------------------------------------------------------

NFT_CHECK_SUPPORTED=""

nft_supports_check() {
    local help
    if [[ -z "$NFT_CHECK_SUPPORTED" ]]; then
        help=$(nft --help 2>&1 || true)
        if [[ "$help" == *"--check"* ]]; then
            NFT_CHECK_SUPPORTED=1
        else
            NFT_CHECK_SUPPORTED=0
        fi
    fi
    [[ "$NFT_CHECK_SUPPORTED" == "1" ]]
}

table_is_ours() {
    local family="${1:-ip}"
    nft list chain "$family" "$TABLE_NAME" owner >/dev/null 2>&1
}

auto_install_nft() {
    if [[ "$AUTO_INSTALL_NFT" == "0" ]]; then
        err "nft 缺失，且当前环境禁用了自动安装（NFTF_AUTO_INSTALL=0）"
        return 1
    fi
    if ! is_root; then
        err "自动安装 nftables 需要 root 权限"
        return 1
    fi

    warn "未检测到 nftables，正在尝试自动安装..."
    if have apt-get; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y nftables; then
            apt-get update || return 1
            DEBIAN_FRONTEND=noninteractive apt-get install -y nftables || return 1
        fi
    elif have dnf; then
        dnf install -y nftables || return 1
    elif have yum; then
        yum install -y nftables || return 1
    elif have apk; then
        apk add --no-cache nftables || return 1
    elif have pacman; then
        pacman -S --needed --noconfirm nftables || return 1
    elif have zypper; then
        zypper --non-interactive install nftables || return 1
    else
        err "未找到支持的包管理器，无法自动安装 nftables"
        print_install_hint
        return 1
    fi

    hash -r
    if have nft; then
        ok "nftables 自动安装完成"
        return 0
    fi
    err "nftables 自动安装失败"
    return 1
}

auto_install_iproute() {
    if have ip; then
        return 0
    fi
    if ! is_root; then
        return 1
    fi

    warn "未检测到 ip 命令，正在尝试安装 iproute2..."
    if have apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 || return 1
    elif have dnf; then
        dnf install -y iproute || return 1
    elif have yum; then
        yum install -y iproute || return 1
    elif have apk; then
        apk add --no-cache iproute2 || return 1
    elif have pacman; then
        pacman -S --needed --noconfirm iproute2 || return 1
    elif have zypper; then
        zypper --non-interactive install iproute2 || return 1
    else
        return 1
    fi
    hash -r
    have ip
}

require_nft() {
    if ! have nft; then
        if ! auto_install_nft; then
            err "环境缺少 nftables，且自动安装未成功。"
            print_install_hint
            exit 1
        fi
    fi

    if ! nft list tables >/dev/null 2>&1; then
        if have modprobe; then
            modprobe nf_tables 2>/dev/null || true
            modprobe nf_nat 2>/dev/null || true
            modprobe nft_chain_nat 2>/dev/null || true
        fi
        if ! nft list tables >/dev/null 2>&1; then
            err "nft 无法访问内核 nftables 接口。"
            err "可能原因：内核不支持 nftables、模块未加载，或容器缺少 CAP_NET_ADMIN。"
            exit 1
        fi
    fi
}

write_sysctl_forwarding() {
    local ipv6="${1:-0}"
    mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null || true
    {
        printf '# Managed by nft-forward\n'
        printf 'net.ipv4.ip_forward = 1\n'
        if ((ipv6 == 1)); then
            printf 'net.ipv6.conf.all.forwarding = 1\n'
        fi
    } > "$SYSCTL_FILE" || warn "无法写入 $SYSCTL_FILE，重启后可能需要重新启用转发"
}

ensure_ip_forward() {
    local current
    local proc_file="/proc/sys/net/ipv4/ip_forward"
    local keep_ipv6=0

    [[ -r "$proc_file" ]] || die "内核未提供 IPv4 转发开关 $proc_file"
    current=$(< "$proc_file")
    if [[ "$current" != "1" ]]; then
        if have sysctl; then
            if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
                printf '1\n' > "$proc_file" || die "无法启用 IPv4 转发"
            fi
        else
            printf '1\n' > "$proc_file" || die "无法启用 IPv4 转发"
        fi
        warn "已临时启用 IPv4 转发（net.ipv4.ip_forward=1）"
    fi

    if [[ -f "$SYSCTL_FILE" ]] &&
        grep -q '^[[:space:]]*net\.ipv6\.conf\.all\.forwarding[[:space:]]*=[[:space:]]*1' "$SYSCTL_FILE" 2>/dev/null; then
        keep_ipv6=1
    fi
    write_sysctl_forwarding "$keep_ipv6"
}

ensure_ipv6_forward() {
    local current
    local proc_file="/proc/sys/net/ipv6/conf/all/forwarding"

    if [[ ! -r "$proc_file" ]]; then
        die "内核未提供 IPv6 转发开关 $proc_file（系统可能未启用 IPv6）"
    fi
    current=$(< "$proc_file")
    if [[ "$current" != "1" ]]; then
        if have sysctl; then
            if ! sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1; then
                printf '1\n' > "$proc_file" || die "无法启用 IPv6 转发"
            fi
        else
            printf '1\n' > "$proc_file" || die "无法启用 IPv6 转发"
        fi
        warn "已临时启用 IPv6 转发（net.ipv6.conf.all.forwarding=1）"
    fi
    write_sysctl_forwarding 1
}

apply_nft_file() {
    local statefile="$1"
    local quiet="${2:-0}"
    local nftfile backup_ip backup_ip6
    local had_ip=0 had_ip6=0
    local tmpdir="${TMPDIR:-/tmp}"

    nftfile=$(mktemp "${tmpdir}/nft-forward-rules.XXXXXX") || { err "无法创建临时文件"; return 1; }
    CLEANUP_FILES+=("$nftfile")
    backup_ip=$(mktemp "${tmpdir}/nft-forward-backup-ip.XXXXXX") || { err "无法创建临时文件"; return 1; }
    CLEANUP_FILES+=("$backup_ip")
    backup_ip6=$(mktemp "${tmpdir}/nft-forward-backup-ip6.XXXXXX") || { err "无法创建临时文件"; return 1; }
    CLEANUP_FILES+=("$backup_ip6")

    render_ruleset "$statefile" "$nftfile"

    if [[ -s "$nftfile" ]] && nft_supports_check; then
        if ! nft -c -f "$nftfile" 2>&1; then
            err "生成的 nftables 规则未通过校验，未修改系统。"
            return 1
        fi
    elif [[ -s "$nftfile" ]]; then
        warn "当前 nft 不支持 -c 校验，将直接应用规则。"
    fi

    if nft list table ip "$TABLE_NAME" > "$backup_ip" 2>/dev/null; then
        had_ip=1
    fi
    if nft list table ip6 "$TABLE_NAME" > "$backup_ip6" 2>/dev/null; then
        had_ip6=1
    fi

    if ((had_ip)) && ! table_is_ours ip; then
        err "表 ip ${TABLE_NAME} 已存在，但不是本脚本创建（缺少 owner 链）。"
        err "为避免破坏其他防火墙配置，拒绝覆盖；请先手动处理同名表。"
        return 1
    fi
    if ((had_ip6)) && ! table_is_ours ip6; then
        err "表 ip6 ${TABLE_NAME} 已存在，但不是本脚本创建（缺少 owner 链）。"
        err "为避免破坏其他防火墙配置，拒绝覆盖；请先手动处理同名表。"
        return 1
    fi

    if ((had_ip)); then
        if ! nft delete table ip "$TABLE_NAME"; then
            err "无法删除现有表 ip ${TABLE_NAME}。"
            return 1
        fi
    fi
    if ((had_ip6)); then
        if ! nft delete table ip6 "$TABLE_NAME"; then
            err "无法删除现有表 ip6 ${TABLE_NAME}。"
            if ((had_ip)); then
                nft -f "$backup_ip" >/dev/null 2>&1 || err "恢复 ip 表失败"
            fi
            return 1
        fi
    fi

    if [[ -s "$nftfile" ]]; then
        if ! nft -f "$nftfile"; then
            err "应用 nftables 规则失败，正在回滚。"
            nft delete table ip "$TABLE_NAME" 2>/dev/null || true
            nft delete table ip6 "$TABLE_NAME" 2>/dev/null || true
            if ((had_ip)); then
                if ! nft -f "$backup_ip"; then
                    err "回滚旧 ip 表失败，请立即执行 nft list ruleset 检查。"
                fi
            fi
            if ((had_ip6)); then
                if ! nft -f "$backup_ip6"; then
                    err "回滚旧 ip6 表失败，请立即执行 nft list ruleset 检查。"
                fi
            fi
            return 1
        fi
    fi

    if ((quiet == 0)); then
        state_load "$statefile"
        ok "已应用 ${#R_ID[@]} 条规则到表 ip/ip6 ${TABLE_NAME}"
    fi
    return 0
}

publish_state() {
    local newfile="$1"
    local oldstate=""
    local have_old=0

    ensure_state_dir
    if [[ -f "$STATE_FILE" ]]; then
        oldstate=$(mktemp "${STATE_DIR}/.old.XXXXXX") || { err "无法创建状态备份"; return 1; }
        CLEANUP_FILES+=("$oldstate")
        cp -p "$STATE_FILE" "$oldstate" || { err "无法备份状态文件"; return 1; }
        have_old=1
    fi

    if ! mv -f "$newfile" "$STATE_FILE"; then
        err "无法写入状态文件 $STATE_FILE"
        return 1
    fi
    chmod 0644 "$STATE_FILE" 2>/dev/null || true

    if ! apply_nft_file "$STATE_FILE" 0; then
        if ((have_old)); then
            mv -f "$oldstate" "$STATE_FILE" || err "恢复旧状态文件失败"
        else
            rm -f "$STATE_FILE" || true
        fi
        err "规则应用失败，已恢复原状态。"
        return 1
    fi
    return 0
}

acquire_lock() {
    if ! have flock; then
        warn "未找到 flock，跳过并发锁（同时执行多个实例可能产生竞争）。"
        return 0
    fi
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    if ! exec 9> "$LOCK_FILE"; then
        die "无法创建锁文件 $LOCK_FILE"
    fi
    if ! flock -w 10 9; then
        die "另一个 nft-forward 实例正在运行，请稍后重试。"
    fi
}

release_lock() {
    exec 9>&- 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# add
# ------------------------------------------------------------------------------

SPEC_L=()
SPEC_A=()
SPEC_D=()
SPEC_F=()
OPT_PROTO="tcp"
OPT_IFACE=""
OPT_MASQ=1
OPT_DRY_RUN=0

parse_rule_spec() {
    local rule="$1"
    local l a d family

    if [[ ! "$rule" =~ ^([^:]+):(\[[^]]+\]|[^:]+):([^:]+)$ ]]; then
        die "--rule 格式错误：'$rule'，应为 监听端口:目标地址:目标端口；IPv6 地址请写成 [2001:db8::1]"
    fi
    l="${BASH_REMATCH[1]}"
    a="${BASH_REMATCH[2]}"
    d="${BASH_REMATCH[3]}"
    if [[ "$a" == \[*\] ]]; then
        a="${a#\[}"
        a="${a%\]}"
    fi
    family=$(family_of_addr "$a")
    SPEC_L+=("$l")
    SPEC_A+=("$a")
    SPEC_D+=("$d")
    SPEC_F+=("$family")
}

parse_add_args() {
    local listen="" dest="" dport=""
    local have_l=0 have_d=0 have_p=0
    local -a positional=() rules=()
    local pos_n rule

    SPEC_L=()
    SPEC_A=()
    SPEC_D=()
    SPEC_F=()
    OPT_PROTO="tcp"
    OPT_IFACE=""
    OPT_MASQ=1
    OPT_DRY_RUN=0

    while (($#)); do
        case "$1" in
            -l|--listen)
                (($# >= 2)) || die "$1 缺少参数"
                if ((have_l)); then die "--listen 只能指定一次"; fi
                listen="$2"
                have_l=1
                shift 2
                ;;
            -d|--dest)
                (($# >= 2)) || die "$1 缺少参数"
                if ((have_d)); then die "--dest 只能指定一次"; fi
                dest="$2"
                have_d=1
                shift 2
                ;;
            -p|--dest-port)
                (($# >= 2)) || die "$1 缺少参数"
                if ((have_p)); then die "--dest-port 只能指定一次"; fi
                dport="$2"
                have_p=1
                shift 2
                ;;
            -r|--rule|--map)
                (($# >= 2)) || die "$1 缺少参数"
                rules+=("$2")
                shift 2
                ;;
            --proto)
                (($# >= 2)) || die "--proto 缺少参数"
                case "$2" in
                    tcp|udp|both) OPT_PROTO="$2" ;;
                    *) die "--proto 只能是 tcp、udp 或 both" ;;
                esac
                shift 2
                ;;
            -i|--iface)
                (($# >= 2)) || die "$1 缺少参数"
                OPT_IFACE="$2"
                shift 2
                ;;
            --masquerade)
                OPT_MASQ=1
                shift
                ;;
            --no-masquerade)
                OPT_MASQ=0
                shift
                ;;
            -n|--dry-run)
                OPT_DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while (($#)); do
                    positional+=("$1")
                    shift
                done
                ;;
            -*)
                die "未知选项：$1（使用 --help 查看帮助）"
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ -n "$OPT_IFACE" ]] && ! is_iface_name "$OPT_IFACE"; then
        die "网卡名 '$OPT_IFACE' 不合法（只允许字母、数字、_ . : @ -，最长 15 字符）"
    fi

    pos_n=${#positional[@]}
    if ((${#rules[@]} > 0)); then
        if ((have_l || have_d || have_p || pos_n > 0)); then
            die "--rule 不能与 --listen/--dest/--dest-port 或位置参数混用"
        fi
        for rule in "${rules[@]}"; do
            parse_rule_spec "$rule"
        done
    else
        if ((pos_n > 0)); then
            if ((pos_n != 3)); then
                die "位置参数需要 3 个：监听端口 目标地址 目标端口"
            fi
            if ((have_l || have_d || have_p)); then
                die "位置参数不能与 --listen/--dest/--dest-port 混用"
            fi
            listen="${positional[0]}"
            dest="${positional[1]}"
            dport="${positional[2]}"
            have_l=1
            have_d=1
            have_p=1
        fi
        if ((!have_l || !have_d || !have_p)); then
            die "缺少参数：需要 --listen、--dest、--dest-port（或使用 3 个位置参数）"
        fi
        SPEC_L+=("$listen")
        SPEC_A+=("$dest")
        SPEC_D+=("$dport")
        SPEC_F+=("$(family_of_addr "$dest")")
    fi

    if ((${#SPEC_L[@]} == 0)); then
        die "没有可添加的规则"
    fi
}

build_add_state() {
    local outfile="$1"
    local i id

    state_load "$STATE_FILE"
    for ((i = 0; i < ${#SPEC_L[@]}; i++)); do
        validate_spec "${SPEC_L[i]}" "${SPEC_A[i]}" "${SPEC_D[i]}" "$OPT_IFACE" "${SPEC_F[i]}"
        check_conflict "${SPEC_F[i]}" "$OPT_PROTO" "${SPEC_L[i]}" "$OPT_IFACE"
        id=$(next_id)
        state_append "$id" "$OPT_PROTO" "${SPEC_L[i]}" "${SPEC_A[i]}" "${SPEC_D[i]}" "$OPT_IFACE" "$OPT_MASQ" "${SPEC_F[i]}"
    done
    state_write "$outfile"
}

ensure_boot_service() {
    if ! systemd_available; then
        warn "systemd 不可用，无法设置开机自启"
        return 1
    fi

    install_self || return 1
    write_service_file || return 1

    if ! systemctl daemon-reload; then
        warn "systemctl daemon-reload 失败"
        return 1
    fi
    if ! systemctl enable "$SERVICE_NAME" >/dev/null; then
        warn "启用 $SERVICE_NAME 失败"
        return 1
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        if ! systemctl reload "$SERVICE_NAME"; then
            warn "重载 $SERVICE_NAME 失败"
            return 1
        fi
    else
        if ! systemctl start "$SERVICE_NAME"; then
            warn "启动 $SERVICE_NAME 失败"
            return 1
        fi
    fi
    ok "开机自启服务已启用：$SERVICE_NAME"
    return 0
}

cmd_add() {
    local tmp

    parse_add_args "$@"

    if ((OPT_DRY_RUN)); then
        tmp=$(mktemp "${TMPDIR:-/tmp}/nft-forward-state.XXXXXX") || die "无法创建临时文件"
        CLEANUP_FILES+=("$tmp")
        build_add_state "$tmp"
        preview_state_file "$tmp"
        info "dry-run：未修改系统。" >&2
        return 0
    fi

    require_root "$@"
    require_nft
    ensure_state_dir
    acquire_lock

    tmp=$(mktemp "${STATE_DIR}/.rules.XXXXXX") || die "无法创建临时状态文件"
    CLEANUP_FILES+=("$tmp")
    build_add_state "$tmp"
    ensure_ip_forward
    if state_has_ipv6; then
        ensure_ipv6_forward
    fi
    if ! publish_state "$tmp"; then
        return 1
    fi

    state_load "$STATE_FILE"
    ok "添加完成，当前共 ${#R_ID[@]} 条规则。"

    # 释放锁后再启动/重载 systemd 服务，避免服务里的 apply 等待同一把锁。
    release_lock
    if ! ( ensure_boot_service ); then
        warn "规则已生效，但开机自启配置失败；可执行 sudo $0 install 重试"
    fi
}

# ------------------------------------------------------------------------------
# remove / flush
# ------------------------------------------------------------------------------

build_remove_state() {
    local outfile="$1"
    shift
    local -a ids=("$@")
    local i j id skip found
    local -a nid=() nfamily=() nproto=() nlisten=() naddr=() ndports=() niface=() nmasq=()

    if ((${#ids[@]} == 0)); then
        die "请指定要删除的规则 ID"
    fi

    state_load "$STATE_FILE"
    for id in "${ids[@]}"; do
        if [[ ! "$id" =~ ^[1-9][0-9]*$ ]]; then
            die "规则 ID 非法：'$id'"
        fi
        found=0
        for ((j = 0; j < ${#R_ID[@]}; j++)); do
            if [[ "${R_ID[j]}" == "$id" ]]; then
                found=1
                break
            fi
        done
        if ((found == 0)); then
            die "规则 #$id 不存在"
        fi
    done

    for ((i = 0; i < ${#R_ID[@]}; i++)); do
        skip=0
        for id in "${ids[@]}"; do
            if [[ "${R_ID[i]}" == "$id" ]]; then
                skip=1
                break
            fi
        done
        if ((skip == 0)); then
            nid+=("${R_ID[i]}")
            nfamily+=("${R_FAMILY[i]}")
            nproto+=("${R_PROTO[i]}")
            nlisten+=("${R_LISTEN[i]}")
            naddr+=("${R_ADDR[i]}")
            ndports+=("${R_DPORTS[i]}")
            niface+=("${R_IFACE[i]}")
            nmasq+=("${R_MASQ[i]}")
        fi
    done

    if ((${#nid[@]})); then
        R_ID=("${nid[@]}")
        R_FAMILY=("${nfamily[@]}")
        R_PROTO=("${nproto[@]}")
        R_LISTEN=("${nlisten[@]}")
        R_ADDR=("${naddr[@]}")
        R_DPORTS=("${ndports[@]}")
        R_IFACE=("${niface[@]}")
        R_MASQ=("${nmasq[@]}")
    else
        state_reset
    fi
    state_write "$outfile"
}

cmd_remove() {
    local dry=0
    local -a ids=()
    local tmp

    while (($#)); do
        case "$1" in
            -n|--dry-run) dry=1; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; while (($#)); do ids+=("$1"); shift; done ;;
            -*) die "未知选项：$1" ;;
            *) ids+=("$1"); shift ;;
        esac
    done

    if ((${#ids[@]} == 0)); then
        die "用法：$0 remove <ID> [ID...]"
    fi

    if ((dry)); then
        tmp=$(mktemp "${TMPDIR:-/tmp}/nft-forward-state.XXXXXX") || die "无法创建临时文件"
        CLEANUP_FILES+=("$tmp")
        build_remove_state "$tmp" "${ids[@]}"
        preview_state_file "$tmp"
        info "dry-run：未修改系统。" >&2
        return 0
    fi

    require_root "$@"
    require_nft
    ensure_state_dir
    acquire_lock

    tmp=$(mktemp "${STATE_DIR}/.rules.XXXXXX") || die "无法创建临时状态文件"
    CLEANUP_FILES+=("$tmp")
    build_remove_state "$tmp" "${ids[@]}"
    if ! publish_state "$tmp"; then
        return 1
    fi
    state_load "$STATE_FILE"
    ok "删除完成，当前剩余 ${#R_ID[@]} 条规则。"
}

cmd_flush() {
    local dry=0
    local assume_yes=0
    local tmp

    while (($#)); do
        case "$1" in
            -n|--dry-run) dry=1; shift ;;
            -y|--yes) assume_yes=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知选项：$1" ;;
        esac
    done

    if ((dry)); then
        tmp=$(mktemp "${TMPDIR:-/tmp}/nft-forward-state.XXXXXX") || die "无法创建临时文件"
        CLEANUP_FILES+=("$tmp")
        state_reset
        state_write "$tmp"
        preview_state_file "$tmp"
        info "dry-run：未修改系统。" >&2
        return 0
    fi

    require_root "$@"
    if ((assume_yes == 0)); then
        if [[ ! -t 0 ]]; then
            die "非交互模式请加 --yes 确认清空"
        fi
        local answer=""
        read -r -p "确认清空所有转发规则？[y/N] " answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) die "已取消" ;;
        esac
    fi

    require_nft
    ensure_state_dir
    acquire_lock

    tmp=$(mktemp "${STATE_DIR}/.rules.XXXXXX") || die "无法创建临时状态文件"
    CLEANUP_FILES+=("$tmp")
    state_reset
    state_write "$tmp"
    if ! publish_state "$tmp"; then
        return 1
    fi
    ok "已清空所有转发规则。"
}

# ------------------------------------------------------------------------------
# apply / down
# ------------------------------------------------------------------------------

cmd_apply() {
    local dry=0 quiet=0

    while (($#)); do
        case "$1" in
            -n|--dry-run) dry=1; shift ;;
            -q|--quiet) quiet=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知选项：$1" ;;
        esac
    done

    if ((dry)); then
        preview_state_file "$STATE_FILE"
        return 0
    fi

    require_root "$@"
    require_nft
    acquire_lock
    state_load "$STATE_FILE"
    if ((${#R_ID[@]} > 0)); then
        ensure_ip_forward
        if state_has_ipv6; then
            ensure_ipv6_forward
        fi
    fi
    apply_nft_file "$STATE_FILE" "$quiet"
}

cmd_down() {
    local quiet=0 family
    local -a existing=()

    while (($#)); do
        case "$1" in
            -q|--quiet) quiet=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知选项：$1" ;;
        esac
    done

    require_root "$@"
    require_nft
    acquire_lock

    for family in "${TABLE_FAMILIES[@]}"; do
        if nft list table "$family" "$TABLE_NAME" >/dev/null 2>&1; then
            if ! table_is_ours "$family"; then
                die "表 $family ${TABLE_NAME} 不是本脚本创建，拒绝删除。"
            fi
            existing+=("$family")
        fi
    done

    if ((${#existing[@]})); then
        for family in "${existing[@]}"; do
            nft delete table "$family" "$TABLE_NAME" || die "删除 $family ${TABLE_NAME} 失败"
        done
        ((quiet == 1)) || ok "已删除运行时表 ip/ip6 ${TABLE_NAME}（规则配置仍保留）。"
    else
        ((quiet == 1)) || info "运行时表不存在，无需删除。"
    fi
}

# ------------------------------------------------------------------------------
# list / status / check
# ------------------------------------------------------------------------------

cmd_list() {
    local i proto target iface masq family

    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) die "未知选项：$1" ;;
    esac

    state_load "$STATE_FILE"
    if ((${#R_ID[@]} == 0)); then
        info "暂无转发规则。"
        return 0
    fi

    printf '%-4s %-6s %-7s %-24s %-26s %-9s %s\n' "ID" "FAMILY" "PROTO" "LISTEN" "TARGET" "IFACE" "MASQ"
    for ((i = 0; i < ${#R_ID[@]}; i++)); do
        family="${R_FAMILY[i]}"
        proto="${R_PROTO[i]}"
        if [[ "$proto" == "both" ]]; then proto="tcp+udp"; fi
        if [[ "$family" == "ip6" ]]; then
            target="[${R_ADDR[i]}]:${R_DPORTS[i]}"
        else
            target="${R_ADDR[i]}:${R_DPORTS[i]}"
        fi
        iface="${R_IFACE[i]:-any}"
        if ((R_MASQ[i] == 1)); then masq="yes"; else masq="no"; fi
        printf '%-4s %-6s %-7s %-24s %-26s %-9s %s\n' \
            "${R_ID[i]}" "$family" "$proto" "${R_LISTEN[i]}" "$target" "$iface" "$masq"
    done
}

cmd_status() {
    local enabled="" active="" forward4="未知" forward6="未知" family table_status=""

    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) die "未知选项：$1" ;;
    esac

    detect_os
    state_load "$STATE_FILE"

    printf '%-14s %s\n' "程序版本" "$SCRIPT_VERSION"
    printf '%-14s %s\n' "系统" "$OS_NAME"
    printf '%-14s %s\n' "内核" "$(uname -sr)"
    printf '%-14s %s\n' "规则数量" "${#R_ID[@]}"
    printf '%-14s %s\n' "状态文件" "$STATE_FILE"

    if [[ -r /proc/sys/net/ipv4/ip_forward ]]; then
        forward4=$(< /proc/sys/net/ipv4/ip_forward)
    fi
    if [[ "$forward4" == "1" ]]; then
        printf '%-14s %s\n' "IPv4 转发" "已启用"
    else
        printf '%-14s %s\n' "IPv4 转发" "$forward4"
    fi

    if [[ -r /proc/sys/net/ipv6/conf/all/forwarding ]]; then
        forward6=$(< /proc/sys/net/ipv6/conf/all/forwarding)
    fi
    if [[ "$forward6" == "1" ]]; then
        printf '%-14s %s\n' "IPv6 转发" "已启用"
    else
        printf '%-14s %s\n' "IPv6 转发" "$forward6"
    fi

    if is_root && have nft; then
        for family in "${TABLE_FAMILIES[@]}"; do
            if nft list table "$family" "$TABLE_NAME" >/dev/null 2>&1; then
                if table_is_ours "$family"; then
                    table_status+="${family}:已加载 "
                else
                    table_status+="${family}:同名非本脚本表 "
                fi
            else
                table_status+="${family}:未加载 "
            fi
        done
        printf '%-14s %s\n' "运行时表" "${table_status% }"
    else
        printf '%-14s %s\n' "运行时表" "未知（需要 root 和 nft）"
    fi

    if systemd_available; then
        enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)
        active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
        if [[ -n "$enabled" ]]; then
            printf '%-14s %s\n' "systemd 服务" "${enabled} / ${active:-未知}"
        else
            printf '%-14s %s\n' "systemd 服务" "未安装"
        fi
    else
        printf '%-14s %s\n' "systemd 服务" "systemd 不可用"
    fi
}

CHECK_FAILS=0
CHECK_WARNS=0

report_ok() {
    printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

report_info() {
    printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
}

report_warn() {
    CHECK_WARNS=$((CHECK_WARNS + 1))
    printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

report_fail() {
    CHECK_FAILS=$((CHECK_FAILS + 1))
    printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

check_env() {
    local nft_path="" nft_ver="" nft_ver_raw=""
    local forward4="未知" forward6="未知" missing=()
    local dep family table_seen=0

    detect_os
    CHECK_FAILS=0
    CHECK_WARNS=0

    printf '%s %s 环境检查\n' "$PROG_NAME" "$SCRIPT_VERSION"
    printf '%s\n' "------------------------------------------------------------"

    if [[ "$(uname -s)" == "Linux" ]]; then
        report_ok "操作系统：$OS_NAME（$(uname -sr)）"
    else
        report_fail "仅支持 Linux，当前系统：$(uname -s)"
    fi

    if ((BASH_VERSINFO[0] >= 4)); then
        report_ok "Bash 版本：${BASH_VERSION}"
    else
        report_fail "Bash 版本过低（需要 4.0+），当前：${BASH_VERSION}"
    fi

    if is_root; then
        report_ok "root 权限：是（UID 0）"
    else
        report_fail "root 权限：否（当前 UID ${EUID:-$(id -u)}）"
    fi

    if have nft; then
        nft_path=$(command -v nft)
        nft_ver_raw=$(nft --version 2>/dev/null || true)
        nft_ver="${nft_ver_raw#* v}"
        nft_ver="${nft_ver%% *}"
        report_ok "nft 命令：$nft_path${nft_ver:+（v$nft_ver）}"
        if [[ "$nft_ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] && version_lt "$nft_ver" "0.9.0"; then
            report_warn "nft 版本较旧（$nft_ver），建议升级到 0.9.0 或更高"
        fi
        if nft_supports_check; then
            report_ok "nft 校验支持：-c/--check 可用"
        else
            report_warn "nft 不支持 -c 校验，应用前无法做离线语法检查"
        fi
    else
        report_fail "nft 命令：缺失"
        report_info "add/install 会在 root 下尝试自动安装 nftables"
        print_install_hint
    fi

    if ! is_root; then
        report_warn "非 root：跳过 nftables 内核接口检测"
    elif have nft; then
        if nft list tables >/dev/null 2>&1; then
            report_ok "nftables 内核接口：可访问"
        else
            report_fail "nftables 内核接口：不可访问（内核不支持、模块未加载或缺少 CAP_NET_ADMIN）"
        fi
    fi

    if [[ -r /proc/sys/net/ipv4/ip_forward ]]; then
        forward4=$(< /proc/sys/net/ipv4/ip_forward)
        if [[ "$forward4" == "1" ]]; then
            report_ok "IPv4 转发：已启用"
        else
            report_warn "IPv4 转发：未启用（add/apply 会自动启用并写入 sysctl 配置）"
        fi
    else
        report_fail "IPv4 转发开关：/proc/sys/net/ipv4/ip_forward 不存在"
    fi

    if [[ -r /proc/sys/net/ipv6/conf/all/forwarding ]]; then
        forward6=$(< /proc/sys/net/ipv6/conf/all/forwarding)
        if [[ "$forward6" == "1" ]]; then
            report_ok "IPv6 转发：已启用"
        else
            report_warn "IPv6 转发：未启用（添加 IPv6 规则时会自动启用）"
        fi
    else
        report_warn "IPv6 转发：内核未提供 IPv6 转发开关（仅可添加 IPv4 规则）"
    fi

    if systemd_available; then
        report_ok "systemd：可用，支持开机自动恢复"
    else
        report_warn "systemd：不可用，install 无法设置开机自启"
    fi

    for dep in sysctl ip flock install; do
        if ! have "$dep"; then
            missing+=("$dep")
        fi
    done
    if ((${#missing[@]})); then
        report_warn "可选命令缺失：${missing[*]}（对应功能可能不可用）"
    else
        report_ok "可选命令：sysctl / ip / flock / install 均可用"
    fi

    if [[ ! -d "$STATE_DIR" ]]; then
        report_info "状态目录：尚不存在（首次 add/install 时创建）"
    elif [[ -w "$STATE_DIR" ]]; then
        report_ok "状态目录：$STATE_DIR 可写"
    else
        report_fail "状态目录：$STATE_DIR 不可写"
    fi

    if is_root && have nft; then
        for family in "${TABLE_FAMILIES[@]}"; do
            if nft list table "$family" "$TABLE_NAME" >/dev/null 2>&1; then
                table_seen=1
                if table_is_ours "$family"; then
                    report_info "运行时表：$family ${TABLE_NAME} 已加载"
                else
                    report_warn "运行时表：存在同名表 $family ${TABLE_NAME}，但缺少 owner 链"
                fi
            fi
        done
        if ((table_seen == 0)); then
            report_info "运行时表：ip/ip6 ${TABLE_NAME} 未加载"
        fi
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        report_info "开机服务：已安装 $SERVICE_FILE"
    else
        report_info "开机服务：未安装（添加规则时会自动安装）"
    fi

    printf '%s\n' "------------------------------------------------------------"
    if ((CHECK_FAILS > 0)); then
        err "环境检查未通过：${CHECK_FAILS} 项失败，${CHECK_WARNS} 项警告。"
        return 1
    fi
    ok "环境检查通过（${CHECK_WARNS} 项警告）。"
    return 0
}

cmd_check() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
            *) die "未知选项：$arg" ;;
        esac
    done
    check_env
}

# ------------------------------------------------------------------------------
# install / uninstall
# ------------------------------------------------------------------------------

write_service_file() {
    mkdir -p "$(dirname "$SERVICE_FILE")" || die "无法创建 systemd 目录"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=nftables port forwarding (${PROG_NAME})
Documentation=man:nft(8)
After=network-pre.target
Wants=network-pre.target
Before=network.target
ConditionPathExists=${STATE_FILE}

[Service]
Type=oneshot
RemainAfterExit=yes
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="NFTF_AUTO_INSTALL=0"
ExecStart=${INSTALL_PATH} apply --quiet
ExecReload=${INSTALL_PATH} apply --quiet
ExecStop=${INSTALL_PATH} down --quiet
TimeoutStartSec=30
UMask=0022

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SERVICE_FILE" 2>/dev/null || true
}

install_self() {
    local src dst src_path newpath
    src_path="${BASH_SOURCE[0]:-$0}"
    mkdir -p "$(dirname "$INSTALL_PATH")" || die "无法创建 $INSTALL_PATH 所在目录"
    newpath="${INSTALL_PATH}.new.$$"
    CLEANUP_FILES+=("$newpath")

    if [[ -n "$src_path" && -f "$src_path" ]]; then
        src=$(readlink -f "$src_path" 2>/dev/null || printf '%s' "$src_path")
        dst=$(readlink -f "$INSTALL_PATH" 2>/dev/null || printf '%s' "$INSTALL_PATH")
        if [[ "$src" == "$dst" ]]; then
            ok "脚本已位于 $INSTALL_PATH"
            return 0
        fi
        if have install; then
            install -m 0755 "$src" "$newpath" || die "复制脚本到 $INSTALL_PATH 失败"
        else
            cp -f "$src" "$newpath" || die "复制脚本到 $INSTALL_PATH 失败"
            chmod 0755 "$newpath" || die "设置脚本执行权限失败"
        fi
    else
        warn "当前脚本不是普通文件（进程替换/管道），从 GitHub 下载副本用于开机服务..."
        if have curl; then
            curl -fsSL --retry 3 "$SELF_RAW_URL" -o "$newpath" ||
                die "下载脚本失败：$SELF_RAW_URL"
        elif have wget; then
            wget -qO "$newpath" "$SELF_RAW_URL" ||
                die "下载脚本失败：$SELF_RAW_URL"
        else
            die "缺少 curl/wget，无法为开机服务准备脚本副本"
        fi
        [[ -s "$newpath" ]] || die "下载的脚本为空"
        bash -n "$newpath" || die "下载的脚本未通过语法检查"
        chmod 0755 "$newpath" || die "设置脚本执行权限失败"
    fi

    mv -f "$newpath" "$INSTALL_PATH" || die "安装脚本到 $INSTALL_PATH 失败"
    ok "已安装脚本到 $INSTALL_PATH"
}

cmd_install() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
            *) die "未知选项：$arg" ;;
        esac
    done

    require_root "$@"
    require_nft
    ensure_state_dir

    if [[ ! -f "$STATE_FILE" ]]; then
        local tmp
        tmp=$(mktemp "${STATE_DIR}/.rules.XXXXXX") || die "无法创建状态文件"
        CLEANUP_FILES+=("$tmp")
        state_reset
        state_write "$tmp"
        mv -f "$tmp" "$STATE_FILE" || die "无法写入状态文件"
    fi

    state_load "$STATE_FILE"
    if ((${#R_ID[@]} > 0)); then
        ensure_ip_forward
        if state_has_ipv6; then
            ensure_ipv6_forward
        fi
    fi

    install_self
    write_service_file

    if systemd_available; then
        systemctl daemon-reload || die "systemctl daemon-reload 失败"
        systemctl enable "$SERVICE_NAME" >/dev/null || die "启用 $SERVICE_NAME 失败"
        systemctl reload-or-restart "$SERVICE_NAME" || die "启动 $SERVICE_NAME 失败，请查看 journalctl -u $SERVICE_NAME"
        ok "安装完成：$SERVICE_NAME 已启用并启动。"
        info "查看规则：$INSTALL_PATH list"
        info "查看服务：systemctl status $SERVICE_NAME"
    else
        warn "systemd 不可用：已安装脚本，但不会开机自动恢复。"
        acquire_lock
        apply_nft_file "$STATE_FILE" || return 1
        ok "当前规则已应用；重启后需要手动执行 $INSTALL_PATH apply"
    fi
}

cmd_uninstall() {
    local purge=0 assume_yes=0 family
    local arg

    while (($#)); do
        case "$1" in
            --purge) purge=1; shift ;;
            -y|--yes) assume_yes=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知选项：$1" ;;
        esac
    done

    require_root "$@"
    if ((assume_yes == 0)); then
        if [[ ! -t 0 ]]; then
            die "非交互模式请加 --yes 确认卸载"
        fi
        local answer=""
        read -r -p "确认卸载 nft-forward 服务和运行时规则？[y/N] " answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) die "已取消" ;;
        esac
    fi

    if systemd_available; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$SERVICE_FILE" || true
    if systemd_available; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if have nft; then
        for family in "${TABLE_FAMILIES[@]}"; do
            if nft list table "$family" "$TABLE_NAME" >/dev/null 2>&1; then
                if table_is_ours "$family"; then
                    nft delete table "$family" "$TABLE_NAME" 2>/dev/null || warn "删除 $family ${TABLE_NAME} 失败"
                else
                    warn "保留同名但非本脚本创建的表 $family ${TABLE_NAME}"
                fi
            fi
        done
    fi

    rm -f "$INSTALL_PATH" || true

    if ((purge)); then
        rm -rf "$STATE_DIR"
        rm -f "$SYSCTL_FILE"
        ok "已卸载服务、运行时表、状态文件和 sysctl 配置。"
    else
        ok "已卸载服务和运行时表；规则状态保留在 $STATE_DIR。"
    fi
}

# ------------------------------------------------------------------------------
# 启动环境检测
# ------------------------------------------------------------------------------

ENV_CHECKED=0
ENV_ROOT=0
ENV_NFT_VERSION=""
ENV_FORWARD="未知"
ENV_FORWARD6="未知"
ENV_KERNEL="未知"
ENV_OS_LABEL="Linux"
ENV_AUTH_LABEL=""
ENV_NFT_LABEL=""
ENV_ACCESS_LABEL=""
ENV_FWD_LABEL="未知"
ENV_FWD6_LABEL="未知"
ENV_SYSTEMD_LABEL="不可用"

startup_env_check() {
    local uname_s raw

    if ((ENV_CHECKED)); then
        return 0
    fi
    ENV_CHECKED=1

    detect_os
    uname_s=$(uname -s 2>/dev/null || printf 'unknown')
    ENV_KERNEL=$(uname -sr 2>/dev/null || printf '未知')
    if [[ "$uname_s" == "Linux" ]]; then
        ENV_OS_LABEL="Linux"
    else
        ENV_OS_LABEL="非 Linux（$uname_s）"
    fi

    if is_root; then
        ENV_ROOT=1
        ENV_AUTH_LABEL="root"
    else
        ENV_AUTH_LABEL="非 root"
    fi

    if have nft; then
        raw=$(nft --version 2>/dev/null || true)
        ENV_NFT_VERSION="${raw#* v}"
        ENV_NFT_VERSION="${ENV_NFT_VERSION%% *}"
        if [[ -n "$ENV_NFT_VERSION" ]]; then
            ENV_NFT_LABEL="nft v$ENV_NFT_VERSION"
        else
            ENV_NFT_LABEL="nft 已安装"
        fi
        if ((ENV_ROOT)); then
            if nft list tables >/dev/null 2>&1; then
                ENV_ACCESS_LABEL="nftables 可用"
            else
                ENV_ACCESS_LABEL="nftables 不可用"
            fi
        else
            ENV_ACCESS_LABEL="nftables 状态未知（需要 root）"
        fi
    else
        ENV_NFT_LABEL="nft 缺失（操作时自动安装）"
        ENV_ACCESS_LABEL="nftables 不可用"
    fi

    if [[ -r /proc/sys/net/ipv4/ip_forward ]]; then
        ENV_FORWARD=$(< /proc/sys/net/ipv4/ip_forward)
    fi
    case "$ENV_FORWARD" in
        1) ENV_FWD_LABEL="已启用" ;;
        0) ENV_FWD_LABEL="未启用" ;;
        *) ENV_FWD_LABEL="未知" ;;
    esac

    if [[ -r /proc/sys/net/ipv6/conf/all/forwarding ]]; then
        ENV_FORWARD6=$(< /proc/sys/net/ipv6/conf/all/forwarding)
    fi
    case "$ENV_FORWARD6" in
        1) ENV_FWD6_LABEL="已启用" ;;
        0) ENV_FWD6_LABEL="未启用" ;;
        *) ENV_FWD6_LABEL="未知" ;;
    esac

    if systemd_available; then
        ENV_SYSTEMD_LABEL="可用"
    else
        ENV_SYSTEMD_LABEL="不可用"
    fi
    return 0
}

env_summary() {
    startup_env_check
    printf '%s[环境]%s %s / %s / %s\n' \
        "$C_BLUE" "$C_RESET" "$ENV_OS_LABEL" "$ENV_AUTH_LABEL" "$ENV_NFT_LABEL" >&2
    printf '        %s | IPv4转发: %s | IPv6转发: %s | systemd: %s | 内核: %s\n' \
        "$ENV_ACCESS_LABEL" "$ENV_FWD_LABEL" "$ENV_FWD6_LABEL" "$ENV_SYSTEMD_LABEL" "$ENV_KERNEL" >&2
}

# ------------------------------------------------------------------------------
# 交互式菜单
# ------------------------------------------------------------------------------

MENU_PROTO="tcp"
MENU_IFACE=""
MENU_MASQ=1
IFACE_LIST=()
declare -A IFACE_ADDR_MAP=()

detect_interfaces() {
    local idx name family addr rest path base

    if ! have ip; then
        auto_install_iproute || true
    fi

    IFACE_LIST=()
    IFACE_ADDR_MAP=()

    if have ip; then
        while read -r idx name _; do
            name="${name%:}"
            name="${name%%@*}"
            [[ -n "$name" ]] || continue
            if [[ -z "${IFACE_ADDR_MAP[$name]+x}" ]]; then
                IFACE_LIST+=("$name")
                IFACE_ADDR_MAP[$name]=""
            fi
        done < <(ip -o link show 2>/dev/null)

        while read -r idx name family addr _; do
            name="${name%:}"
            name="${name%%@*}"
            [[ -n "$name" ]] || continue
            if [[ -z "${IFACE_ADDR_MAP[$name]+x}" ]]; then
                IFACE_LIST+=("$name")
                IFACE_ADDR_MAP[$name]=""
            fi
            case "$family" in
                inet|inet6) IFACE_ADDR_MAP[$name]+="${addr} " ;;
            esac
        done < <(ip -o addr show 2>/dev/null)
    fi

    if ((${#IFACE_LIST[@]} == 0)); then
        for path in /sys/class/net/*; do
            [[ -e "$path" ]] || continue
            base="${path##*/}"
            IFACE_LIST+=("$base")
            IFACE_ADDR_MAP[$base]=""
        done
    fi
}

menu_select_iface() {
    local choice idx name addrs

    detect_interfaces
    if ((${#IFACE_LIST[@]} == 0)); then
        warn "未检测到网卡，请手动输入"
        if ! read -r -p '网卡名（留空=任意）: ' MENU_IFACE; then
            return 1
        fi
        if [[ "$MENU_IFACE" == "any" || "$MENU_IFACE" == "-" ]]; then
            MENU_IFACE=""
        fi
        return 0
    fi

    printf '\n可用入口网卡（显示已绑定 IP）:\n'
    printf '   0) 不限制入口网卡\n'
    idx=1
    for name in "${IFACE_LIST[@]}"; do
        addrs="${IFACE_ADDR_MAP[$name]:-}"
        addrs="${addrs% }"
        if [[ -z "$addrs" ]]; then
            addrs="未检测到 IP"
        fi
        printf '  %2d) %-12s %s\n' "$idx" "$name" "$addrs"
        idx=$((idx + 1))
    done
    printf '   m) 手动输入网卡名\n'

    if ! read -r -p '请选择 [0]: ' choice; then
        return 1
    fi
    choice="${choice:-0}"

    if [[ "$choice" == "m" || "$choice" == "M" ]]; then
        if ! read -r -p '网卡名（留空=任意）: ' MENU_IFACE; then
            return 1
        fi
        if [[ "$MENU_IFACE" == "any" || "$MENU_IFACE" == "-" ]]; then
            MENU_IFACE=""
        fi
        return 0
    fi

    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
        warn "网卡选择无效"
        return 1
    fi
    if ((choice == 0)); then
        MENU_IFACE=""
        return 0
    fi
    if ((choice < 1 || choice > ${#IFACE_LIST[@]})); then
        warn "网卡选择超出范围"
        return 1
    fi
    MENU_IFACE="${IFACE_LIST[choice - 1]}"
    return 0
}

menu_clear() {
    if have clear; then
        clear 2>/dev/null || true
    fi
}

menu_rule_count() {
    local count="0"
    if [[ -r "$STATE_FILE" ]]; then
        count=$(grep -c '^[1-9][0-9]*|' "$STATE_FILE" 2>/dev/null || true)
    fi
    printf '%s' "${count:-0}"
}

menu_header() {
    local count user

    startup_env_check
    count=$(menu_rule_count)
    if is_root; then
        user="root"
    else
        user="非 root (UID ${EUID:-$(id -u)})"
    fi

    printf '\n'
    printf '============================================================\n'
    printf '  nft-forward %s  |  nftables IPv4/IPv6 端口转发\n' "$SCRIPT_VERSION"
    printf '  用户: %s    已保存规则: %s\n' "$user" "$count"
    printf '  环境: %s / %s / %s\n' "$ENV_OS_LABEL" "$ENV_AUTH_LABEL" "$ENV_NFT_LABEL"
    printf '        %s | IPv4转发: %s | IPv6转发: %s | systemd: %s\n' \
        "$ENV_ACCESS_LABEL" "$ENV_FWD_LABEL" "$ENV_FWD6_LABEL" "$ENV_SYSTEMD_LABEL"
    printf '============================================================\n'
    printf '%s\n' \
        '  1) 添加单端口规则' \
        '  2) 添加多端口/范围规则' \
        '  3) 添加端口组合规则' \
        '  4) 添加自定义多目标规则' \
        '  5) 查看规则' \
        '  6) 删除规则' \
        '  7) 清空规则' \
        '  8) 预览 nftables 规则' \
        '  9) 重新应用规则' \
        ' 10) 查看运行状态' \
        ' 11) 安装/修复开机服务' \
        ' 12) 卸载服务' \
        '  0) 退出'
    printf '%s\n' '------------------------------------------------------------'
}

menu_pause() {
    local dummy
    [[ -t 0 ]] || return 0
    printf '\n按 Enter 返回菜单...'
    read -r dummy || true
    : "$dummy"
    printf '\n'
}

menu_run() {
    ( "$@" ) || true
}

menu_require_root() {
    if is_root; then
        return 0
    fi
    warn "该操作需要 root 权限，请退出菜单后使用：sudo $0 menu"
    menu_pause
    return 1
}

menu_ask_options() {
    local choice masq

    MENU_PROTO="tcp"
    MENU_IFACE=""
    MENU_MASQ=1

    printf '\n协议:\n'
    printf '  1) TCP（默认）\n'
    printf '  2) UDP\n'
    printf '  3) TCP + UDP\n'
    if ! read -r -p '请选择 [1]: ' choice; then
        return 1
    fi
    case "${choice:-1}" in
        1) MENU_PROTO="tcp" ;;
        2) MENU_PROTO="udp" ;;
        3) MENU_PROTO="both" ;;
        *) warn "协议选择无效"; return 1 ;;
    esac

    if ! menu_select_iface; then
        return 1
    fi

    if ! read -r -p '是否启用 masquerade/SNAT? [Y/n]: ' masq; then
        return 1
    fi
    case "${masq:-y}" in
        n|N|no|NO) MENU_MASQ=0 ;;
        *) MENU_MASQ=1 ;;
    esac
    return 0
}

menu_add_rule() {
    local mode="$1"
    local label hint listen dest dports
    local -a args=()

    if ! menu_require_root; then return 0; fi

    case "$mode" in
        single)
            label="单端口"
            hint="监听一个端口，目标写一个端口。示例：8080 -> 192.168.1.10:80 或 8080 -> [2001:db8::10]:80"
            ;;
        multi)
            label="多端口/范围"
            hint="监听可写 80,443,8000-8010；目标端口可写一个，所有监听端口都转到它。"
            ;;
        combo)
            label="端口组合"
            hint="监听端口和目标端口数量必须一致，按从小到大一一对应。"
            ;;
        *)
            warn "内部错误：未知添加模式"
            return 1
            ;;
    esac

    printf '\n--- 添加%s规则 ---\n' "$label"
    printf '%s\n' "$hint"
    if ! read -r -p '监听端口: ' listen; then return 1; fi
    if ! read -r -p '目标 IPv4/IPv6 地址: ' dest; then return 1; fi
    if ! read -r -p '目标端口: ' dports; then return 1; fi
    if [[ -z "$listen" || -z "$dest" || -z "$dports" ]]; then
        warn "监听端口、目标地址和目标端口都不能为空"
        menu_pause
        return 1
    fi
    if ! menu_ask_options; then
        menu_pause
        return 1
    fi

    args=(--listen "$listen" --dest "$dest" --dest-port "$dports" --proto "$MENU_PROTO")
    if [[ -n "$MENU_IFACE" ]]; then
        args+=(--iface "$MENU_IFACE")
    fi
    if ((MENU_MASQ == 1)); then
        args+=(--masquerade)
    else
        args+=(--no-masquerade)
    fi
    menu_run cmd_add "${args[@]}"
    menu_pause
    return 0
}

menu_add_custom() {
    local line
    local -a rule_args=() args=()

    if ! menu_require_root; then return 0; fi

    printf '\n--- 添加自定义多目标规则 ---\n'
    printf '%s\n' '格式：监听端口:目标地址:目标端口'
    printf '%s\n' 'IPv4 示例：80:192.168.1.10:80'
    printf '%s\n' 'IPv6 示例：80:[2001:db8::10]:80'
    printf '%s\n' '输入空行结束。'

    while true; do
        if ! read -r -p '--rule: ' line; then
            break
        fi
        if [[ -z "$line" || "$line" == "q" || "$line" == "Q" ]]; then
            break
        fi
        rule_args+=("--rule" "$line")
    done

    if ((${#rule_args[@]} == 0)); then
        info "未输入规则，已取消。"
        menu_pause
        return 0
    fi
    if ! menu_ask_options; then
        menu_pause
        return 1
    fi

    args=("${rule_args[@]}" --proto "$MENU_PROTO")
    if [[ -n "$MENU_IFACE" ]]; then
        args+=(--iface "$MENU_IFACE")
    fi
    if ((MENU_MASQ == 1)); then
        args+=(--masquerade)
    else
        args+=(--no-masquerade)
    fi
    menu_run cmd_add "${args[@]}"
    menu_pause
    return 0
}

menu_delete() {
    local count input id
    local -a ids=()

    if ! menu_require_root; then return 0; fi

    count=$(menu_rule_count)
    if [[ "$count" == "0" ]]; then
        info "暂无规则。"
        menu_pause
        return 0
    fi

    menu_run cmd_list
    printf '\n'
    if ! read -r -p '要删除的规则 ID（空格/逗号分隔，0 取消）: ' input; then
        return 1
    fi
    if [[ -z "$input" || "$input" == "0" ]]; then
        return 0
    fi
    input="${input//,/ }"
    read -r -a ids <<< "$input"
    if ((${#ids[@]} == 0)); then
        return 0
    fi
    for id in "${ids[@]}"; do
        if [[ ! "$id" =~ ^[1-9][0-9]*$ ]]; then
            warn "非法规则 ID：$id"
            menu_pause
            return 1
        fi
    done

    menu_run cmd_remove "${ids[@]}"
    menu_pause
    return 0
}

menu_flush() {
    local count answer

    if ! menu_require_root; then return 0; fi

    count=$(menu_rule_count)
    if [[ "$count" == "0" ]]; then
        info "暂无规则可清空。"
        menu_pause
        return 0
    fi

    printf '\n当前有 %s 条已保存规则。\n' "$count"
    if ! read -r -p '输入 yes 确认清空: ' answer; then
        return 1
    fi
    case "$answer" in
        yes|YES) ;;
        *)
            info "已取消。"
            menu_pause
            return 0
            ;;
    esac

    menu_run cmd_flush --yes
    menu_pause
    return 0
}

menu_preview() {
    menu_run cmd_apply --dry-run
    menu_pause
}

menu_apply() {
    if ! menu_require_root; then return 0; fi
    menu_run cmd_apply
    menu_pause
}

menu_install() {
    if ! menu_require_root; then return 0; fi
    menu_run cmd_install
    menu_pause
}

menu_uninstall() {
    local answer purge
    local -a args=(--yes)

    if ! menu_require_root; then return 0; fi

    printf '\n卸载会停止开机服务并删除运行时转发表。\n'
    if ! read -r -p '输入 yes 确认卸载: ' answer; then
        return 1
    fi
    case "$answer" in
        yes|YES) ;;
        *)
            info "已取消。"
            menu_pause
            return 0
            ;;
    esac

    if ! read -r -p '是否同时删除状态文件和 sysctl 配置? [y/N]: ' purge; then
        purge="n"
    fi
    if [[ "$purge" == "y" || "$purge" == "Y" || "$purge" == "yes" || "$purge" == "YES" ]]; then
        args+=(--purge)
    fi

    menu_run cmd_uninstall "${args[@]}"
    menu_pause
    return 0
}

cmd_menu() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) die "未知选项：$1" ;;
    esac

    if [[ ! -t 0 || ! -t 1 ]]; then
        die "交互式菜单需要终端；请使用 $0 --help 查看命令行用法"
    fi

    startup_env_check
    local choice
    while true; do
        menu_clear
        menu_header
        if ! read -r -p '请选择 [0-12]: ' choice; then
            printf '\n'
            break
        fi

        case "$choice" in
            1) menu_add_rule single ;;
            2) menu_add_rule multi ;;
            3) menu_add_rule combo ;;
            4) menu_add_custom ;;
            5) menu_run cmd_list; menu_pause ;;
            6) menu_delete ;;
            7) menu_flush ;;
            8) menu_preview ;;
            9) menu_apply ;;
            10) menu_run cmd_status; menu_pause ;;
            11) menu_install ;;
            12) menu_uninstall ;;
            0|q|Q|exit) info "已退出。"; break ;;
            *) warn "无效选择：$choice"; sleep 1 ;;
        esac

        # 操作可能改变 nft / 转发状态，下一次刷新菜单时重新检测。
        ENV_CHECKED=0
    done
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------

main() {
    local cmd="${1:-}"
    if (($# > 0)); then shift; fi

    detect_os

    # 启动时自动检测环境：帮助、版本和详细 check 除外；菜单在标题中显示。
    case "$cmd" in
        ""|help|-h|--help|version|-V|--version|check|doctor|menu|m) ;;
        *)
            startup_env_check
            env_summary
            ;;
    esac

    case "$cmd" in
        add|a)                  cmd_add "$@" ;;
        remove|rm|del)          cmd_remove "$@" ;;
        list|ls)                cmd_list "$@" ;;
        flush|clear)            cmd_flush "$@" ;;
        apply|reload|restore|up) cmd_apply "$@" ;;
        down|stop)              cmd_down "$@" ;;
        check|doctor)           cmd_check "$@" ;;
        status|st)              cmd_status "$@" ;;
        menu|m)                 cmd_menu "$@" ;;
        install)                cmd_install "$@" ;;
        uninstall)              cmd_uninstall "$@" ;;
        version|-V|--version)   version ;;
        help|-h|--help)         usage ;;
        "")
            if [[ -t 0 && -t 1 ]]; then
                cmd_menu
            else
                usage
                exit 1
            fi
            ;;
        *)
            die "未知命令：$cmd（使用 --help 查看帮助）"
            ;;
    esac
}

main "$@"
