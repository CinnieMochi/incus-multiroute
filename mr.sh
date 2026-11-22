#!/bin/bash
#
# Incus MultiRoute 宿主机出口管理脚本 v3.4.10
# 作用：在 incus 宿主机上管理 LXC 用户的出站出口（ss / ss2022 / wg）
# 风格：与本机其它运维脚本（lxc.sh 等）保持一致
#
# 目录：
#   /etc/incus-multiroute        配置（出口、绑定、令牌、用户端脚本基准）
#   /var/lib/incus-multiroute    数据（渲染产物、日志）
#
# 非交互命令（供 cron / systemd 调用）：
#   mr apply      重新下发全部规则
#   mr refresh    按 incus 实际状态校正容器 IP
#   mr sync       校验并下发用户端 out（缺失/不一致则推送）
#   mr doctor     环境体检
#

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
PURPLE=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
NC=$'\033[0m'

CONF_DIR="/etc/incus-multiroute"
DATA_DIR="/var/lib/incus-multiroute"
MAIN_CONF="$CONF_DIR/mr.conf"
EXITS_CONF="$CONF_DIR/exits.conf"
BIND_CONF="$CONF_DIR/bindings.conf"
TOKEN_CONF="$CONF_DIR/tokens.conf"
SS_DIR="$CONF_DIR/singbox"
CLIENT_BASE="$DATA_DIR/client/out"
CLIENT_HASH="$CONF_DIR/client.sha256"
CLIENT_ALLOW_CONF="$CONF_DIR/clients.conf"
CLIENT_DENY_CONF="$CONF_DIR/clients.deny"
LOGIC_CONF="$CONF_DIR/logical.conf"
AUTO_GRANT="${AUTO_GRANT:-0}"
BRIDGE_IPV6_AUTO="${BRIDGE_IPV6_AUTO:-0}"
BRIDGE_IPV4_AUTO="${BRIDGE_IPV4_AUTO:-0}"
AUTO_HARDEN="${AUTO_HARDEN:-0}"
NFT_FILE="$DATA_DIR/mr.nft"
UNIT_DIR="/etc/systemd/system"
API_PY="/usr/local/bin/mr-api.py"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

SCRIPT_VERSION="3.4.10"
REPO_OWNER="CinnieMochi"
REPO_NAME="incus-multiroute"
REPO_BRANCH="main"
UPDATE_BASE="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH"

BRIDGE="incusbr0"
SUBNET_GW=""
TPROXY_BASE="27000"
WG_PRIVATE_KEY=""
TPROXY_BASE="${TPROXY_BASE:-27000}"
SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
SS_CLIENT_CMD="$SINGBOX_BIN run"

# ---------------------------------------------------------------- 输出

line()     { printf '%s\n' '============================================================'; }
subline()  { printf '%s\n' '------------------------------------------------------------'; }
title()    { line; printf '%s%s%s\n' "$CYAN" "$1" "$NC"; line; }
section()  { printf '  %s【%s】%s\n' "$CYAN" "$1" "$NC"; }
ok()       { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$1"; }
warn()     { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$1"; }
err()      { printf '%s[错误]%s %s\n' "$RED" "$NC" "$1"; }
info()     { printf '%s[信息]%s %s\n' "$BLUE" "$NC" "$1"; }

pause_back() {
    [ -t 0 ] || return 0
    printf '\n%s按回车返回上一层...%s' "$YELLOW" "$NC"
    read -r _ || true
}

clear_if_tty() {
    if [ -t 1 ] && [ -n "$TERM" ] && [ "$TERM" != "dumb" ] && command -v clear >/dev/null 2>&1; then
        clear
    fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [ "$(id -u)" = "0" ] && return 0
    err "本脚本需要 root 权限运行"
    exit 1
}


# ---------------------------------------------------------------- 配置

detect_bridge() {
    if has_cmd incus; then
        local b
        b="$(incus network list --format=csv 2>/dev/null | cut -d, -f1 | grep -m1 -E '^incusbr|^lxdbr' || true)"
        [ -n "$b" ] && { echo "$b"; return 0; }
    fi
    ip -4 -o addr show 2>/dev/null | awk '{print $2}' | grep -m1 -E '^(incusbr|lxdbr)' || true
}

detect_gateway() {
    local b
    b="${BRIDGE:-incusbr0}"
    ip -4 -o addr show dev "$b" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

detect_subnet() {
    local b
    b="${BRIDGE:-incusbr0}"
    ip -4 -o addr show dev "$b" 2>/dev/null | awk '{print $4}' | head -1
}

ensure_dirs() {
    mkdir -p "$CONF_DIR" "$DATA_DIR" "$DATA_DIR/client" "$SS_DIR"
    [ -f "$EXITS_CONF" ] || printf '%s\n' '# 名称|协议|地址|端口|加密|密码|mark|wg公钥|wg接口|隧道本端|期望出口IP|启用|指定本地端口|第二地址(双隧道)' > "$EXITS_CONF"
    [ -f "$BIND_CONF" ]  || printf '%s\n' '# 容器|IPv4|出口|mark' > "$BIND_CONF"
    [ -f "$TOKEN_CONF" ] || { : > "$TOKEN_CONF"; chmod 600 "$TOKEN_CONF"; }
    [ -f "$LOGIC_CONF" ] || printf '%s\n' '# 节点|序号|协议|地址|端口|加密|密码|家族(v4/v6)' > "$LOGIC_CONF"
    if [ ! -f "$CONF_DIR/api.conf" ]; then
        # 默认只绑网桥地址，避免 API 暴露到公网
        local _gw
        _gw="$(detect_gateway 2>/dev/null)"
        [ -n "$_gw" ] || _gw="0.0.0.0"
        printf 'LISTEN="%s:18988"\n' "$_gw" > "$CONF_DIR/api.conf"
    fi
    [ -f "$CLIENT_ALLOW_CONF" ] || printf '%s\n' '# 授权使用 out 的容器，一行一个；不在本表的容器永远不会被下发' > "$CLIENT_ALLOW_CONF"
    # 出口配置里含明文密码，只允许 root 读
    chmod 600 "$EXITS_CONF" "$LOGIC_CONF" "$MAIN_CONF" 2>/dev/null || true
}

init_main_conf() {
    [ -f "$MAIN_CONF" ] && return 0
    local b gw
    b="$(detect_bridge)"
    [ -n "$b" ] || b="incusbr0"
    gw="$(ip -4 -o addr show dev "$b" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    {
        echo '# Incus MultiRoute 主配置'
        echo "BRIDGE="$b""
        echo "SUBNET_GW="$gw""
        echo 'TPROXY_BASE="27000"'
        echo 'AUTO_GRANT=0'
        echo 'WG_PRIVATE_KEY=""'
        echo 'SS_CLIENT_CMD="/usr/local/bin/sing-box run"'
    } > "$MAIN_CONF"
    chmod 600 "$MAIN_CONF"
}

load_conf() {
    ensure_dirs
    init_main_conf
    . "$MAIN_CONF"
    # 本项目固定使用自己的一份 sing-box，不跟随系统/其它面板的那份
    SINGBOX_BIN="/usr/local/bin/sing-box"
    # 清掉旧版本引入的 SINGBOX_BIN 配置项（复用其它二进制已被移除）
    if grep -q '^SINGBOX_BIN=' "$MAIN_CONF" 2>/dev/null; then
        grep -v '^SINGBOX_BIN=' "$MAIN_CONF" > "$MAIN_CONF.tmp" && mv -f "$MAIN_CONF.tmp" "$MAIN_CONF"
        info "已移除 mr.conf 里的 SINGBOX_BIN（本项目固定使用 /usr/local/bin/sing-box）"
    fi
    # 端口段从 41000 迁到 27000：避开常见业务号段，且用户端口映射撞号时能明确报占用
    if [ "$TPROXY_BASE" = "41000" ]; then
        TPROXY_BASE="27000"
        save_main_var TPROXY_BASE "27000"
        info "端口段已从 41000 迁移到 27000-27099，需重新下发一次"
    fi
    BRIDGE="${BRIDGE:-incusbr0}"
    [ -n "$SUBNET_GW" ] || SUBNET_GW="$(detect_gateway)"
}

save_main_var() {
    local k="$1" v="$2"
    grep -v "^$k=" "$MAIN_CONF" > "$MAIN_CONF.tmp" 2>/dev/null || :
    printf '%s="%s"\n' "$k" "$v" >> "$MAIN_CONF.tmp"
    mv -f "$MAIN_CONF.tmp" "$MAIN_CONF"
    chmod 600 "$MAIN_CONF"
}


# ---------------------------------------------------------------- 出口

exits_count() {
    grep -v '^#' "$EXITS_CONF" 2>/dev/null | grep -c '|' || true
}

exits_each() {
    local cb="$1" l
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS="|" read -r e_name e_proto e_host e_port e_method e_pass e_mark e_wgkey e_wgif e_local e_expect e_enable e_lp e_host6 <<< "$l"
        "$cb" "$e_name" "$e_proto" "$e_host" "$e_port" "$e_method" "$e_pass" "$e_mark" "$e_wgkey" "$e_wgif" "$e_local" "$e_expect" "$e_enable" "$e_lp" "$e_host6"
    done < "$EXITS_CONF"
}

exit_get() {
    local want="$1" l
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        [ "${l%%|*}" = "$want" ] || continue
        echo "$l"
        return 0
    done < "$EXITS_CONF"
    return 1
}

# 字段: 1名称 2协议 3地址 4端口 5加密 6密码 7mark 8wg公钥 9wg接口 10本端 11期望IP 12启用
exit_fld() {
    local l="$1" i="$2"
    printf '%s' "$l" | awk -F'|' -v i="$i" '{print $i}'
}

exit_exists() { exit_get "$1" >/dev/null 2>&1; }

exit_ss_port() {
    # ss 出口的本地代理端口 = TPROXY_BASE + 序号
    # 只对 Shadowsocks 出口计数：WireGuard 出口不占端口，不该挤掉端口号
    local want="$1" l i=0 name proto a1 a2 a3 a4 a5 a6 a7 a8 a9 enable
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS="|" read -r name proto a1 a2 a3 a4 a5 a6 a7 a8 a9 enable a10 a11 <<< "$l"
        case "$proto" in ss|ss2022|logic) ;; *) continue ;; esac
        i=$((i + 1))
        if [ "$name" = "$want" ]; then
            # 第 13 字段是"指定端口"：被占用时给这个出口单独分配的号，优先使用
            if [ -n "${a10:-}" ]; then
                echo "$a10"
                return 0
            fi
            i_port=$((TPROXY_BASE + i))
            if [ "$i_port" -gt "$((TPROXY_BASE + 99))" ]; then
                return 1
            fi
            echo "$i_port"
            return 0
        fi
    done < "$EXITS_CONF"
    return 1
}

exits_list_plain() {
    grep -v '^#' "$EXITS_CONF" 2>/dev/null | cut -d'|' -f1,2,3,4
}

# ---------------------------------------------------------------- 容器绑定

bindings_each() {
    local cb="$1" l
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r b_name b_ip b_exit b_mark <<< "$l"
        "$cb" "$b_name" "$b_ip" "$b_exit" "$b_mark"
    done < "$BIND_CONF"
}

ip2int() {
    local IFS=.
    set -- $1
    echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}

in_bridge_subnet() {  # $1=IP  $2=网桥 CIDR（如 10.10.0.1/22）
    local ip="$1" cidr="$2" net len mi ipi neti
    net="${cidr%/*}"; len="${cidr#*/}"
    case "$ip" in ''|*[!0-9.]*) return 1 ;; esac
    case "$net" in ''|*[!0-9.]*) return 1 ;; esac
    case "$len" in ''|*[!0-9]*) return 1 ;; esac
    [ "$len" -ge 1 ] && [ "$len" -le 32 ] || return 1
    ipi="$(ip2int "$ip")"; neti="$(ip2int "$net")"
    mi=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
    [ $(( ipi & mi )) -eq $(( neti & mi )) ]
}

bridge_ipv6() {
    # 网桥上可用于代理的 IPv6 地址（跳过链路本地）
    local b="${BRIDGE:-incusbr0}"
    ip -6 -o addr show dev "$b" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

bridge_ipv4() {
    # 网桥的 IPv4 地址（透明代理入站绑它）
    local b="${BRIDGE:-incusbr0}"
    ip -4 -o addr show dev "$b" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

container_ip6() {
    # 容器的 IPv6，优先网桥前缀内的（容器里可能还有 wg0 的公网 v6）
    local name="$1" b6 pre a first best ips
    b6="$(bridge_ipv6 2>/dev/null)"
    pre=""
    [ -n "$b6" ] && pre="${b6%::*}"
    if has_cmd jq && has_cmd incus; then
        ips="$(incus list --format=json 2>/dev/null | jq -r --arg n "$name" '.[] | select(.name==$n) | [.state.network[]?.addresses[]? | select(.family=="inet6") | select(.scope!="link") | .address] | join(" ")' 2>/dev/null)"
        first=""; best=""
        for a in $ips; do
            [ -n "$first" ] || first="$a"
            if [ -n "$pre" ] && [ "${a#"$pre"}" != "$a" ]; then best="$a"; break; fi
        done
        [ -n "$best" ] || best="$first"
        [ -n "$best" ] && echo "$best"
        return 0
    fi
    incus list --format=csv -c n6 2>/dev/null | awk -F, -v n="$name" '
        $1 == n { s = $2; gsub(/"/, "", s); c = split(s, a, /[ \t]+/);
            for (i = 1; i <= c; i++) { t = a[i]; if (t == "" || t ~ /^\(/) continue;
                if (t !~ /:/) continue; if (t ~ /^fe80:/) continue; print t; exit } }'
}

containers_scan() {
    # 输出：容器名<TAB>IPv4（优先网桥网段内的地址）
    # 用 incus JSON + jq：CSV 会把容器内部网卡（wg0 等）也列出来，且多地址含换行，逐行解析会错位
    has_cmd incus || return 1
    local cidr n ips a best first
    cidr="$(detect_subnet 2>/dev/null)"
    if has_cmd jq; then
        while IFS=$'\t' read -r n ips; do
            [ -n "$n" ] || continue
            best=""; first=""
            for a in $ips; do
                [ -n "$first" ] || first="$a"
                if [ -n "$cidr" ] && in_bridge_subnet "$a" "$cidr"; then best="$a"; break; fi
            done
            [ -n "$best" ] || best="$first"
            [ -n "$best" ] && printf '%s\t%s\n' "$n" "$best"
        done < <(incus list --format=json 2>/dev/null | jq -r '.[] | "\(.name)\t\([.state.network[]?.addresses[]? | select(.family=="inet") | .address] | join(" "))"' 2>/dev/null)
        return 0
    fi
    # 没有 jq 的兜底：CSV 单行解析（多网卡容器可能取错）
    while IFS=, read -r n ips; do
        n="${n//\"/}"; ips="${ips//\"/}"
        best=""; first=""
        for a in $ips; do
            case "$a" in "("*) continue ;; esac
            case "$a" in *:*|'') continue ;; esac
            [ -n "$first" ] || first="$a"
            if [ -n "$cidr" ] && in_bridge_subnet "$a" "$cidr"; then best="$a"; break; fi
        done
        [ -n "$best" ] || best="$first"
        [ -n "$best" ] && printf '%s\t%s\n' "$n" "$best"
    done < <(incus list --format=csv -c n4 2>/dev/null)
}
container_ip() {
    local name="$1"
    containers_scan 2>/dev/null | awk -F'\t' -v n="$name" '$1==n {print $2; exit}'
}

bind_get() {
    local want="$1" l
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        [ "${l%%|*}" = "$want" ] && { echo "$l"; return 0; }
    done < "$BIND_CONF"
    return 1
}

bind_set() {
    local name="$1" exit_name="$2" ip mark l found=0
    [ -n "$name" ] && [ -n "$exit_name" ] || { err "用法: bind_set 容器 出口"; return 1; }
    exit_exists "$exit_name" || { err "出口不存在: $exit_name"; return 1; }
    l="$(exit_get "$exit_name")"
    mark="$(exit_fld "$l" 7)"
    ip="$(container_ip "$name")"
    : > "$BIND_CONF.tmp"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) printf '%s\n' "$l" >> "$BIND_CONF.tmp"; continue ;; esac
        if [ "${l%%|*}" = "$name" ]; then
            printf '%s|%s|%s|%s\n' "$name" "$ip" "$exit_name" "$mark" >> "$BIND_CONF.tmp"
            found=1
        else
            printf '%s\n' "$l" >> "$BIND_CONF.tmp"
        fi
    done < "$BIND_CONF"
    [ "$found" = "1" ] || printf '%s|%s|%s|%s\n' "$name" "$ip" "$exit_name" "$mark" >> "$BIND_CONF.tmp"
    mv -f "$BIND_CONF.tmp" "$BIND_CONF"
    ok "已绑定 $name -> $exit_name"
}

bind_clear() {
    # 只清空出口与 mark，保留行 ---- 否则容器会因"未识别来源"而再也切不回来
    local name="$1" ip
    ip="$(bind_get "$name" 2>/dev/null | awk -F'|' '{print $2}')"
    [ -n "$ip" ] || ip="$(container_ip "$name")"
    : > "$BIND_CONF.tmp"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) printf '%s\n' "$l" >> "$BIND_CONF.tmp"; continue ;; esac
        if [ "${l%%|*}" = "$name" ]; then
            printf '%s|%s||\n' "$name" "$ip" >> "$BIND_CONF.tmp"
        else
            printf '%s\n' "$l" >> "$BIND_CONF.tmp"
        fi
    done < "$BIND_CONF"
    mv -f "$BIND_CONF.tmp" "$BIND_CONF"
    ok "$name 已切回入口机直出"
}

bind_remove() {
    local name="$1"
    : > "$BIND_CONF.tmp"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) printf '%s\n' "$l" >> "$BIND_CONF.tmp"; continue ;; esac
        [ "${l%%|*}" = "$name" ] || printf '%s\n' "$l" >> "$BIND_CONF.tmp"
    done < "$BIND_CONF"
    mv -f "$BIND_CONF.tmp" "$BIND_CONF"
    ok "已解除绑定 $name（回入口机直出）"
}

clients_prune() {  # 删掉"容器已不存在"的授权/令牌/绑定记录
    local live f name n=0 line
    live="$(incus list --format=csv -c n </dev/null 2>/dev/null | tr -d '"' | sed '/^$/d')"
    [ -n "$live" ] || return 0
    for f in "$CLIENT_ALLOW_CONF" "$TOKEN_CONF" "$BIND_CONF" "$CLIENT_DENY_CONF"; do
        [ -f "$f" ] || continue
        : > "$f.tmp"
        while IFS= read -r line; do
            case "$line" in ''|'#'*) printf '%s\n' "$line" >> "$f.tmp"; continue ;; esac
            name="$(printf '%s' "$line" | cut -d'|' -f1)"
            if printf '%s\n' "$live" | grep -qxF "$name"; then
                printf '%s\n' "$line" >> "$f.tmp"
            else
                n=$((n + 1))
            fi
        done < "$f"
        mv -f "$f.tmp" "$f"
        chmod 600 "$f" 2>/dev/null || true
    done
    [ "$n" -gt 0 ] && info "已清理 $n 条失效记录（容器已删除）"
    return 0
}

bindings_refresh() {
    # 用 incus 的真实 IP 校正 bindings，容器内改 IP 也能自愈
    local l name ip changed=0
    : > "$BIND_CONF.tmp"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) printf '%s\n' "$l" >> "$BIND_CONF.tmp"; continue ;; esac
        IFS='|' read -r b_name b_ip b_exit b_mark <<< "$l"
        if ! incus info "$b_name" >/dev/null 2>&1 </dev/null; then
            info "已移除失效绑定：$b_name（容器已不存在）"; changed=1; continue
        fi
        ip="$(container_ip "$b_name")"
        [ -n "$ip" ] || { warn "容器 $b_name 不在线，保留原绑定"; printf '%s\n' "$l" >> "$BIND_CONF.tmp"; continue; }
        [ "$ip" = "$b_ip" ] || { info "校正 $b_name: $b_ip -> $ip"; changed=1; }
        printf '%s|%s|%s|%s\n' "$b_name" "$ip" "$b_exit" "$b_mark" >> "$BIND_CONF.tmp"
    done < "$BIND_CONF"
    mv -f "$BIND_CONF.tmp" "$BIND_CONF"
    [ "$changed" = "1" ] && return 0
    return 0
}

# ---------------------------------------------------------------- 规则渲染

gen_nft() {
    local elems="" l ts
    ts="$(date +%Y-%m-%d\ %H:%M:%S)"
    elems="$(grep -v '^#' "$BIND_CONF" 2>/dev/null | awk -F'|' 'NF>=4 && $2!="" && $4!="" {printf "%s%s : %s", (n++ ? ",\n        " : "\n        "), $2, $4}')"
    # IPv6：只有网桥配了 IPv6 才启用整套 v6 规则
    BRIDGE6="$(bridge_ipv6 2>/dev/null)"
    local has6=0 elems6=""
    if [ -n "$BRIDGE6" ]; then
        has6=1
        local _bn _bip _bex _bmark _b6 _first6=1
        while IFS='|' read -r _bn _bip _bex _bmark; do
            case "$_bn" in ''|'#'*) continue ;; esac
            [ -n "$_bmark" ] || continue
            _b6="$(container_ip6 "$_bn" 2>/dev/null)"
            [ -n "$_b6" ] || continue
            if [ "$_first6" = "1" ]; then
                elems6="
        $_b6 : $_bmark"
                _first6=0
            else
                elems6="$elems6,
        $_b6 : $_bmark"
            fi
        done < "$BIND_CONF"
    fi
    {
        echo "# 由 Incus MultiRoute 生成于 $ts —— 请勿手改"
        echo 'table inet multiroute {'
        printf '    set bypass4 {\n        type ipv4_addr\n        flags interval\n        elements = { 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }\n    }\n'
        if [ -n "$elems" ]; then
            printf '    map c_ip {\n        type ipv4_addr : mark\n        elements = {%s\n        }\n    }\n' "$elems"
        else
            printf '    map c_ip {\n        type ipv4_addr : mark\n    }\n'
        fi
        # ---- IPv6 部分（仅在网桥有 IPv6 时生成）----
        if [ "$has6" = "1" ]; then
            printf '    set bypass6 {\n        type ipv6_addr\n        flags interval\n        elements = { ::1/128, fe80::/10, fc00::/7 }\n    }\n'
            if [ -n "$elems6" ]; then
                printf '    map c_ip6 {\n        type ipv6_addr : mark\n        elements = {%s\n        }\n    }\n' "$elems6"
            else
                printf '    map c_ip6 {\n        type ipv6_addr : mark\n    }\n'
            fi
        fi
        # 透明代理：TCP + UDP 都走 tproxy（需要 br_netfilter=0）
        echo '    chain prerouting {'
        echo '        type filter hook prerouting priority mangle; policy accept;'
        echo "        iifname \"$BRIDGE\" ip daddr @bypass4 return"
        [ "$has6" = "1" ] && echo "        iifname \"$BRIDGE\" ip6 daddr @bypass6 return"
        echo "        iifname \"$BRIDGE\" meta mark set ip saddr map @c_ip"
        [ "$has6" = "1" ] && echo "        iifname \"$BRIDGE\" meta mark set ip6 saddr map @c_ip6"
        echo "        iifname \"$BRIDGE\" meta mark 0x0 return"
        # 注意：这里绝不能加 "socket transparent 1 accept"，它会把包直接放行走宿主
        exits_each emit_tproxy
        [ "$has6" = "1" ] && exits_each emit_tproxy6
        echo '    }'
        # 防止外部直接访问本机代理端口（sing-box 监听 0.0.0.0）
        echo '    chain input_guard {'
        echo '        type filter hook input priority filter - 5; policy accept;'
        echo "        iifname != \"$BRIDGE\" iifname != \"lo\" tcp dport $TPROXY_BASE-$((TPROXY_BASE + 99)) counter drop"
        echo "        iifname != \"$BRIDGE\" iifname != \"lo\" udp dport $TPROXY_BASE-$((TPROXY_BASE + 99)) counter drop"
        echo '    }'
        echo '    chain postrouting {'
        echo '        type nat hook postrouting priority 100; policy accept;'
        echo '        oifname "wg-*" tcp flags syn tcp option maxseg size set 1380'
        echo '    }'
        echo '}'
    } > "$NFT_FILE"
}


addr_family() {  # $1=地址或域名 → 输出 v4/v6/unknown（域名按解析结果判断）
    local a="$1"
    case "$a" in
        *:*) printf 'v6'; return 0 ;;
        *[0-9].[0-9]*) case "$a" in *[!0-9.]*) : ;; *) printf 'v4'; return 0 ;; esac ;;
    esac
    # 域名：看能解析出哪一族（优先返回单一族，双栈返回 both）
    local has4=0 has6=0
    getent ahostsv4 "$a" >/dev/null 2>&1 && has4=1
    getent ahostsv6 "$a" >/dev/null 2>&1 && has6=1
    if [ "$has4" = "1" ] && [ "$has6" = "1" ]; then printf 'both'
    elif [ "$has4" = "1" ]; then printf 'v4'
    elif [ "$has6" = "1" ]; then printf 'v6'
    else printf 'unknown'; fi
}

split_cfg_json() {  # $1=本地端口 $2=v4侧地址 $3=v6侧地址 $4=端口 $5=method $6=password
    local lport="$1" h4="$2" h6="$3" port="$4" method="$5" pass="$6"
    local inb v6in b6
    inb="$(printf '{"type":"tproxy","tag":"tproxy-in","listen":"%s","listen_port":%s,"network":["tcp","udp"]}' \
        "$(json_esc "${SUBNET_GW:-0.0.0.0}")" "$lport")"
    v6in=""
    b6="$(bridge_ipv6 2>/dev/null)"
    [ -n "$b6" ] && v6in=",$(printf '{"type":"tproxy","tag":"tproxy-in6","listen":"%s","listen_port":%s,"network":["tcp","udp"]}' "$(json_esc "$b6")" "$lport")"
    printf '{\n  "log": { "level": "warn" },\n'
    printf '  "dns": { "servers": [{"tag":"res-v4","type":"udp","server":"1.1.1.1","domain_strategy":"ipv4_only"},{"tag":"res-v6","type":"udp","server":"2606:4700:4700::1111","domain_strategy":"ipv6_only"}] },\n'
    printf '  "inbounds": [%s%s],\n' "$inb" "$v6in"
    printf '  "outbounds": [\n'
    printf '    {"type":"shadowsocks","tag":"v4","server":"%s","server_port":%s,"method":"%s","password":"%s","domain_resolver":"res-v4"},\n' \
        "$(json_esc "$h4")" "$port" "$(json_esc "$method")" "$(json_esc "$pass")"
    printf '    {"type":"shadowsocks","tag":"v6","server":"%s","server_port":%s,"method":"%s","password":"%s","domain_resolver":"res-v6"}\n' \
        "$(json_esc "$h6")" "$port" "$(json_esc "$method")" "$(json_esc "$pass")"
    printf '  ],\n  "route": { "rules": [{"ip_version":4,"outbound":"v4"},{"ip_version":6,"outbound":"v6"}] }\n}\n'
}
logic_members() {  # $1=节点名
    [ -f "$LOGIC_CONF" ] || return 0
    grep -v '^#' "$LOGIC_CONF" 2>/dev/null | awk -F'|' -v n="$1" '$1==n'
}

logic_del_node() {
    [ -f "$LOGIC_CONF" ] || return 0
    grep -v "^$1|" "$LOGIC_CONF" > "$LOGIC_CONF.tmp" 2>/dev/null || :
    mv -f "$LOGIC_CONF.tmp" "$LOGIC_CONF"
}

logic_cfg_json() {  # $1=节点名 $2=本地端口 → 输出 sing-box 配置
    local node="$1" lport="$2"
    local obs="" dns="" rules="" sv4=0 sv6=0
    local line _n idx proto host port method pass fam tag ob rule
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in '#'*) continue ;; esac
        _n="$(printf '%s' "$line" | cut -d'|' -f1)"
        [ "$_n" = "$node" ] || continue
        idx="$(printf '%s' "$line" | cut -d'|' -f2)"
        host="$(printf '%s' "$line" | cut -d'|' -f4)"
        port="$(printf '%s' "$line" | cut -d'|' -f5)"
        method="$(printf '%s' "$line" | cut -d'|' -f6)"
        pass="$(printf '%s' "$line" | cut -d'|' -f7)"
        fam="$(printf '%s' "$line" | cut -d'|' -f8)"
        [ -n "$fam" ] || continue
        local tp
        tp="$(printf '%s' "$line" | cut -d'|' -f9)"
        [ -n "$tp" ] && [ "$tp" != "auto" ] || tp="$fam"
        tag="m${idx}-${fam}"
        if [ "$tp" = "v4" ]; then sv4=1; else sv6=1; fi
        local pn
        pn="$(printf '%s' "$line" | cut -d'|' -f3)"
        if [ "$pn" = "direct" ]; then
            ob="{\"type\":\"direct\",\"tag\":\"$tag\"}"
        else
            ob="{\"type\":\"shadowsocks\",\"tag\":\"$tag\",\"server\":\"$(json_esc "$host")\",\"server_port\":$port,\"method\":\"$(json_esc "$method")\",\"password\":\"$(json_esc "$pass")\",\"domain_resolver\":\"res-$tp\"}"
        fi
        if [ -z "$obs" ]; then obs="$ob"; else obs="$obs,$ob"; fi
        rule="{\"ip_version\":${fam#v},\"outbound\":\"$tag\"}"
        if [ -z "$rules" ]; then rules="$rule"; else rules="$rules,$rule"; fi
    done <<EOF
$(logic_members "$node")
EOF
    if [ "$sv4" = "1" ]; then
        dns='{"tag":"res-v4","type":"udp","server":"1.1.1.1","domain_strategy":"ipv4_only"}'
    fi
    if [ "$sv6" = "1" ]; then
        local d6='{"tag":"res-v6","type":"udp","server":"2606:4700:4700::1111","domain_strategy":"ipv6_only"}'
        if [ -n "$dns" ]; then dns="$dns,$d6"; else dns="$d6"; fi
    fi
    local inb v6in b6
    inb="{\"type\":\"tproxy\",\"tag\":\"tproxy-in\",\"listen\":\"$(json_esc "${SUBNET_GW:-0.0.0.0}")\",\"listen_port\":${lport},\"network\":[\"tcp\",\"udp\"]}"
    v6in=""
    b6="$(bridge_ipv6 2>/dev/null)"
    if [ -n "$b6" ]; then
        v6in=",{\"type\":\"tproxy\",\"tag\":\"tproxy-in6\",\"listen\":\"$(json_esc "$b6")\",\"listen_port\":${lport},\"network\":[\"tcp\",\"udp\"]}"
    fi
    printf '{\n  "log": { "level": "warn" },\n'
    [ -n "$dns" ] && printf '  "dns": { "servers": [%s] },\n' "$dns"
    printf '  "inbounds": [%s%s],\n  "outbounds": [%s],\n  "route": { "rules": [%s] }\n}\n' "$inb" "$v6in" "$obs" "$rules"
}
exit_add_logic() {
    local name mark idx=0 used4=0 used6=0
    local step host port method pass fam ps msel methods m reason st
    clear_if_tty
    title "新增逻辑节点（2 台机器拼 IPv4 + IPv6）"
    info "一个逻辑节点最多两个成员：一个提供 IPv4、一个提供 IPv6"
    info "用户访问 v4 网站走 v4 成员，访问 v6 网站走 v6 成员"
    info "每一步输入 0 都可以返回上一步"
    if ! singbox_installed; then
        err "还没有安装 sing-box（逻辑节点依赖它）"
        info "请先到菜单 [15] → [3] 安装"
        pause_back; return 1
    fi
    while :; do
        printf '节点名称（输入 0 返回菜单）: '; read -r name || return 0
        case "$name" in 0|"") info "已取消"; return 0 ;; esac
        [ -n "$name" ] || { err "名称不能为空"; continue; }
        if exit_exists "$name"; then err "出口已存在: $name"; continue; fi
        break
    done

    while :; do
        idx=$((idx + 1))
        subline
        printf '  %s成员 %s%s\n' "$BLUE" "$idx" "$NC"
        st="proto"
        while :; do
            case "$st" in
                proto)
                    printf '\n协议类型（0=返回上一步）：\n'
                    printf '  %s[1]%s Shadowsocks 2022（推荐）\n' "$GREEN" "$NC"
                    printf '  %s[2]%s Shadowsocks（经典版）\n' "$GREEN" "$NC"
                    printf '  %s[0]%s 返回上一步\n' "$YELLOW" "$NC"
                    printf '请输入 [0-2]（回车=1）: '
                    read -r ps || return 0
                    case "$ps" in
                        0)
                            if [ "$idx" -le 1 ]; then
                                info "已取消并删除该节点"; logic_del_node "$name"; return 0
                            fi
                            info "已返回上一步（重新输入节点名称）"
                            logic_del_node "$name"; return 0
                            ;;
                        2) step="ss" ;;
                        *) step="ss2022" ;;
                    esac
                    if [ "$step" = "ss2022" ]; then
                        methods="2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305"
                    else
                        methods="aes-256-gcm aes-192-gcm aes-128-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305"
                    fi
                    st="method"
                    ;;
                method)
                    printf '加密方式（0=返回上一步）：\n'
                    i=1
                    for m in $methods; do printf '  %s[%s]%s %s\n' "$GREEN" "$i" "$NC" "$m"; i=$((i + 1)); done
                    printf '  %s[0]%s 返回上一步\n' "$YELLOW" "$NC"
                    printf '请选择 [0-%s]: ' "$((i - 1))"
                    read -r msel || return 0
                    case "$msel" in
                        0) st="proto"; continue ;;
                        ''|*[!0-9]*) err "请输入数字"; continue ;;
                    esac
                    method="$(printf '%s\n' $methods | sed -n "${msel}p")"
                    [ -n "$method" ] || { err "无效选择"; continue; }
                    st="host"
                    ;;
                host)
                    printf '服务器地址（0=返回上一步）: '; read -r host || return 0
                    [ "$host" = "0" ] && { st="method"; continue; }
                    [ -n "$host" ] || { err "地址不能为空"; continue; }
                    st="port"
                    ;;
                port)
                    printf '端口（0=返回上一步）: '; read -r port || return 0
                    [ "$port" = "0" ] && { st="host"; continue; }
                    case "$port" in ''|*[!0-9]*) err "端口必须是数字"; continue ;; esac
                    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then err "端口范围 1-65535"; continue; fi
                    st="pass"
                    ;;
                pass)
                    printf '密码（0=返回上一步）: '; read -r pass || return 0
                    [ "$pass" = "0" ] && { st="port"; continue; }
                    [ -n "$pass" ] || { err "密码不能为空"; continue; }
                    if [ "$step" = "ss2022" ]; then
                        if np="$(ss2022_pass_check "$method" "$pass")"; then
                            [ "$np" != "$pass" ] && info "已自动补齐 base64 填充：$np"
                            pass="$np"
                        else
                            err "密码不符合 $method 的格式：$np"
                            info "单密钥：16/32 字节的 base64；双密钥：两段 base64 用 : 连接"
                            continue
                        fi
                    fi
                    st="fam"
                    ;;
                fam)
                    if [ "$used4" = "1" ]; then
                        fam="v6"; info "IPv4 槽已被占用，本成员固定为 IPv6"
                    elif [ "$used6" = "1" ]; then
                        fam="v4"; info "IPv6 槽已被占用，本成员固定为 IPv4"
                    else
                        printf '这台机器给节点提供哪种地址（0=返回上一步）?\n'
                        printf '  %s[1]%s IPv4\n' "$GREEN" "$NC"
                        printf '  %s[2]%s IPv6\n' "$GREEN" "$NC"
                        printf '  %s[0]%s 返回上一步\n' "$YELLOW" "$NC"
                        printf '请输入 [0-2]: '; read -r fs || return 0
                        case "$fs" in
                            0) st="pass"; continue ;;
                            2) fam="v6" ;;
                            *) fam="v4" ;;
                        esac
                    fi
                    st="done"
                    ;;
                done) break ;;
            esac
        done
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$name" "$idx" "$step" "$host" "$port" "$method" "$pass" "$fam" >> "$LOGIC_CONF"
        [ "$fam" = "v4" ] && used4=1 || used6=1
        info "已加入成员 $idx（$(proto_label "$step") / $fam / $host:$port）"
        if [ "$fam" = "v6" ] && ! ip -6 route show default 2>/dev/null | grep -q default; then
            warn "本机没有 IPv6 默认路由：这个 v6 成员会连不上（除非以后给宿主机配 IPv6）"
        fi
        if [ "$used4" = "1" ] && [ "$used6" = "1" ]; then
            info "IPv4 与 IPv6 成员都已就绪"; break
        fi
        printf '继续添加另一个家族的成员? [Y/n]: '; read -r a || return 0
        case "$a" in [nN]) break ;; esac
    done

    while :; do
        printf '期望出口 IP（可留空；输入 0 删除整个节点）: '; read -r expect || return 0
        [ "$expect" = "0" ] && { logic_del_node "$name"; info "已取消"; return 0; }
        break
    done
    mark="$(mark_next)"
    printf '%s|logic||0|||%s||||%s|1|\n' "$name" "$mark" "$expect" >> "$EXITS_CONF"
    ok "已新增逻辑节点 $name（mark $mark，成员 $(logic_members "$name" | grep -c .) 个）"
    info "正在下发规则 ..."
    apply_all
    pause_back
}
emit_tproxy6() {
    local name="$1" proto="$2" mark="$7" enable="${12}"
    [ "$enable" = "0" ] && return 0
    [ -n "${BRIDGE6:-}" ] || return 0
    case "$proto" in
        ss|ss2022|logic)
            local port
            port="$(exit_ss_port "$name")"
            echo "        iifname \"$BRIDGE\" meta mark $mark meta l4proto { tcp, udp } ct direction original tproxy ip6 to [$BRIDGE6]:$port meta mark set 0x80000001"
            ;;
    esac
}

emit_tproxy() {
    local name="$1" proto="$2" mark="$7" enable="${12}"
    [ "$enable" = "0" ] && return 0
    case "$proto" in
        ss|ss2022|logic)
            local port
            port="$(exit_ss_port "$name")"
            # ct direction original：只劫持"容器主动发起"的包。
            # 不加这一条，容器作为服务端时（如 vless / hy2），它给客户端回包也会被劫持，
            # 导致外部连接超时。实测踩过。
            # 指定网桥地址：sing-box 只绑网桥，代理端口不暴露到公网，
            # 也不会和用户的端口映射抢 0.0.0.0
            local tpaddr="${SUBNET_GW:-}"
            if [ -n "$tpaddr" ]; then
                echo "        iifname \"$BRIDGE\" meta mark $mark meta l4proto { tcp, udp } ct direction original tproxy ip to $tpaddr:$port meta mark set 0x80000001"
            else
                echo "        iifname \"$BRIDGE\" meta mark $mark meta l4proto { tcp, udp } ct direction original tproxy ip to :$port meta mark set 0x80000001"
            fi
            ;;
    esac
}

gen_wg() {
    local name proto host port wgkey wgif local mark enable table
    exits_each apply_wg_one
}

apply_wg_one() {
    local name="$1" proto="$2" host="$3" port="$4" m="$5" pw="$6" mark="$7" wgkey="$8" wgif="$9" local="${10}" expect="${11}" enable="${12}"
    [ "$proto" = "wg" ] || return 0
    [ "$enable" = "0" ] && return 0
    has_cmd wg || { warn "$name: 未安装 wireguard-tools，跳过"; return 1; }
    [ -n "$wgif" ] || { warn "$name: 缺少 WireGuard 接口名"; return 1; }
    if ! ip link show "$wgif" >/dev/null 2>&1; then
        ip link add dev "$wgif" type wireguard || { warn "$name: 建接口失败"; return 1; }
    fi
    [ -n "$WG_PRIVATE_KEY" ] || { warn "$name: 主配置缺少 WG_PRIVATE_KEY"; return 1; }
    printf '%s' "$WG_PRIVATE_KEY" > "$DATA_DIR/wg.key"
    chmod 600 "$DATA_DIR/wg.key"
    [ -n "$local" ] && ip addr replace "$local" dev "$wgif"
    ip link set mtu 1420 up dev "$wgif"
    # IPv6 端点必须写成 [addr]:port，否则 wg 解析失败
    local ep="$host:$port"
    case "$host" in *:*) ep="[$host]:$port" ;; esac
    wg set "$wgif" private-key "$DATA_DIR/wg.key" peer "$wgkey" endpoint "$ep" allowed-ips 0.0.0.0/0 persistent-keepalive 25
    table="$(wg_table "$name")"
    ip rule del fwmark "$mark" table "$table" 2>/dev/null || true
    ip rule add fwmark "$mark" table "$table" priority "$((1000 + table - 10000))"
    ip route replace default dev "$wgif" table "$table"
    ok "$name: WireGuard 接口 $wgif 就绪（表 $table）"
}

wg_table() {
    local want="$1" l i=0
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        i=$((i + 1))
        [ "${l%%|*}" = "$want" ] && { echo $((10000 + i)); return 0; }
    done < "$EXITS_CONF"
    echo 10999
}

ensure_wg_key() {
    local k pub a
    [ -n "$WG_PRIVATE_KEY" ] && return 0
    has_cmd wg || { err "需要先安装 wireguard-tools（菜单 15 -> 2）"; return 1; }
    printf ' 尚未生成宿主机 WireGuard 私钥，现在生成? [Y/n]: '
    read -r a || return 0
    case "$a" in [nN]) err "已取消"; return 1 ;; esac
    k="$(wg genkey 2>/dev/null)"
    [ -n "$k" ] || { err "生成失败"; return 1; }
    pub="$(printf '%s' "$k" | wg pubkey 2>/dev/null)"
    save_main_var WG_PRIVATE_KEY "$k"
    WG_PRIVATE_KEY="$k"
    ok "已生成并保存宿主机 WireGuard 私钥"
    printf ' %s宿主机公钥%s（填进出口机 wg 配置的 [Peer] PublicKey）:\n  %s%s%s\n' "$BLUE" "$NC" "$GREEN" "$pub" "$NC"
}

b64_pad() {
    # 给 base64 补齐 "=" 填充（用户复制时常漏掉），返回补齐后的串
    local s="$1" m
    [ -n "$s" ] || return 1
    case "$s" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
    case "$s" in
        *=*)
            # 已经带填充：长度必须是 4 的倍数，否则非法（不能再补 "="）
            [ $(( ${#s} % 4 )) -eq 0 ] && printf '%s' "$s" || return 1
            return 0
            ;;
    esac
    m=$(( ${#s} % 4 ))
    case "$m" in
        0) printf '%s' "$s" ;;
        2) printf '%s==' "$s" ;;
        3) printf '%s=' "$s" ;;
        *) return 1 ;;
    esac
}

b64_bytes() {
    # base64 解码后的字节数；解码失败（含填充不全）返回 0
    local s="$1" n rc
    [ -n "$s" ] || { echo 0; return; }
    case "$s" in *[!A-Za-z0-9+/=]*) echo 0; return ;; esac
    s="$(b64_pad "$s")" || { echo 0; return; }
    if has_cmd base64; then
        n="$(printf '%s' "$s" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
        rc=${PIPESTATUS[1]:-0}
        # 注意：base64 -d 失败时也可能吐出半截字节，必须用退出码判断
        if ! printf '%s' "$s" | base64 -d >/dev/null 2>&1; then
            echo 0; return
        fi
        echo "${n:-0}"
    else
        case "${#s}" in
            24) echo 16 ;;
            44) echo 32 ;;
            *) echo 0 ;;
        esac
    fi
}

ss2022_pass_check() {  # $1=method $2=password
    # 成功：stdout 输出**补齐填充后的密码**（可直接入库），返回 0
    # 失败：stdout 输出原因，返回 1
    # 支持：单密钥 base64 / 双密钥 base64:base64（两侧都按算法长度校验）
    local method="$1" pass="$2" want k1 k2 p1 p2 b1 b2
    case "$method" in
        2022-blake3-aes-128-gcm|2022-blake3-chacha20-poly1305) want=16 ;;
        2022-blake3-aes-256-gcm) want=32 ;;
        *) printf '%s' "$pass"; return 0 ;;
    esac
    case "$pass" in
        *:*)
            k1="${pass%%:*}"; k2="${pass#*:}"
            p1="$(b64_pad "$k1")" || { echo "双密钥左侧不是合法 base64"; return 1; }
            p2="$(b64_pad "$k2")" || { echo "双密钥右侧不是合法 base64"; return 1; }
            b1="$(b64_bytes "$p1")"; b2="$(b64_bytes "$p2")"
            if [ "$b1" = "$want" ] && [ "$b2" = "$want" ]; then printf '%s:%s' "$p1" "$p2"; return 0; fi
            echo "双密钥要求冒号两侧各 ${want} 字节 base64（当前 ${b1}/${b2} 字节）"
            return 1
            ;;
        *)
            p1="$(b64_pad "$pass")" || { echo "不是合法的 base64 密钥"; return 1; }
            b1="$(b64_bytes "$p1")"
            if [ "$b1" = "$want" ]; then printf '%s' "$p1"; return 0; fi
            echo "该算法要求 ${want} 字节 base64 密钥（当前 ${b1} 字节）"
            return 1
            ;;
    esac
}

ss_classic_pass_check() {  # $1=password
    local pass="$1"
    [ -n "$pass" ] || { echo "密码不能为空"; return 1; }
    echo ok
    return 0
}

proto_label() {
    case "$1" in
        ss2022) echo "Shadowsocks 2022" ;;
        ss)     echo "Shadowsocks" ;;
        wg)     echo "WireGuard" ;;
        logic)  echo "逻辑节点" ;;
        *)      echo "$1" ;;
    esac
}

conf_backup() {
    # 每次下发前留一份配置快照，出问题能回滚（只保留最近 10 份）
    local d f
    d="$DATA_DIR/backup/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$d" 2>/dev/null || return 0
    for f in "$EXITS_CONF" "$BIND_CONF" "$CLIENT_ALLOW_CONF" "$CLIENT_DENY_CONF" "$LOGIC_CONF" "$MAIN_CONF"; do
        [ -f "$f" ] && cp -f "$f" "$d/" 2>/dev/null
    done
    chmod 600 "$d"/* 2>/dev/null || true
    ls -1dt "$DATA_DIR/backup"/* 2>/dev/null | tail -n +11 | while IFS= read -r x; do rm -rf "$x"; done
    return 0
}

json_esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

mark_next() {
    # 从 0x1001 起找第一个未被占用的 mark
    local i=1 m
    while [ "$i" -le 4000 ]; do
        m="$(printf '0x%x' $((0x1000 + i)))"
        grep -q "|$m|" "$EXITS_CONF" 2>/dev/null || { echo "$m"; return 0; }
        i=$((i + 1))
    done
    echo "0x1fff"
}

port_owner() {  # 输出占用该端口的进程名（tsv），空闲则输出空
    ss -lntupH 2>/dev/null | awk -v p=":$1\$" '$5 ~ p {print $1" "$7; exit}'
}

tproxy_port_conflicts() {  # 列出代理端口段里被"非 sing-box"占用的端口
    ss -lntupH 2>/dev/null | awk -v lo="$TPROXY_BASE" -v hi="$((TPROXY_BASE + 99))" '
        {
            p = $5; sub(/.*:/, "", p); if (p + 0 < lo || p + 0 > hi) next
            if ($7 !~ /sing-box/) print p
        }' | sort -un | tr '\n' ' '
}

ss_enabled_count() {
    local n=0 l name proto a1 a2 a3 a4 a5 a6 a7 a8 a9 enable a10 a11
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS="|" read -r name proto a1 a2 a3 a4 a5 a6 a7 a8 a9 enable a10 a11 <<< "$l"
        case "$proto" in
            ss|ss2022|logic) [ "${enable:-1}" != "0" ] && n=$((n + 1)) ;;
        esac
    done < "$EXITS_CONF"
    echo "$n"
}

tproxy_routing_on() {
    ip rule del fwmark 0x80000001 lookup 1001 2>/dev/null || true
    ip rule add fwmark 0x80000001 lookup 1001 priority 900 2>/dev/null || true
    ip route replace local 0.0.0.0/0 dev lo table 1001 2>/dev/null || true
    # IPv6：网桥有 v6 时才建 v6 的 tproxy 回环路由
    if [ -n "$(bridge_ipv6 2>/dev/null)" ]; then
        ip -6 rule del fwmark 0x80000001 lookup 1001 2>/dev/null || true
        ip -6 rule add fwmark 0x80000001 lookup 1001 priority 900 2>/dev/null || true
        ip -6 route replace local ::/0 dev lo table 1001 2>/dev/null || true
    else
        # 网桥没有 IPv6 时把残留的 v6 策略路由清掉
        ip -6 rule del fwmark 0x80000001 lookup 1001 2>/dev/null || true
        ip -6 route flush table 1001 2>/dev/null || true
    fi
}

tproxy_routing_off() {
    ip rule del fwmark 0x80000001 lookup 1001 2>/dev/null || true
    ip route flush table 1001 2>/dev/null || true
    ip -6 rule del fwmark 0x80000001 lookup 1001 2>/dev/null || true
    ip -6 route flush table 1001 2>/dev/null || true
}

ensure_tproxy_sysctl() {
    local cur cur6
    cur="$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo 1)"
    cur6="$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null || echo 1)"
    if [ "$cur" != "0" ] || [ "$cur6" != "0" ]; then
        printf '%s\n' '# Incus MultiRoute：TPROXY 需要关闭 br_netfilter 对桥接帧的劫持' \
            'net.bridge.bridge-nf-call-iptables = 0' \
            'net.bridge.bridge-nf-call-ip6tables = 0' > /etc/sysctl.d/90-incus-multiroute.conf
        sysctl -qw net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
        sysctl -qw net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true
        warn "已关闭 net.bridge.bridge-nf-call-iptables（容器间二层流量不再经过防火墙）"
    fi
}

remove_tproxy_sysctl() {
    rm -f /etc/sysctl.d/90-incus-multiroute.conf
    sysctl -qw net.bridge.bridge-nf-call-iptables=1 2>/dev/null || true
    sysctl -qw net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
}

apply_ss_units() {
    local force="${1:-0}"
    local name proto host port method pass enable l cmd host6
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto host port method pass mark wgkey wgif local expect enable lp host6 <<< "$l"
        case "$proto" in ss|ss2022|logic) ;; *) continue ;; esac
        local u="mr-ss-$mark.service"
        if [ "$enable" = "0" ]; then
            systemctl disable --now "$u" >/dev/null 2>&1 || true
            continue
        fi
        local lport
        if ! lport="$(exit_ss_port "$name")" || [ -z "$lport" ]; then
            warn "$name: 没有可用端口（端口段 $TPROXY_BASE-$((TPROXY_BASE + 99)) 已用尽）"
            continue
        fi
        local owner
        owner="$(port_owner "$lport" 2>/dev/null)"
        case "$owner" in
            *sing-box*) ;;
            "") ;;
            *) warn "$name: 端口 $lport 已被占用（$owner），该出口可能启动失败" ;;
        esac
        # sing-box：tproxy 入站（TCP+UDP），shadowsocks 出站
        local newcfg newunit
        if [ "$proto" = "logic" ]; then
            newcfg="$(logic_cfg_json "$name" "$lport")"
        elif [ -n "${host6:-}" ] && { [ "$proto" = "ss" ] || [ "$proto" = "ss2022" ]; }; then
            # 双隧道分流：v4 目标走 v4 隧道、v6 目标走 v6 隧道
            newcfg="$(split_cfg_json "$lport" "$host" "$host6" "$port" "$method" "$pass")"
        else
        local inb v6in
        inb="$(printf '{"type":"tproxy","tag":"tproxy-in","listen":"%s","listen_port":%s,"network":["tcp","udp"]}' \
            "$(json_esc "${SUBNET_GW:-0.0.0.0}")" "$lport")"
        v6in=""
        if [ -n "$(bridge_ipv6 2>/dev/null)" ]; then
            v6in=",$(printf '{"type":"tproxy","tag":"tproxy-in6","listen":"%s","listen_port":%s,"network":["tcp","udp"]}' \
                "$(json_esc "$(bridge_ipv6)")" "$lport")"
        fi
        newcfg="$(cat <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [$inb$v6in],
  "outbounds": [{
    "type": "shadowsocks", "tag": "ss",
    "server": "$(json_esc "$host")",
    "server_port": $port,
    "method": "$(json_esc "$method")",
    "password": "$(json_esc "$pass")"
  }]
}
EOF
)"
        fi
        newunit="$(cat <<EOF
[Unit]
Description=Incus MultiRoute sing-box ($name)
After=network-online.target incus.service
Wants=network-online.target
Wants=incus.service

[Service]
Type=simple
ExecStart=$SINGBOX_BIN run -c "$SS_DIR/$mark.json"
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
)"
        # 只有配置真的变了才重启：新增/删除/停用出口时，不能打断其它出口的连接
        local changed=1 desc_only=0
        if [ -f "$SS_DIR/$mark.json" ] && [ -f "$UNIT_DIR/$u" ] \
            && [ "$newcfg" = "$(cat "$SS_DIR/$mark.json")" ] \
            && [ "$newunit" = "$(cat "$UNIT_DIR/$u")" ]; then
            changed=0
        fi
        # 只改了出口名称时：单元内容只差 Description 一行，更新描述即可，不重启（不断用户连接）
        if [ "$changed" = "1" ] && [ -f "$SS_DIR/$mark.json" ] && [ -f "$UNIT_DIR/$u" ] \
            && [ "$newcfg" = "$(cat "$SS_DIR/$mark.json")" ] \
            && [ "$(grep -v '^Description=' <<< "$newunit")" = "$(grep -v '^Description=' "$UNIT_DIR/$u")" ]; then
            desc_only=1
            changed=0
        fi
        if [ "$desc_only" = "1" ]; then
            printf '%s\n' "$newunit" > "$UNIT_DIR/$u"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        if [ "$changed" = "1" ]; then
            printf '%s\n' "$newcfg" > "$SS_DIR/$mark.json"
            printf '%s\n' "$newunit" > "$UNIT_DIR/$u"
            chmod 600 "$SS_DIR/$mark.json"
        fi
        if [ "$changed" = "1" ] || [ "$force" = "1" ] || ! systemctl is-active --quiet "$u" 2>/dev/null; then
            systemctl daemon-reload
            systemctl enable "$u" >/dev/null 2>&1 || true
            systemctl restart "$u" >/dev/null 2>&1 || warn "$name: sing-box 启动失败，看 journalctl -u $u"
        fi
    done < "$EXITS_CONF"
    local f n
    for f in "$UNIT_DIR"/mr-ss-*.service; do
        [ -e "$f" ] || continue
        n="$(basename "$f" .service)"
        n="${n#mr-ss-}"
        if ! grep -q "|$n|" "$EXITS_CONF" 2>/dev/null; then
            systemctl disable --now "mr-ss-$n.service" >/dev/null 2>&1 || true
            rm -f "$f"
            # 同时删掉该出口遗留的 sing-box 配置，避免残留 mark 对应的 JSON 堆着
            rm -f "$SS_DIR/$n.json"
            info "已清理失效单元: mr-ss-$n.service"
        fi
    done
}

ensure_boot_unit() {
    # nft 规则是运行时状态，重启即丢；用一个 oneshot 单元在开机时重新下发
    cat > "$UNIT_DIR/mr-restore.service" <<EOF
[Unit]
Description=Incus MultiRoute 开机恢复出口规则
After=network-online.target incus.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mr apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl enable mr-restore >/dev/null 2>&1; then
        info "已启用开机自动恢复（mr-restore.service）"
    else
        warn "开机自动恢复单元启用失败"
    fi
}

apply_nft_only() {
    # 只重建 nft 表：绑定关系变化时用这个，不重启 sing-box，
    # 避免"一个人切换出口，所有人的连接都被打断"
    load_conf
    require_root
    gen_nft
    sed 's/^table inet multiroute {/table inet multiroute_chk {/' "$NFT_FILE" > "$NFT_FILE.chk" 2>/dev/null
    if ! nft -c -f "$NFT_FILE.chk" 2>/tmp/mr.nft.err; then
        err "生成的 nft 规则不合法，已保留现有规则不动"
        sed -n '1,5p' /tmp/mr.nft.err >&2
        rm -f /tmp/mr.nft.err
        return 1
    fi
    rm -f /tmp/mr.nft.err "$NFT_FILE.chk"
    nft delete table inet multiroute 2>/dev/null || true
    nft -f "$NFT_FILE" || return 1
    if [ "$(ss_enabled_count)" -gt 0 ]; then
        ensure_tproxy_sysctl
        tproxy_routing_on
    else
        tproxy_routing_off
        [ -f /etc/sysctl.d/90-incus-multiroute.conf ] && remove_tproxy_sysctl
    fi
    return 0
}

apply_all() {
    local force="${1:-0}"
    load_conf
    require_root
    conf_backup
    title "下发规则"
    apply_nft_only || { err "nft 下发失败"; pause_back; return 1; }
    ok "nft 规则已加载"
    gen_wg
    apply_ss_units "$force"
    # 只做最小必要改动：ip_forward 本就是 incus 要求开启的；
    # rp_filter 仅在严格模式(1)时放宽为宽松(2)，已经是 0 或 2 就完全不去动它。
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    if [ "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)" = "1" ]; then
        sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 && info "rp_filter: 1 -> 2（策略路由必需，仅在严格模式时调整）"
    fi
    [ "$(ss_enabled_count)" -gt 0 ] && ok "透明代理已就绪（TCP+UDP tproxy）"
    ensure_boot_unit
    ok "全部下发完成"
}

# ---------------------------------------------------------------- 用户端 out

client_hash_base() {
    [ -f "$CLIENT_BASE" ] || return 1
    sha256sum "$CLIENT_BASE" | awk '{print $1}'
}

client_inject_api_url() {
    # 把用户端脚本里的默认 API 地址换成本机网桥网关，容器才能连上宿主 API
    [ -f "$CLIENT_BASE" ] || return 1
    local gw
    gw="${SUBNET_GW:-}"
    [ -n "$gw" ] || gw="$(detect_gateway)"
    [ -n "$gw" ] || { warn "未探测到网桥网关，用户端 API 地址保持原样"; return 1; }
    sed -i -E "s|[0-9]{1,3}(\.[0-9]{1,3}){3}:18988|$gw:18988|g" "$CLIENT_BASE"
    info "用户端 API 地址已指向 $gw:18988"
}

client_hash_in() {
    local name="$1"
    incus exec "$name" -- sh -c 'sha256sum /usr/local/bin/out 2>/dev/null | cut -d" " -f1' </dev/null 2>/dev/null | tr -d '\r' | head -1
}

token_of() {
    local name="$1"
    awk -F'|' -v n="$name" '$1==n {print $2; exit}' "$TOKEN_CONF" 2>/dev/null
}

token_new() {
    local name="$1" t
    t="$(head -c 24 /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-32)"
    awk -F'|' -v n="$name" '$1!=n' "$TOKEN_CONF" > "$TOKEN_CONF.tmp" 2>/dev/null || :
    printf '%s|%s\n' "$name" "$t" >> "$TOKEN_CONF.tmp"
    mv -f "$TOKEN_CONF.tmp" "$TOKEN_CONF"
    chmod 600 "$TOKEN_CONF"
    echo "$t"
}

# ---------------------------------------------------------------- 用户授权

allowed_list() {
    [ -f "$CLIENT_ALLOW_CONF" ] || return 0
    grep -v '^#' "$CLIENT_ALLOW_CONF" 2>/dev/null | awk -F'|' '$1!="" {print $1}'
}

client_allowed() {
    [ -f "$CLIENT_ALLOW_CONF" ] || return 1
    awk -v n="$1" '!/^#/ && $1==n {f=1} END{exit(f?0:1)}' "$CLIENT_ALLOW_CONF" 2>/dev/null
}

allowed_count() {
    allowed_list | grep -c . || true
}

client_denied() {
    [ -f "$CLIENT_DENY_CONF" ] && grep -qx "$1" "$CLIENT_DENY_CONF"
}

deny_add()    { [ -f "$CLIENT_DENY_CONF" ] || : > "$CLIENT_DENY_CONF"; grep -qx "$1" "$CLIENT_DENY_CONF" || printf '%s\n' "$1" >> "$CLIENT_DENY_CONF"; }
deny_remove() { [ -f "$CLIENT_DENY_CONF" ] || return 0; grep -vx "$1" "$CLIENT_DENY_CONF" > "$CLIENT_DENY_CONF.tmp" 2>/dev/null || :; mv -f "$CLIENT_DENY_CONF.tmp" "$CLIENT_DENY_CONF"; }

client_enroll_quiet() {
    # 静默授权 + 下发：给定时器用，不打印菜单、不 pause
    local name="$1"
    client_allowed "$name" || printf '%s\n' "$name" >> "$CLIENT_ALLOW_CONF"
    bind_get "$name" >/dev/null 2>&1 || bind_clear "$name" >/dev/null 2>&1
    client_push_one "$name" >/dev/null 2>&1
}

auto_enroll_new() {
    # AUTO_GRANT=1 时，把还没授权的新容器自动授权并下发 out
    [ "${AUTO_GRANT:-0}" = "1" ] || return 0
    local c n=0
    # 只处理运行中的容器：停机的推不进去，等它起来下一轮再纳管
    for c in $(incus list --format=csv -c ns 2>/dev/null | awk -F, '$2=="RUNNING"{print $1}'); do
        [ -n "$c" ] || continue
        client_allowed "$c" && continue
        client_denied "$c" && continue
        client_enroll_quiet "$c"
        n=$((n + 1))
        echo "$(date '+%F %T') 自动授权并下发: $c" >> "$DATA_DIR/sync.log"
        if [ "${AUTO_HARDEN:-0}" = "1" ]; then
            sec_apply_one "$c" 1 >/dev/null 2>&1 && echo "$(date '+%F %T') 自动加固: $c" >> "$DATA_DIR/sync.log"
        fi
    done
    [ "$n" -gt 0 ] && info "自动授权了新容器 $n 个"
    return 0
}

client_grant() {
    local name="$1"
    [ -n "$name" ] || { err "用法: client_grant 容器名"; return 1; }
    client_allowed "$name" || printf '%s\n' "$name" >> "$CLIENT_ALLOW_CONF"
    deny_remove "$name"
    ok "$name 已授权使用 out"
    # 关键：API 靠 bindings.conf 的 IP→容器名 识别来源，没有这行就一律 403
    if ! bind_get "$name" >/dev/null 2>&1; then
        bind_clear "$name" >/dev/null 2>&1
        info "已为 $name 建立身份记录（当前：入口机直出），它现在可以自己切换出口"
    fi
    client_push_one "$name"
    pause_back
}

client_revoke() {
    local name="$1"
    [ -n "$name" ] || { err "用法: client_revoke 容器名"; return 1; }
    if [ -f "$CLIENT_ALLOW_CONF" ]; then
        grep -vx "$name" "$CLIENT_ALLOW_CONF" > "$CLIENT_ALLOW_CONF.tmp" 2>/dev/null || :
        mv -f "$CLIENT_ALLOW_CONF.tmp" "$CLIENT_ALLOW_CONF"
    fi
    incus exec "$name" -- sh -c 'rm -f /usr/local/bin/out /etc/incus-egress-token' </dev/null >/dev/null 2>&1 || true
    bind_remove "$name" >/dev/null 2>&1 || true
    [ "${AUTO_GRANT:-0}" = "1" ] && deny_add "$name"
    ok "$name 已撤销授权，容器内 out 与令牌已移除，绑定已清除"
    pause_back
}

client_grant_all() {
    local names n c cnt=0 preview
    names="$(containers_scan 2>/dev/null | cut -f1)"
    n="$(printf '%s\n' "$names" | grep -c . || true)"
    title "全部授权并下发"
    [ "$n" -gt 0 ] || { warn "没有可用容器"; pause_back; return 1; }
    preview="$(printf '%s\n' "$names" | head -6 | tr '\n' ' ')"
    warn "将给全部 $n 个容器授权使用 out，并逐个推送脚本与令牌"
    info "容器: $preview$([ "$n" -gt 6 ] && echo '...')"
    subline
    printf ' 输入 yes 继续，其它任意键取消: '
    read -r a || return 0
    case "$a" in
        [yY][eE][sS]) ;;
        *) info "已取消，未做任何改动"; pause_back; return 0 ;;
    esac
    for c in $names; do
        client_allowed "$c" || printf '%s\n' "$c" >> "$CLIENT_ALLOW_CONF"
        deny_remove "$c"
        bind_get "$c" >/dev/null 2>&1 || bind_clear "$c" >/dev/null 2>&1
        client_push_one "$c" >/dev/null 2>&1 && cnt=$((cnt + 1))
    done
    subline
    ok "已授权并下发 $cnt / $n 个容器"
    pause_back
}

client_revoke_all() {
    local list n c cnt=0
    list="$(allowed_list)"
    n="$(printf '%s\n' "$list" | grep -c . || true)"
    title "全部撤销授权并回收"
    if [ "$n" = "0" ]; then
        info "当前没有任何已授权用户，无需回收"
        pause_back
        return 0
    fi
    warn "将撤销全部 $n 个用户的授权，并从这些容器内删除 out 与令牌"
    info "名单: $(printf '%s ' $list)"
    subline
    printf ' 输入 yes 继续，其它任意键取消: '
    read -r a || return 0
    case "$a" in
        [yY][eE][sS]) ;;
        *) info "已取消，未做任何改动"; pause_back; return 0 ;;
    esac
    for c in $list; do
        incus exec "$c" -- sh -c 'rm -f /usr/local/bin/out /etc/incus-egress-token' </dev/null >/dev/null 2>&1 && cnt=$((cnt + 1))
        bind_remove "$c" >/dev/null 2>&1 || true
        # 开启自动授权时，被撤销的必须进黑名单，否则下一轮又被自动加回来
        [ "${AUTO_GRANT:-0}" = "1" ] && deny_add "$c"
    done
    printf '%s\n' '# 授权使用 out 的容器，一行一个；不在本表的容器永远不会被下发' > "$CLIENT_ALLOW_CONF"
    apply_nft_only >/dev/null 2>&1 || true
    subline
    ok "已回收 $cnt / $n 个容器，白名单已清空"
    pause_back
}

client_push_one() {
    local name="$1" tok tmp
    [ -f "$CLIENT_BASE" ] || { err "缺少基准脚本 $CLIENT_BASE（先在菜单 14 安装本脚本）"; return 1; }
    incus file push "$CLIENT_BASE" "$name/usr/local/bin/out" --mode 0755 --create-dirs >/dev/null 2>&1 || {
        err "$name: 推送 out 失败"; return 1; }
    tok="$(token_of "$name")"
    [ -n "$tok" ] || tok="$(token_new "$name")"
    tmp="$(mktemp)"
    printf '%s' "$tok" > "$tmp"
    incus file push "$tmp" "$name/etc/incus-egress-token" --mode 0600 --create-dirs >/dev/null 2>&1 || {
        err "$name: 推送令牌失败"; rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    ok "$name: out 与令牌已下发"
}

client_status() {
    local base n h st
    base="$(client_hash_base 2>/dev/null || true)"
    title "用户端 out 同步状态"
    [ -n "$base" ] || { err "缺少基准脚本 $CLIENT_BASE"; pause_back; return 1; }
    info "基准哈希: $base"
    info "已授权用户: $(allowed_count) 个 —— 未授权用户永远不会被下发"
    subline
    printf '  %-20s %-16s %-6s %s\n' "容器" "IPv4" "授权" "状态"
    containers_scan 2>/dev/null | while IFS=$'\t' read -r n ip; do
        [ -n "$n" ] || continue
        if client_allowed "$n"; then
            h="$(client_hash_in "$n")"
            if [ -z "$h" ]; then st="${RED}缺失${NC}"
            elif [ "$h" = "$base" ]; then st="${GREEN}一致${NC}"
            else st="${YELLOW}版本不一致${NC}"; fi
            printf '  %-20s %-16s %-6s %b\n' "$n" "$ip" "${GREEN}是${NC}" "$st"
        else
            printf '  %-20s %-16s %-6s %s\n' "$n" "$ip" "${YELLOW}否${NC}" "未下发"
        fi
    done
    subline
    info "共 $(containers_scan 2>/dev/null | wc -l | tr -d ' ') 个容器，其中 $(allowed_count) 个已授权"
}

client_sync() {
    local quiet="${1:-}" base n h pushed=0 tot=0
    clients_prune >/dev/null 2>&1 || true
    auto_enroll_new
    base="$(client_hash_base 2>/dev/null || true)"
    [ -n "$base" ] || { [ -n "$quiet" ] || err "缺少基准脚本 $CLIENT_BASE"; return 1; }
    tot="$(allowed_count)"
    if [ "$tot" = "0" ]; then
        if [ -n "$quiet" ]; then
            return 0
        fi
        title "下发用户端 out"
        warn "当前没有任何已授权用户，未做任何下发"
        info "如需给某用户开通：菜单 [10] -> [3] 授权并下发"
        pause_back
        return 0
    fi
    local c failed="" gone=""
    local existing
    existing="$(incus list --format=csv -c n </dev/null 2>/dev/null | tr -d '"' | tr '\n' ' ')"
    for c in $(allowed_list); do
        case " $existing " in
            *" $c "*) ;;
            *) gone="$gone $c"; continue ;;
        esac
        h="$(client_hash_in "$c")"
        if [ "$h" != "$base" ]; then
            if client_push_one "$c" >/dev/null 2>&1; then
                pushed=$((pushed + 1))
            else
                failed="$failed $c"
            fi
        fi
    done
    if [ -n "$quiet" ]; then
        if [ "$pushed" -gt 0 ] || [ -n "$failed" ]; then
            echo "$(date '+%F %T') 已同步 $pushed/$tot 个已授权容器${failed:+；失败:$failed}" >> "$DATA_DIR/sync.log"
        fi
    else
        title "下发用户端 out"
        ok "已授权 $tot 个容器，本次推送 $pushed 个"
        [ -n "$failed" ] && warn "推送失败:$failed（容器可能已停）"
        [ -n "$gone" ] && warn "授权表里有已不存在的容器:$gone（可用 [3] 撤销）"
        pause_back
    fi
}

sync_timer_on() {
    local m
    if [ "$(allowed_count)" = "0" ]; then
        warn "尚未授权任何用户，定时器开启后也不会有任何下发动作"
    fi
    info "当前间隔: $(sync_timer_interval)"
    printf ' 请输入校验间隔（分钟，最小 5，直接回车用 10）: '
    read -r m || return 0
    case "$m" in
        ""|0) m=10 ;;
        *[!0-9]*) err "请输入数字"; return 1 ;;
    esac
    if [ "$m" -lt 5 ]; then
        warn "不能低于 5 分钟，已按 5 分钟设置"
        m=5
    fi
    cat > "$UNIT_DIR/mr-sync.service" <<EOF
[Unit]
Description=Incus MultiRoute 用户端 out 校验下发

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mr sync
EOF
    cat > "$UNIT_DIR/mr-sync.timer" <<EOF
[Unit]
Description=每 10 分钟校验用户端 out

[Timer]
OnBootSec=2min
OnUnitActiveSec=${m}min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    printf ' 是否自动授权并下发「新创建的容器」? [Y/n]: '
    read -r ag || return 0
    case "$ag" in
        [nN]) save_main_var AUTO_GRANT 0; AUTO_GRANT=0; info "已关闭自动授权：新容器需要手动 [2] 授权" ;;
        *)    save_main_var AUTO_GRANT 1; AUTO_GRANT=1; ok "已开启自动授权：定时器每次运行都会把新容器纳管并下发 out" ;;
    esac
    systemctl daemon-reload
    systemctl enable --now mr-sync.timer >/dev/null 2>&1
    systemctl restart mr-sync.timer >/dev/null 2>&1 || true
    ok "自动校验定时器已启用（每 $m 分钟）"
}

sync_timer_interval() {
    local v
    v="$(sed -n 's/^OnUnitActiveSec=//p' "$UNIT_DIR/mr-sync.timer" 2>/dev/null | head -1)"
    [ -n "$v" ] && printf '每 %s' "$v" || printf '未设置'
}

sync_timer_off() {
    systemctl disable --now mr-sync.timer >/dev/null 2>&1 || true
    ok "自动校验定时器已停用"
}

sync_timer_state() {
    if systemctl is-active --quiet mr-sync.timer 2>/dev/null; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

# ---------------------------------------------------------------- 组件环境

wg_installed()      { has_cmd wg; }
singbox_installed() { [ -x "$SINGBOX_BIN" ]; }

singbox_probe() {
    # 检查某个 sing-box 二进制能不能跑我们的配置（tproxy 入站 + ss2022 出站）
    local bin="$1" tmp rc
    [ -x "$bin" ] || return 1
    tmp="$(mktemp /tmp/sbprobe.XXXXXX.json)"
    cat > "$tmp" <<'JSON'
{
  "log": { "level": "error" },
  "inbounds": [{ "type": "tproxy", "tag": "t", "listen": "127.0.0.1", "listen_port": 46001, "network": ["tcp", "udp"] }],
  "outbounds": [{ "type": "shadowsocks", "tag": "s", "server": "127.0.0.1", "server_port": 1,
                  "method": "2022-blake3-aes-128-gcm", "password": "AAAAAAAAAAAAAAAAAAAAAA==" }]
}
JSON
    "$bin" check -c "$tmp" >/dev/null 2>&1
    rc=$?
    rm -f "$tmp"
    return $rc
}


wg_iface_count() {
    ip -o link show type wireguard 2>/dev/null | wc -l | tr -d ' '
}

ss_active_units() {
    systemctl list-units 'mr-ss-*.service' --state=running --no-legend --no-pager 2>/dev/null | wc -l | tr -d ' '
}

comp_line() {
    local wg_badge ss_badge ss_n
    if wg_installed; then wg_badge="${GREEN}已安装${NC}"; else wg_badge="${RED}未安装${NC}"; fi
    if singbox_installed; then ss_badge="${GREEN}已安装${NC}"; else ss_badge="${RED}未安装${NC}"; fi
    ss_n="$(ss_active_units)"
    printf '  %swireguard-tools%s %b   %ssing-box%s %b（运行中 %s 个出口）\n' "$BLUE" "$NC" "$wg_badge" "$BLUE" "$NC" "$ss_badge" "$ss_n"
}

install_wireguard() {
    if wg_installed; then
        ok "wireguard-tools 已安装（$(wg --version 2>/dev/null | head -1)），跳过"
        return 0
    fi
    info "安装 wireguard-tools ..."
    apt-get update -qq >/dev/null 2>&1 || true
    if apt-get install -y wireguard-tools >/dev/null 2>&1; then
        wg_installed && { ok "wireguard-tools 安装完成"; return 0; }
    fi
    err "wireguard-tools 安装失败，请手动执行: apt-get install -y wireguard-tools"
    return 1
}

install_singbox() {
    local arch url tmp bin ver
    if singbox_installed; then
        ok "本项目的 sing-box 已安装（$("$SINGBOX_BIN" version 2>/dev/null | head -1)），跳过"
        return 0
    fi
    # 说明：本项目始终使用自己的一份（固定路径），不与系统里其它 sing-box 共用，
    # 避免对方升级/覆写把我们的出口带崩
    local other
    other="$(command -v sing-box 2>/dev/null || true)"
    if [ -n "$other" ] && [ "$other" != "$SINGBOX_BIN" ]; then
        info "系统里另有 sing-box: $other（那是别的程序的，本项目不共用）"
    fi
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) err "不支持的架构: $(uname -m)"; return 1 ;;
    esac
    # 优先用 releases/latest 的重定向取版本号：不走 API，避免 60 次/小时的限流
    local tag ver
    tag="$(curl -sIL --max-time 25 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
        | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p' | head -1)"
    if [ -n "$tag" ]; then
        ver="${tag#v}"
        url="https://github.com/SagerNet/sing-box/releases/download/$tag/sing-box-$ver-linux-$arch.tar.gz"
    else
        # 兜底：走 API
        has_cmd jq || { err "需要 jq 才能解析 release 列表"; return 1; }
        url="$(curl -s --max-time 25 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
            | jq -r '.assets[].browser_download_url' 2>/dev/null | grep -m1 "linux-$arch.tar.gz" || true)"
    fi
    [ -n "$url" ] || { err "未取到 sing-box 下载地址（网络受限？）"; return 1; }
    info "下载 $url ..."
    tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 180 -o "$tmp/sb.tar.gz" "$url"; then
        err "下载失败"; rm -rf "$tmp"; return 1
    fi
    tar -xzf "$tmp/sb.tar.gz" -C "$tmp" >/dev/null 2>&1
    bin="$(find "$tmp" -maxdepth 3 -type f -name sing-box | head -1)"
    if [ -z "$bin" ]; then
        err "压缩包里没找到 sing-box"; rm -rf "$tmp"; return 1
    fi
    install -m 755 "$bin" "$SINGBOX_BIN"
    rm -rf "$tmp"
    ver="$("$SINGBOX_BIN" version 2>/dev/null | head -1)"
    if [ -z "$ver" ]; then
        err "sing-box 安装后无法运行"; return 1
    fi
    if singbox_probe "$SINGBOX_BIN"; then
        ok "sing-box 安装完成（$ver），兼容性自检通过（tproxy + Shadowsocks 2022）"
    else
        warn "sing-box 已安装（$ver），但兼容性自检未通过：可能不支持 tproxy 或 Shadowsocks 2022"
        info "请换一个官方 release 版本，或手动验证: $SINGBOX_BIN check"
    fi
}

nftables_guard() {
    # apt 装 nftables 会顺带启用 nftables.service，而 Debian/Ubuntu 默认的
    # /etc/nftables.conf 里有一句 flush ruleset —— 下次开机会把 incus 和
    # 面板的所有表全部冲掉（端口映射集体失效）。这里做一次显式保护。
    [ -f /etc/nftables.conf ] || return 0
    grep -q '^flush ruleset' /etc/nftables.conf 2>/dev/null || return 0
    systemctl is-enabled --quiet nftables 2>/dev/null || return 0
    warn "检测到 nftables.service 已启用，且 /etc/nftables.conf 含 flush ruleset"
    info "开机时它会清空 incus / 面板的全部 nft 表 —— 端口映射会集体失效"
    printf ' 是否停用 nftables.service? [Y/n]: '
    read -r a || return 0
    case "$a" in
        [nN]) info "已保留，请自行确认风险" ;;
        *) systemctl disable --now nftables >/dev/null 2>&1 && ok "已停用 nftables.service（规则仍由 incus 与各面板自己管理）" ;;
    esac
}

install_base() {
    local pkgs="nftables iproute2 curl jq python3 ca-certificates" p miss=""
    title "基础套件"
    info "只做 apt 安装与检测：不重启 nftables 服务、不执行 flush、不触碰任何现有表"
    subline
    for p in $pkgs; do
        if dpkg -s "$p" >/dev/null 2>&1; then
            printf '  %s[跳过]%s %-16s 已安装\n' "$GREEN" "$NC" "$p"
        else
            printf '  %s[安装]%s %-16s 缺失\n' "$YELLOW" "$NC" "$p"
            miss="$miss $p"
        fi
    done
    subline
    if [ -z "$miss" ]; then
        ok "基础套件已齐备，未做任何安装动作"
        nftables_guard
        return 0
    fi
    printf ' 需要安装:%s\n 继续? [Y/n]: ' "$miss"
    read -r a || return 0
    case "$a" in
        [nN]) info "已取消"; return 0 ;;
    esac
    apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 有告警，继续"
    # shellcheck disable=SC2086
    if apt-get install -y $miss >/dev/null 2>&1; then
        ok "基础套件安装完成"
    else
        warn "部分包安装异常，请检查 apt 输出"
    fi
    nftables_guard
}

deps_check_update() {
    local a latest
    title "组件更新检查"
    subline
    if wg_installed; then
        printf '  %-20s %s\n' "wireguard-tools" "$(wg --version 2>/dev/null | head -1)"
        if apt list --upgradable 2>/dev/null | grep -q '^wireguard-tools/'; then
            warn "wireguard-tools 有新版本可用"
            printf ' 现在升级? [y/N]: '
            read -r a || return 0
            case "$a" in
                [yY]) if apt-get install -y --only-upgrade wireguard-tools >/dev/null 2>&1; then
                          ok "wireguard-tools 已升级"
                      else
                          err "升级失败，请手动检查 apt"
                      fi ;;
                *) info "已跳过 wireguard-tools" ;;
            esac
        else
            ok "wireguard-tools 已是最新"
        fi
    else
        info "wireguard-tools 未安装，跳过"
    fi
    subline
    if singbox_installed; then
        printf "  %-20s %s\n" "sing-box 路径" "$(command -v sing-box)"
        printf '  %-20s %s\n' "当前版本" "$("$SINGBOX_BIN" version 2>/dev/null | head -1)"
        latest="$(curl -s --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null || true)"
        printf '  %-20s %s\n' "sing-box 最新发布" "${latest:-未知}"
        printf ' 是否重新下载并覆盖为最新版? [y/N]: '
        read -r a || return 0
        case "$a" in
            [yY]) rm -f "$SINGBOX_BIN"
                  install_singbox ;;
            *) info "已跳过 sing-box" ;;
        esac
    else
        info "sing-box 未安装，跳过"
    fi
    subline
    info "组件更新不影响出口配置，也不会重启 incus 或 nftables 服务"
}

deps_menu() {
    while true; do
        clear_if_tty
        title "依赖安装"
        comp_line
        subline
        printf '  %s[1]%s 基础套件\n' "$GREEN" "$NC"
        printf '        nftables / iproute2 / curl / jq / python3 / ca-certificates\n'
        printf '  %s[2]%s 隧道组件 · WireGuard\n' "$GREEN" "$NC"
        printf '        wireguard-tools —— 使用 WireGuard 出口时必需\n'
        printf '  %s[3]%s 隧道组件 · Shadowsocks / Shadowsocks 2022（sing-box）\n' "$GREEN" "$NC"
        printf '        sing-box 客户端 —— 使用 Shadowsocks / Shadowsocks 2022 出口时必需（支持 TCP+UDP）\n'
        printf '  %s[4]%s 全部安装（1 + 2 + 3）\n' "$GREEN" "$NC"
        printf '  %s[5]%s 检查组件更新（已装的才会检查）\n' "$GREEN" "$NC"
        printf '  ------------------------------------------------------------\n'
        printf '  %s[0]%s 返回上一层\n' "$YELLOW" "$NC"
        line
        printf '请输入选项 [0-4]: '
        read -r c || return 0
        case "$c" in
            1) install_base; pause_back ;;
            2) install_wireguard; pause_back ;;
            3) install_singbox; pause_back ;;
            4) install_base; install_wireguard; install_singbox; pause_back ;;
            5) deps_check_update; pause_back ;;
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------- 版本与更新

ver_gt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

update_menu() {
    local rv tmp
    title "更新脚本"
    info "当前版本: v$SCRIPT_VERSION"
    info "远端仓库: $REPO_OWNER/$REPO_NAME ($REPO_BRANCH)"
    subline
    info "正在检查远端版本 ..."
    chk="$(mktemp -d)"
    # codeload 不受 raw CDN 缓存影响，优先用它取版本号
    sha="$(curl -s --max-time 20 "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/git/refs/heads/$REPO_BRANCH" 2>/dev/null | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)"
    src_url="https://codeload.github.com/$REPO_OWNER/$REPO_NAME/tar.gz/$sha"
    [ -n "$sha" ] || src_url="https://codeload.github.com/$REPO_OWNER/$REPO_NAME/tar.gz/refs/heads/$REPO_BRANCH"
    if curl -fsSL --max-time 90 -o "$chk/src.tar.gz" "$src_url" 2>/dev/null; then
        mkdir -p "$chk/src"
        tar -xzf "$chk/src.tar.gz" -C "$chk/src" 2>/dev/null
        rv="$(cat "$(find "$chk/src" -maxdepth 2 -name version.txt | head -1)" 2>/dev/null | tr -d '\r\n ')"
    fi
    [ -n "${rv:-}" ] || rv="$(curl -fsSL -H 'Cache-Control: no-cache' --max-time 15 "$UPDATE_BASE/version.txt" 2>/dev/null | tr -d '\r\n ' || true)"
    rm -rf "$chk"
    if [ -z "$rv" ]; then
        err "拉取远端版本失败（网络不通或仓库不可达）"
        pause_back
        return 1
    fi
    info "远端版本: v$rv"
    if ! ver_gt "$rv" "$SCRIPT_VERSION"; then
        ok "已是最新版本 v$SCRIPT_VERSION，无需更新"
        pause_back
        return 0
    fi
    printf '\n'
    warn "发现新版本 v$rv"
    printf ' 更新说明（前 20 行）：\n'
    subline
    curl -fsSL --max-time 15 "$UPDATE_BASE/CHANGELOG.md" 2>/dev/null | head -20 || printf '  （无更新说明）\n'
    subline
    printf ' 更新只替换 /usr/local/bin/mr 与 mr-api.py\n'
    printf ' %s不会改动%s /etc/incus-multiroute（出口/绑定/令牌/白名单）和 /var/lib/incus-multiroute\n' "$GREEN" "$NC"
    printf ' 继续更新? [y/N]: '
    read -r a || return 0
    case "$a" in [yY]) ;; *) info "已取消，未做任何改动"; pause_back; return 0 ;; esac
    tmp="$(mktemp -d)"
    info "下载新版本 ..."
    sha="$(curl -s --max-time 20 "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/git/refs/heads/$REPO_BRANCH" 2>/dev/null | sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)"
    src_url2="https://codeload.github.com/$REPO_OWNER/$REPO_NAME/tar.gz/$sha"
    [ -n "$sha" ] || src_url2="https://codeload.github.com/$REPO_OWNER/$REPO_NAME/tar.gz/refs/heads/$REPO_BRANCH"
    if curl -fsSL --max-time 120 -o "$tmp/src.tar.gz" "$src_url2" 2>/dev/null; then
        mkdir -p "$tmp/src"
        tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" 2>/dev/null
        local sd2
        sd2="$(find "$tmp/src" -maxdepth 1 -type d -name '*multiroute*' | head -1)"
        [ -n "$sd2" ] && cp -f "$sd2/mr.sh" "$tmp/mr.sh" && cp -f "$sd2/mr-api.py" "$tmp/mr-api.py" 2>/dev/null
    fi
    if [ ! -f "$tmp/mr.sh" ] && ! curl -fsSL --max-time 60 -o "$tmp/mr.sh" "$UPDATE_BASE/mr.sh"; then
        err "下载失败，已放弃（当前版本未受影响）"; rm -rf "$tmp"; pause_back; return 1
    fi
    if ! bash -n "$tmp/mr.sh"; then
        err "新脚本语法校验失败，已放弃（当前版本未受影响）"; rm -rf "$tmp"; pause_back; return 1
    fi
    if ! grep -q "SCRIPT_VERSION=\"$rv\"" "$tmp/mr.sh" 2>/dev/null; then
        warn "raw 取到的仍是旧版本（CDN 缓存），改用 codeload 直取 ..."
        if curl -fsSL --max-time 120 -o "$tmp/src.tar.gz" \
            "https://codeload.github.com/$REPO_OWNER/$REPO_NAME/tar.gz/refs/heads/$REPO_BRANCH" 2>/dev/null; then
            mkdir -p "$tmp/src"
            tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" 2>/dev/null
            local sd
            sd="$(find "$tmp/src" -maxdepth 1 -type d -name '*multiroute*' | head -1)"
            [ -n "$sd" ] && cp -f "$sd/mr.sh" "$tmp/mr.sh" && cp -f "$sd/mr-api.py" "$tmp/mr-api.py" 2>/dev/null
        fi
        if ! grep -q "SCRIPT_VERSION=\"$rv\"" "$tmp/mr.sh" 2>/dev/null; then
            err "仍取不到 v$rv，已放弃（当前版本未受影响）"; rm -rf "$tmp"; pause_back; return 1
        fi
    fi
    cp -f "$SELF_PATH" "$SELF_PATH.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    install -m 755 "$tmp/mr.sh" /usr/local/bin/mr
    if curl -fsSL --max-time 60 -o "$tmp/mr-api.py" "$UPDATE_BASE/mr-api.py" 2>/dev/null; then
        if python3 -c "import py_compile; py_compile.compile('$tmp/mr-api.py', doraise=True)" >/dev/null 2>&1; then
            install -m 755 "$tmp/mr-api.py" /usr/local/bin/mr-api.py
            systemctl is-active --quiet mr-api 2>/dev/null && systemctl restart mr-api
        else
            warn "新的 mr-api.py 语法校验失败，已跳过（API 保持旧版本）"
        fi
    fi
    rm -rf "$tmp"
    # 校验落盘版本，避免"显示更新成功但实际还是旧文件"
    local nowver
    nowver="$(grep -m1 'SCRIPT_VERSION=' /usr/local/bin/mr 2>/dev/null | cut -d'"' -f2)"
    if [ "$nowver" != "$rv" ]; then
        err "落盘版本是 v${nowver:-未知}，不是 v$rv（可能被其它进程覆盖）"
        pause_back
        return 1
    fi
    ok "已更新到 v$rv"
    info "旧版本备份: $SELF_PATH.bak.*"
    info "配置未改动"
    # 直接用新文件重开菜单（bash 显式执行，避免 shebang / noexec 等意外）
    if [ -f /usr/local/bin/mr ]; then
        info "正在用新版本重新打开菜单 ..."
        sleep 1
        exec bash /usr/local/bin/mr
    fi
    pause_back
}

# ---------------------------------------------------------------- 一键卸载

uninstall_all() {
    local ans name l proto wgif mark table
    title "一键卸载 Incus MultiRoute"
    warn "将删除：nft 表 inet multiroute、WireGuard 出口接口与策略路由、全部 mr-* 单元、"
    warn "        /etc/incus-multiroute、/var/lib/incus-multiroute、/usr/local/bin/mr 与 mr-api.py"
    info "不会自动卸载 wireguard-tools / sing-box 二进制，也不会动 incus 与其它面板的表"
    subline
    printf ' %s第一次确认%s —— 输入 yes 继续，其它任意键取消: ' "$YELLOW" "$NC"
    read -r a1 || return 0
    case "$a1" in
        [yY][eE][sS]) ;;
        *) info "已取消，未做任何改动"; pause_back; return 0 ;;
    esac
    printf ' %s第二次确认%s —— 最后机会，再次输入 yes: ' "$RED" "$NC"
    read -r a2 || return 0
    case "$a2" in
        [yY][eE][sS]) ;;
        *) info "两次确认不一致，已取消，未做任何改动"; pause_back; return 0 ;;
    esac
    info "开始卸载 ..."

    info "停止并清理服务单元 ..."
    systemctl disable --now mr-sync.timer    >/dev/null 2>&1 || true
    systemctl disable --now mr-api.service   >/dev/null 2>&1 || true
    systemctl disable --now mr-restore.service >/dev/null 2>&1 || true
    # 单元是按 mark 命名的（中文名不能做 systemd 单元名），这里必须用 mark
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto host port meth pass mark wgkey wgif local expect enable lp mhost6 <<< "$l"
        case "$proto" in
            ss|ss2022|logic) systemctl disable --now "mr-ss-$mark.service" >/dev/null 2>&1 || true ;;
        esac
    done < "$EXITS_CONF" 2>/dev/null
    # 兜底：清掉任何残留的 mr-ss-* 单元
    systemctl disable --now 'mr-ss-*' >/dev/null 2>&1 || true

    info "清理 wg 接口与策略路由 ..."
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto host port meth pass mark wgkey wgif local expect enable lp mhost6 <<< "$l"
        [ "$proto" = "wg" ] || continue
        table="$(wg_table "$name")"
        ip rule del fwmark "$mark" table "$table" 2>/dev/null || true
        ip route flush table "$table" 2>/dev/null || true
        [ -n "$wgif" ] && ip link del "$wgif" 2>/dev/null || true
    done < "$EXITS_CONF" 2>/dev/null

    info "清理透明代理策略路由与 sysctl ..."
    tproxy_routing_off 2>/dev/null || true
    remove_tproxy_sysctl 2>/dev/null || true

    info "删除 nft 表 ..."
    nft delete table inet multiroute 2>/dev/null && ok "已删除 inet multiroute" || info "无 nft 表需要删除"

    info "回收所有已授权容器的 out ..."
    local c
    for c in $(allowed_list); do
        incus exec "$c" -- sh -c 'rm -f /usr/local/bin/out /etc/incus-egress-token' </dev/null >/dev/null 2>&1 \
            && info "已回收 $c" || warn "$c 回收失败（容器可能已停）"
    done

    info "删除单元文件与目录 ..."
    rm -f /etc/systemd/system/mr-*.service /etc/systemd/system/mr-*.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    printf ' 是否一并卸载依赖组件 wireguard-tools / sing-box? 输入 yes 卸载（其它保留）: '
    read -r a3 || return 0
    if [ "$a3" = "yes" ]; then
        if dpkg -s wireguard-tools >/dev/null 2>&1; then
            apt-get remove -y wireguard-tools >/dev/null 2>&1 && info "已卸载 wireguard-tools" || warn "wireguard-tools 卸载失败"
        fi
        rm -f "$SINGBOX_BIN" && info "已删除 sing-box"
    else
        info "已保留 wireguard-tools / sing-box（以后要用可直接复用）"
    fi

    local _bk
    _bk="/root/incus-multiroute-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    if tar czf "$_bk" -C / etc/incus-multiroute 2>/dev/null; then
        ok "配置已备份：$_bk"
    else
        warn "配置备份失败（继续卸载）"
    fi
    rm -rf "$CONF_DIR" "$DATA_DIR"
    rm -f /usr/local/bin/mr /usr/local/bin/mr-api.py
    # 一并清掉历次自更新留下的备份
    rm -f /usr/local/bin/mr.bak.* /usr/local/bin/mr-api.py.bak.* 2>/dev/null || true
    subline
    ok "卸载完成（incus、其它面板的 nft 表、所有容器均未改动）"
    printf '\n'
    exit 0
}

# ---------------------------------------------------------------- 安全加固

host_has_ipv4() { ip -4 route show default 2>/dev/null | grep -q default; }
host_has_ipv6() { ip -6 route show default 2>/dev/null | grep -q default; }

# 找出容器的网卡设备名（通常 eth0，但不写死）
container_nic_dev() {
    local c="$1" dev
    dev="$(incus config device show "$c" 2>/dev/null | awk '
        /^[A-Za-z0-9_.-]+:$/ { name=$0; sub(/:$/, "", name) }
        /nictype:|network:/ { if (name != "") { print name; exit } }
    ')"
    printf '%s' "${dev:-eth0}"
}

sec_flag() {  # $1=容器 $2=设备 $3=ipv4_filtering|ipv6_filtering  → 输出 true/空
    incus config device get "$1" "$2" "security.$3" 2>/dev/null
}

sec_apply_one() {  # $1=容器  $2=1 开启 / 0 关闭
    local c="$1" mode="$2" dev rc=0 k
    dev="$(container_nic_dev "$c")"
    for k in ipv4_filtering ipv6_filtering; do
        case "$k" in
            ipv4_filtering) host_has_ipv4 || continue ;;
            ipv6_filtering) host_has_ipv6 || continue ;;
        esac
        if [ "$mode" = "1" ]; then
            incus config device set "$c" "$dev" "security.$k" true >/dev/null 2>&1 || rc=1
        else
            incus config device unset "$c" "$dev" "security.$k" >/dev/null 2>&1 || rc=1
        fi
    done
    return $rc
}

sec_status_table() {
    local c dev v4 v6 f4 f6 line
    if ! host_has_ipv4; then f4="(宿主机无 IPv4)"; fi
    if ! host_has_ipv6; then f6="(宿主机无 IPv6)"; fi
    printf '  %-22s %-16s %-16s
' "容器" "IPv4 防伪" "IPv6 防伪"
    subline
    for c in $(incus list --format=csv -c n 2>/dev/null); do
        dev="$(container_nic_dev "$c")"
        v4="$(sec_flag "$c" "$dev" ipv4_filtering)"
        v6="$(sec_flag "$c" "$dev" ipv6_filtering)"
        [ "$v4" = "true" ] && v4="${GREEN}已开${NC}" || v4="${YELLOW}未开${NC}"
        [ "$v6" = "true" ] && v6="${GREEN}已开${NC}" || v6="${YELLOW}未开${NC}"
        [ -n "$f4" ] && v4="$f4"
        [ -n "$f6" ] && v6="$f6"
        printf '  %-22s %-25b %-25b
' "$c" "$v4" "$v6"
    done
}

sec_apply_all() {
    local mode="$1" c ok=0 fail=0 n=0
    if ! host_has_ipv4 && ! host_has_ipv6; then
        err "宿主机既没有 IPv4 也没有 IPv6 默认路由，无法加固"
        return 1
    fi
    title "安全加固 · $([ "$mode" = "1" ] && echo 开启 || echo 关闭)"
    info "将处理: $(host_has_ipv4 && printf 'IPv4 ') $(host_has_ipv6 && printf 'IPv6 ')"
    if ! host_has_ipv6; then info "宿主机没有 IPv6 默认路由，跳过 ipv6_filtering"; fi
    if ! host_has_ipv4; then info "宿主机没有 IPv4 默认路由，跳过 ipv4_filtering"; fi
    subline
    for c in $(incus list --format=csv -c n 2>/dev/null); do
        n=$((n + 1))
        if sec_apply_one "$c" "$mode"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            warn "$c 设置失败"
        fi
    done
    subline
    ok "处理完成: 成功 $ok / 失败 $fail（共 $n 个容器）"
    if [ "$mode" = "1" ]; then
        info "如某个容器出现断网，用本菜单 [4] 关闭它的加固再排查"
        info "少数场景（容器内含 Docker 多网段、Tailscale 等）可能需要重启容器才完全生效"
    fi
}

bridge_family_menu() {
    local a c b4 b6 g4 g6 own4 own6 l4 l6
    while :; do
        clear_if_tty
        title "辅助功能 · 网桥地址族"
        b4="$(bridge_ipv4 2>/dev/null)"; b6="$(bridge_ipv6 2>/dev/null)"
        own4="${BRIDGE_IPV4_AUTO:-0}"; own6="${BRIDGE_IPV6_AUTO:-0}"
        g4=0; g6=0
        ip -4 route show default 2>/dev/null | grep -q default && g4=1
        ip -6 route show default 2>/dev/null | grep -q default && g6=1
        printf '  %-22s %s\n' "宿主机 IPv4 出网" "$([ "$g4" = 1 ] && echo 有 || echo 无)"
        printf '  %-22s %s\n' "宿主机 IPv6 出网" "$([ "$g6" = 1 ] && echo 有 || echo 无)"
        printf '  %-22s %s\n' "网桥 IPv4（$BRIDGE）" "${b4:-未启用}"
        printf '  %-22s %s\n' "网桥 IPv6（$BRIDGE）" "${b6:-未启用}"
        subline
        if [ -n "$b4" ] && [ "$own4" != "1" ]; then
            l4="由 Incus 原生提供 —— 不可关闭"
        elif [ -n "$b4" ]; then
            l4="关闭（本脚本开启的）"
        else
            l4="开启"
        fi
        if [ -n "$b6" ] && [ "$own6" != "1" ]; then
            l6="由 Incus 原生提供 —— 不可关闭"
        elif [ -n "$b6" ]; then
            l6="关闭（本脚本开启的）"
        else
            l6="开启"
        fi
        printf '    %s[1]%s 网桥 IPv4：%s\n' "$GREEN" "$NC" "$l4"
        printf '    %s[2]%s 网桥 IPv6：%s\n' "$GREEN" "$NC" "$l6"
        if [ -n "$b4" ] && [ -n "$b6" ]; then
            printf '    %s[3]%s 全部开启（当前两个地址族都已存在，无需操作）\n' "$YELLOW" "$NC"
        else
            printf '    %s[3]%s 全部开启（只开缺失的地址族）\n' "$GREEN" "$NC"
        fi
        printf '    %s[4]%s 关闭新增网桥（只关本脚本开启的）\n' "$GREEN" "$NC"
        printf '    %s[0]%s 返回\n' "$YELLOW" "$NC"
        line
        printf '请输入选项 [0-4]: '
        read -r a || return 0
        case "$a" in
            0|"") return 0 ;;
            1)
                if [ -n "$b4" ] && [ "$own4" != "1" ]; then
                    err "网桥 IPv4（$b4）是 Incus 原生配置，脚本不允许关闭"
                    info "只有由本脚本（本菜单）开启的地址族才可关闭，避免影响 incus 自身"
                    pause_back; continue
                fi
                if [ -n "$b4" ]; then
                    warn "关闭网桥 IPv4 后，容器的 IPv4 代理与绑定会全部失效"
                    printf ' 确认关闭? 输入 yes: '; read -r c || return 0
                    [ "$c" = "yes" ] || { info 已取消; continue; }
                    incus network unset "$BRIDGE" ipv4.address </dev/null >/dev/null 2>&1 || true
                    incus network unset "$BRIDGE" ipv4.nat </dev/null >/dev/null 2>&1 || true
                    save_main_var BRIDGE_IPV4_AUTO 0; BRIDGE_IPV4_AUTO=0
                    ok "网桥 IPv4 已关闭"; load_conf >/dev/null 2>&1 || true
                else
                    printf ' 确认开启网桥 IPv4（自动挑私有网段）? [Y/n]: '; read -r c || return 0
                    case "$c" in [nN]) info 已取消; continue ;; esac
                    if incus network set "$BRIDGE" ipv4.address auto </dev/null >/dev/null 2>&1; then
                        incus network set "$BRIDGE" ipv4.nat true </dev/null >/dev/null 2>&1 || true
                        save_main_var BRIDGE_IPV4_AUTO 1; BRIDGE_IPV4_AUTO=1; sleep 1
                        ok "网桥 IPv4 已开启：$(bridge_ipv4 2>/dev/null)"; load_conf >/dev/null 2>&1 || true
                    else
                        err "开启失败，请手动检查 incus network show $BRIDGE"
                    fi
                fi
                pause_back ;;
            2)
                if [ -n "$b6" ] && [ "$own6" != "1" ]; then
                    err "网桥 IPv6（$b6）是 Incus 原生配置，脚本不允许关闭"
                    info "只有由本脚本（本菜单）开启的地址族才可关闭，避免影响 incus 自身"
                    pause_back; continue
                fi
                if [ -n "$b6" ]; then
                    warn "关闭网桥 IPv6 后，容器的 IPv6 代理与双栈会全部失效"
                    printf ' 确认关闭? 输入 yes: '; read -r c || return 0
                    [ "$c" = "yes" ] || { info 已取消; continue; }
                    incus network unset "$BRIDGE" ipv6.address </dev/null >/dev/null 2>&1 || true
                    incus network unset "$BRIDGE" ipv6.nat </dev/null >/dev/null 2>&1 || true
                    save_main_var BRIDGE_IPV6_AUTO 0; BRIDGE_IPV6_AUTO=0
                    ok "网桥 IPv6 已关闭"; load_conf >/dev/null 2>&1 || true
                else
                    printf ' 确认开启网桥 IPv6（ULA，不占公网）? [Y/n]: '; read -r c || return 0
                    case "$c" in [nN]) info 已取消; continue ;; esac
                    if incus network set "$BRIDGE" ipv6.address "fd42:1:1::1/64" </dev/null >/dev/null 2>&1; then
                        incus network set "$BRIDGE" ipv6.nat true </dev/null >/dev/null 2>&1 || true
                        save_main_var BRIDGE_IPV6_AUTO 1; BRIDGE_IPV6_AUTO=1; sleep 1
                        ok "网桥 IPv6 已开启：$(bridge_ipv6 2>/dev/null)"; load_conf >/dev/null 2>&1 || true
                    else
                        err "开启失败，请手动检查 incus network show $BRIDGE"
                    fi
                fi
                pause_back ;;
            3)
                if [ -n "$b4" ] && [ -n "$b6" ]; then
                    info "网桥 IPv4 与 IPv6 都已存在，无需开启"
                    pause_back; continue
                fi
                printf ' 确认开启网桥缺失的地址族? [Y/n]: '; read -r c || return 0
                case "$c" in [nN]) info 已取消; continue ;; esac
                if [ -z "$(bridge_ipv4 2>/dev/null)" ]; then
                    incus network set "$BRIDGE" ipv4.address auto </dev/null >/dev/null 2>&1 && save_main_var BRIDGE_IPV4_AUTO 1 && ok "网桥 IPv4 已开启"
                fi
                if [ -z "$(bridge_ipv6 2>/dev/null)" ]; then
                    if incus network set "$BRIDGE" ipv6.address "fd42:1:1::1/64" </dev/null >/dev/null 2>&1; then
                        incus network set "$BRIDGE" ipv6.nat true </dev/null >/dev/null 2>&1 || true
                        save_main_var BRIDGE_IPV6_AUTO 1; ok "网桥 IPv6 已开启"
                    fi
                fi
                sleep 1; load_conf >/dev/null 2>&1 || true
                pause_back ;;
            4)
                if [ "$own4" != "1" ] && [ "$own6" != "1" ]; then
                    info "没有由本脚本开启的网桥地址族，无需关闭"
                    info "（Incus 原生提供的 IPv4/IPv6 永远不受本菜单影响）"
                    pause_back; continue
                fi
                printf ' 将关闭本脚本开启的：%s%s\n' \
                    "$([ "$own4" = "1" ] && echo "IPv4 ")" "$([ "$own6" = "1" ] && echo "IPv6 ")"
                warn "关闭后容器会失去对应地址族，双栈/混合出口随之失效"
                printf ' 确认关闭? 输入 yes: '; read -r c || return 0
                [ "$c" = "yes" ] || { info 已取消; continue; }
                if [ "$own6" = "1" ]; then
                    incus network unset "$BRIDGE" ipv6.address </dev/null >/dev/null 2>&1 || true
                    incus network unset "$BRIDGE" ipv6.nat </dev/null >/dev/null 2>&1 || true
                    save_main_var BRIDGE_IPV6_AUTO 0; BRIDGE_IPV6_AUTO=0; own6=0
                    ok "网桥 IPv6 已关闭（本脚本开启的）"
                fi
                if [ "$own4" = "1" ]; then
                    incus network unset "$BRIDGE" ipv4.address </dev/null >/dev/null 2>&1 || true
                    incus network unset "$BRIDGE" ipv4.nat </dev/null >/dev/null 2>&1 || true
                    save_main_var BRIDGE_IPV4_AUTO 0; BRIDGE_IPV4_AUTO=0; own4=0
                    ok "网桥 IPv4 已关闭（本脚本开启的）"
                fi
                load_conf >/dev/null 2>&1 || true
                pause_back ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

aux_menu() {
    local a
    while :; do
        clear_if_tty
        title "辅助功能（选择性开启）"
        printf '    %s[1]%s 网桥地址族（IPv4 / IPv6 开启或关闭）\n' "$GREEN" "$NC"
        printf '    %s[2]%s 安全加固（源 IP 防伪）\n' "$GREEN" "$NC"
        printf '    %s[0]%s 返回\n' "$YELLOW" "$NC"
        line
        printf '请输入选项 [0-2]: '
        read -r a || return 0
        case "$a" in
            0|"") return 0 ;;
            1) bridge_family_menu ;;
            2) sec_menu ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}
sec_menu() {
    local c dev a
    while true; do
        title "安全加固"
        printf '  %s宿主协议族%s  IPv4: %s   IPv6: %s
' "$BLUE" "$NC" \
            "$(host_has_ipv4 && echo 有 || echo 无)" "$(host_has_ipv6 && echo 有 || echo 无)"
        info "加固内容: 禁止容器伪造源 IP（security.ipv4_filtering / security.ipv6_filtering）"
        info "作用: 防止容器借别人的 IP 发包（反射攻击、日志污染、绕过按 IP 的限制）"
        subline
        printf '    %s[1]%s 查看各容器加固状态
' "$GREEN" "$NC"
        printf '    %s[2]%s 全部开启（按宿主机协议族自动选择）
' "$GREEN" "$NC"
        printf '    %s[3]%s 指定容器开启
' "$GREEN" "$NC"
        printf '    %s[4]%s 指定容器关闭
' "$GREEN" "$NC"
        printf '    %s[5]%s 全部关闭（撤销全部容器的加固）
' "$GREEN" "$NC"
        printf '    %s[6]%s 新容器自动加固：%s
' "$GREEN" "$NC" "$([ "${AUTO_HARDEN:-0}" = "1" ] && echo 已开启 || echo 未开启)"
        printf '    %s[0]%s 返回
' "$YELLOW" "$NC"
        line
        printf '请输入选项 [0-6]: '
        read -r a || return 0
        case "$a" in
            0|"") return 0 ;;
            1) title "加固状态"; sec_status_table; pause_back ;;
            2)
                printf ' 确认给 %s 个容器开启防伪? 输入 yes 继续: ' "$(incus list --format=csv -c n 2>/dev/null | grep -c .)"
                read -r a || return 0
                [ "$a" = "yes" ] || { info "已取消"; pause_back; continue; }
                sec_apply_all 1; pause_back
                ;;
            3)
                c="$(pick_container)" || { pause_back; continue; }
                if sec_apply_one "$c" 1; then ok "已为 $c 开启加固"; else err "$c 设置失败"; fi
                pause_back
                ;;
            4)
                c="$(pick_container)" || { pause_back; continue; }
                if sec_apply_one "$c" 0; then ok "已为 $c 关闭加固"; else err "$c 设置失败"; fi
                pause_back
                ;;
            5)
                printf ' 确认关闭 %s 个容器的源 IP 防伪? 输入 yes 继续: ' "$(incus list --format=csv -c n 2>/dev/null | grep -c .)"
                read -r a || return 0
                [ "$a" = "yes" ] || { info "已取消"; pause_back; continue; }
                sec_apply_all 0; pause_back
                ;;
            6)
                if [ "${AUTO_HARDEN:-0}" = "1" ]; then
                    save_main_var AUTO_HARDEN 0; AUTO_HARDEN=0
                    info "已关闭：新容器不再自动加固"
                else
                    save_main_var AUTO_HARDEN 1; AUTO_HARDEN=1
                    ok "已开启：定时器会给新容器自动加固（按宿主机协议族）"
                fi
                pause_back
                ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------- 体检

doctor() {
    local fails=0
    title "环境体检"
    printf '  %-28s %s\n' "网桥" "${BRIDGE:-未探测}"
    printf '  %-28s %s\n' "网桥网段" "$(detect_subnet)"
    subline
    check_item() {
        local name="$1" rc="$2" hint="$3"
        if [ "$rc" = "0" ]; then
            printf '  %s[ OK ]%s %-26s %s\n' "$GREEN" "$NC" "$name" "${hint}"
        else
            printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "$name" "${hint}"
        fi
    }
    has_cmd incus;  check_item "incus 命令" "$?" "容器管理依赖"
    has_cmd nft;    check_item "nftables" "$?" "规则下发依赖"
    has_cmd python3; check_item "python3" "$?" "API 服务依赖"
    if [ -x "$SINGBOX_BIN" ]; then
        check_item "sing-box" 0 "$SINGBOX_BIN（$("$SINGBOX_BIN" version 2>/dev/null | head -1 | sed 's/sing-box version //')）"
    else
        check_item "sing-box" 1 "缺少 $SINGBOX_BIN（菜单 15 → 3 安装）"
    fi
    has_cmd wg;     check_item "wireguard-tools" "$?" "WireGuard 出口依赖"
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; check_item "ip_forward=1" "$?" "转发必需"
    local rpv
    rpv="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)"
    if [ "$rpv" = "2" ]; then
        check_item "rp_filter=2（loose）" 0 "策略路由已就绪"
    else
        printf '  %s[提示]%s %-26s 当前 %s；用 ss 出口不需要，用 WireGuard 出口时建议设为 2\n' "$YELLOW" "$NC" "rp_filter" "${rpv:-未知}"
    fi
    nft list table inet multiroute >/dev/null 2>&1; check_item "nft 表 inet multiroute" "$?" "未下发过规则时属于正常"
    [ -f "$CLIENT_BASE" ]; check_item "用户端基准脚本" "$?" "$CLIENT_BASE"
    [ -n "$(client_hash_base 2>/dev/null)" ]; check_item "基准哈希" "$?" "$CLIENT_HASH"
    local api_listen
    api_listen="$(ss -lntH 2>/dev/null | awk '$4 ~ /:18988$/ {print $4; exit}')"
    if [ -n "$api_listen" ]; then
        case "$api_listen" in
            0.0.0.0:*|"*":*|"[::]"*)
                printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "API 监听全部地址" "$api_listen"
                info "建议只绑网桥地址：写 LISTEN=\"<网桥IP>:18988\" 到 $CONF_DIR/api.conf 后重启 mr-api"
                ;;
            *) check_item "API 监听地址" 0 "$api_listen" ;;
        esac
    fi
    local pc
    pc="$(tproxy_port_conflicts 2>/dev/null)"
    if [ -n "$pc" ]; then
        printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "代理端口被占用" "$pc"
        info "端口段 $TPROXY_BASE-$((TPROXY_BASE + 99)) 归本脚本；请让用户端口映射避开"
    fi
    local b4 b6 g4 g6
    b4="$(bridge_ipv4 2>/dev/null)"
    b6="$(bridge_ipv6 2>/dev/null)"
    g4=0; g6=0
    ip -4 route show default 2>/dev/null | grep -q default && g4=1
    ip -6 route show default 2>/dev/null | grep -q default && g6=1
    # 网桥地址族：按宿主机实际出网能力给出对应提示
    if [ -n "$b4" ]; then
        check_item "网桥 IPv4" 0 "$b4"
    elif [ "$g6" = "1" ] && [ "$g4" = "0" ]; then
        printf '  %s[提示]%s %-26s %s\n' "$YELLOW" "$NC" "网桥 IPv4" "未启用（宿主只有 IPv6；需要 IPv4 拓展时用 菜单 [2] → [5] 自动开启）"
    else
        printf '  %s[提示]%s %-26s %s\n' "$YELLOW" "$NC" "网桥 IPv4" "未启用"
    fi
    if [ -z "$b6" ]; then
        if [ "$g4" = "1" ] && [ "$g6" = "0" ]; then
            printf '  %s[提示]%s %-26s %s\n' "$YELLOW" "$NC" "网桥 IPv6" "未启用（宿主只有 IPv4；需要 IPv6 拓展/双栈时用 菜单 [2] → [5] 自动开启）"
        else
            printf '  %s[提示]%s %-26s %s\n' "$YELLOW" "$NC" "网桥 IPv6" "未启用"
        fi
    fi
    if [ -n "$b6" ]; then
        check_item "网桥 IPv6" 0 "$b6（双栈透明代理已启用）"
        if ip -6 rule show 2>/dev/null | grep -q "lookup 1001"; then
            check_item "IPv6 tproxy 策略路由" 0 "fwmark 0x80000001 → table 1001"
        else
            printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "IPv6 tproxy 策略路由" "缺失，按 11 重新下发"
        fi
        [ "$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)" = "0" ] \
            && check_item "br_netfilter(IPv6) 已关闭" 0 "双栈必需" \
            || printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "br_netfilter(IPv6) 未关闭" "v6 tproxy 会不通，按 11 重新下发"
    fi
    if [ -z "$b6" ] && [ -f "$BIND_CONF" ]; then
        # 网桥没 IPv6，但容器自己另有 IPv6（例如单独的 routed 网卡）：这部分流量不会被代理
        local _c _ip _e _m v6leak=""
        while IFS='|' read -r _c _ip _e _m; do
            case "$_c" in ''|'#'*) continue ;; esac
            [ -n "$(container_ip6 "$_c" 2>/dev/null)" ] && v6leak="$v6leak $_c"
        done < "$BIND_CONF"
        if [ -n "$v6leak" ]; then
            printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "容器有 IPv6 但网桥没有" "$v6leak"
            info "这部分 IPv6 流量不经过网桥，不会被代理（如需代理请给网桥配 IPv6，或禁用容器 IPv6）"
        fi
    fi
    if ip -6 route show default 2>/dev/null | grep -q default; then
        printf '  %s[提示]%s %-26s %s\n' "$YELLOW" "$NC" "宿主机有 IPv6 出网" "可用于 IPv6 成员/出口"
    elif [ -n "$b6" ]; then
        printf '  %s[提示]%s %-26s %s\n' "$YELLOW" "$NC" "宿主机无 IPv6 出网" "v6 目标仍可经 v4 隧道访问，但不能直连 v6 出口机"
    fi
    if [ "$(ss_enabled_count 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        if [ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" = "0" ]; then
            check_item "br_netfilter 已关闭" 0 "TPROXY 必需"
        else
            printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "br_netfilter 未关闭" "TPROXY 不通，按 11 重新下发"
        fi
        if ip rule show 2>/dev/null | grep -q "lookup 1001"; then
            check_item "tproxy 策略路由" 0 "fwmark 0x80000001 → table 1001"
        else
            printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "tproxy 策略路由" "缺失，按 11 重新下发"
        fi
    fi
    if [ "${AUTO_GRANT:-0}" = "1" ]; then
        check_item "新容器自动授权" 0 "已开启（定时器会把新容器纳管并下发 out）"
    else
        printf '  %s[提示]%s %-26s 未开启（新容器需要手动授权，菜单 10 → 10 可开）\n' "$YELLOW" "$NC" "新容器自动授权"
    fi
    if systemctl is-active --quiet mr-sync.timer 2>/dev/null; then
        check_item "自动校验定时器" 0 "已启用（$(sync_timer_interval)）"
    else
        printf '  %s[提示]%s %-26s 未开启（可选功能，菜单 10 → 7 开启）\n' "$YELLOW" "$NC" "自动校验定时器"
    fi
    local dup
    dup="$(grep -v '^#' "$EXITS_CONF" 2>/dev/null | awk -F'|' 'NF>=7 && $7!="" {print $7}' | sort | uniq -d | tr '\n' ' ')"
    if [ -n "$dup" ]; then
        printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "出口 mark 重复" "$dup"
        info "重复 mark 会让两个出口抢同一张路由表，请在 [3] 删除后重新 [2] 添加"
    else
        check_item "出口 mark 唯一" 0 "无重复"
    fi
    local conflict
    # 排除本脚本自己的：出口 mark（0x1000-0x1fff）与 tproxy 路由 mark（0x80000001）
    conflict="$(ip rule show 2>/dev/null | grep -oE 'fwmark 0x[0-9a-fA-F]+' | awk '{print $2}' | sort -u \
        | grep -viE '^0x1[0-9a-fA-F]{3}$' | grep -viE '^0x80000001$' | head -5 || true)"
    if [ -n "$conflict" ]; then
        printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "外部 fwmark 规则" "$(printf '%s ' $conflict)"
        info "本脚本只用 0x1000-0x1fff；上面若有重叠，先协调再下发，避免抢路由"
    else
        check_item "mark 段无冲突" 0 "0x1000-0x1fff 归本脚本专用"
    fi
    # 出口密码格式（历史上曾因缺 "=" 填充导致 sing-box 启动失败）
    if [ -f "$EXITS_CONF" ]; then
        local _pn _pp _pm _pr _badpw=""
        while IFS='|' read -r _pn _pp _pm _pr; do
            case "$_pn" in ''|'#'*) continue ;; esac
            [ "$_pp" = "ss2022" ] || continue
            [ -n "$_pr" ] || continue
            if ! _norm="$(ss2022_pass_check "$_pm" "$_pr")"; then
                _badpw="$_badpw $_pn(格式非法)"
            elif [ "$_norm" != "$_pr" ]; then
                _badpw="$_badpw $_pn(缺=填充)"
            fi
        done < "$EXITS_CONF"
        if [ -n "$_badpw" ]; then
            printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "出口密码格式" "$_badpw"
            info "这些出口的 base64 密钥不完整（常见是漏了 = 填充），sing-box 会起不来"
            info "处理：菜单 [3] 修改出口 → [5] 密码，重新输入会自动补齐"
        else
            check_item "出口密码格式" 0 "全部符合所选算法"
        fi
    fi
    # 双隧道分流：两腿是否都还能解析/连得上（域名可能变）
    if [ -f "$EXITS_CONF" ]; then
        local _sn _sp _sh4 _sh6 _sfam6 _sbad=""
        while IFS='|' read -r _sn _sp _sh4 _ __ _ __ _ __ _ __ _ __ _sh6; do
            case "$_sn" in ''|'#'*) continue ;; esac
            case "$_sp" in ss|ss2022) ;; *) continue ;; esac
            [ -n "$_sh6" ] || continue
            case "$(addr_family "$_sh4")" in
                v4|both) ;; *) _sbad="$_sbad $_sn(v4侧异常)" ;;
            esac
            case "$(addr_family "$_sh6")" in
                v6|both) ;; *) _sbad="$_sbad $_sn(v6侧异常)" ;;
            esac
        done < "$EXITS_CONF"
        if [ -n "$_sbad" ]; then
            printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "双隧道地址" "$_sbad"
            info "某一侧的地址族解析不出来时，该族目标会连不上；可用 [3] → [8] 修正"
        fi
    fi
    # 绑定 IP 是否落在网桥网段（容器多网卡时容易绑错，导致代理不生效 + API 认不出身份）
    if [ -f "$BIND_CONF" ]; then
        local _bn _bip _bex _bmk _cidr _badip=""
        _cidr="$(detect_subnet 2>/dev/null)"
        if [ -n "$_cidr" ]; then
            while IFS='|' read -r _bn _bip _bex _bmk; do
                case "$_bn" in ''|'#'*) continue ;; esac
                case "$_bip" in ''|*[!0-9.]*) continue ;; esac
                in_bridge_subnet "$_bip" "$_cidr" || _badip="$_badip $_bn($_bip)"
            done < "$BIND_CONF"
            if [ -n "$_badip" ]; then
                printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "绑定 IP 不在网桥网段" "$_badip"
                info "这些容器有额外网卡（wg0 等）导致取错地址：执行 [9] 校正 后重新下发即可修复"
            else
                check_item "绑定 IP 归属" 0 "均在网桥网段内"
            fi
        fi
    fi
    if [ -f "$BIND_CONF" ] && has_cmd incus; then
        local bc nofilter="" live
        live="$(incus list --format=csv -c n </dev/null 2>/dev/null | tr -d '"')"
        while IFS='|' read -r bc _ _ _; do
            case "$bc" in ''|'#'*) continue ;; esac
            printf '%s\n' "$live" | grep -qxF "$bc" || continue
            incus config show "$bc" 2>/dev/null | grep -q 'ipv4_filtering: "true"' || nofilter="$nofilter $bc"
        done < "$BIND_CONF"
        if [ -n "$nofilter" ]; then
            printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "未开 ipv4_filtering" "$nofilter"
            info "这些容器可以伪造源 IP 发包（反射攻击 / 日志污染）"
            info "处理：菜单 [17] → [2] 安全加固 可一键开启（IPv4/IPv6 按宿主机实际情况）"
        else
            check_item "容器源 IP 防伪" 0 "已绑定容器均开启 ipv4_filtering"
        fi
    fi
    local _auth _live2 _ghost
    _auth="$(grep -v '^#' "$CLIENT_ALLOW_CONF" 2>/dev/null | sed '/^$/d' | cut -d'|' -f1)"
    _live2="$(incus list --format=csv -c n </dev/null 2>/dev/null | tr -d '"')"
    _ghost="$(printf '%s\n' "$_auth" | grep -vxF "$_live2" 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "${_ghost:-0}" -gt 0 ]; then
        printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "失效授权记录" "$_ghost 个（容器已删除）"
        info "处理：菜单 [10] → [11] 一键清理，或下次自动校验时自动清掉"
    else
        check_item "授权记录" 0 "无失效记录"
    fi
    subline
    info "出口 $(exits_count) 个，绑定 $(grep -v '^#' "$BIND_CONF" 2>/dev/null | grep -c '|' || true) 个容器"
    pause_back
}

# ---------------------------------------------------------------- API 服务

api_install_unit() {
    cat > "$UNIT_DIR/mr-api.service" <<EOF
[Unit]
Description=Incus MultiRoute 用户端 API
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/mr-api.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mr-api >/dev/null 2>&1 || true
    # 重启一次，确保按 api.conf 里的地址重新监听（旧进程可能还绑着 0.0.0.0）
    systemctl restart mr-api >/dev/null 2>&1 || true
    ok "API 服务单元已写入并设为开机自启"
}

api_menu() {
    while true; do
        clear_if_tty
        title "API 服务管理"
        printf '  %-20s %s\n' "状态" "$(systemctl is-active mr-api 2>/dev/null || true)"
        printf '  %-20s %s\n' "监听" "$(api_listen_addr)"
        subline
        printf '    %s[1]%s 安装服务单元\n' "$GREEN" "$NC"
        printf '    %s[2]%s 启动 / 重启\n' "$GREEN" "$NC"
        printf '    %s[3]%s 停止\n' "$GREEN" "$NC"
        printf '    %s[4]%s 查看日志\n' "$GREEN" "$NC"
        printf '    %s[0]%s 返回上一层\n' "$YELLOW" "$NC"
        line
        printf '请输入选项 [0-4]: '
        read -r c || return 0
        case "$c" in
            1) api_install_unit; pause_back ;;
            2) api_install_unit; systemctl restart mr-api; sleep 1
               systemctl is-active --quiet mr-api && ok "已启动" || err "启动失败"; pause_back ;;
            3) systemctl stop mr-api; ok "已停止"; pause_back ;;
            4) journalctl -u mr-api -n 40 --no-pager; pause_back ;;
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

api_listen_addr() {
    awk -F'"' '/listen/ {print $2; exit}' "$CONF_DIR/api.conf" 2>/dev/null || echo "未配置"
}

# ---------------------------------------------------------------- 出口菜单

exit_edit() {
    local f num name proto host port method pass mark wgkey wgif local expect enable lp host6
    local field val reason methods m msel i
    title "修改出口节点"
    exits_print_numbered
    subline
    printf '输入要修改的出口编号（0 返回）: '; read -r num || return 0
    case "$num" in 0|"") return 0 ;; esac
    case "$num" in *[!0-9]*) err "请输入编号"; pause_back; return 1 ;; esac
    name="$(exits_list_plain | sed -n "${num}p" | cut -d'|' -f1)"
    [ -n "$name" ] || { err "编号不存在"; pause_back; return 1; }
    while :; do
        f="$(exit_get "$name")"
        IFS='|' read -r name proto host port method pass mark wgkey wgif local expect enable lp host6 <<< "$f"
        title "修改：$name"
        printf '  %-14s %s\n' "协议" "$(proto_label "$proto")"
        printf '  %-14s %s\n' "地址" "${host:-(本机)}"
        printf '  %-14s %s\n' "端口" "${port:-—}"
        printf '  %-14s %s\n' "加密方式" "${method:-（不适用）}"
        printf '  %-14s %s\n' "密码" "$([ -n "$pass" ] && echo '已设置（不显示）' || echo '未设置')"
        printf '  %-14s %s\n' "期望出口 IP" "${expect:-—}"
        printf '  %-14s %s\n' "第二地址" "${host6:-（单隧道）}"
        printf '  %-14s %s\n' "指定本地端口" "${lp:-自动}"
        printf '  %-14s %s\n' "状态" "$([ "$enable" = "0" ] && echo 停用 || echo 启用)"
        subline
        printf '    %s[1]%s 名称\n' "$GREEN" "$NC"
        if [ "$proto" = "logic" ]; then
            printf '    %s[2]%s 查看/修改成员\n' "$GREEN" "$NC"
        else
            printf '    %s[2]%s 服务器地址\n' "$GREEN" "$NC"
            printf '    %s[3]%s 端口\n' "$GREEN" "$NC"
            printf '    %s[4]%s 加密方式\n' "$GREEN" "$NC"
            printf '    %s[5]%s 密码\n' "$GREEN" "$NC"
        fi
        printf '    %s[6]%s 期望出口 IP\n' "$GREEN" "$NC"
        printf '    %s[7]%s 启用 / 停用\n' "$GREEN" "$NC"
        if [ "$proto" = "ss" ] || [ "$proto" = "ss2022" ]; then
            printf '    %s[8]%s 第二隧道地址（双隧道分流）：%s\n' "$GREEN" "$NC" "${host6:-未设置（单隧道）}"
        fi
        printf '    %s[0]%s 返回上一层\n' "$YELLOW" "$NC"
        line
        printf '请输入选项: '; read -r msel || return 0
        case "$msel" in
            0|"") return 0 ;;
            1)
                printf '新名称（0 返回）: '; read -r val || return 0
                case "$val" in 0|"") continue ;; esac
                exit_exists "$val" && [ "$val" != "$name" ] && { err "已有同名出口"; continue; }
                edit_exit_field "$name" 1 "$val" || continue
                # 绑定表里的出口名一起改
                [ -f "$BIND_CONF" ] && { awk -F'|' -v OFS='|' -v o="$name" -v n="$val" '$3==o{$3=n} {print}' "$BIND_CONF" > "$BIND_CONF.tmp" && mv -f "$BIND_CONF.tmp" "$BIND_CONF"; }
                # 逻辑节点/拓展节点的成员记录也要跟着改名，否则配置会生成不出来
                if [ -f "$LOGIC_CONF" ] && grep -q "^$name|" "$LOGIC_CONF" 2>/dev/null; then
                    awk -F'|' -v OFS='|' -v o="$name" -v n="$val" '$1==o{$1=n} {print}' "$LOGIC_CONF" > "$LOGIC_CONF.tmp" \
                        && mv -f "$LOGIC_CONF.tmp" "$LOGIC_CONF"
                fi
                info "名称已改为 $val（用户端 out list 会显示新名称）"
                name="$val"
                edit_apply_changes
                ;;
            2)
                if [ "$proto" = "logic" ]; then exit_edit_members "$name"; continue; fi
                printf '新服务器地址（0 返回）: '; read -r val || return 0
                case "$val" in 0|"") continue ;; esac
                case "$val" in \[*\]) val="$(printf '%s' "$val" | tr -d '[]')" ;; esac
                edit_exit_field "$name" 3 "$val" || continue
                edit_apply_changes
                ;;
            3)
                [ "$proto" = "logic" ] && { echo "无效选择"; sleep 1; continue; }
                printf '新端口（0 返回）: '; read -r val || return 0
                case "$val" in 0|"") continue ;; esac
                case "$val" in *[!0-9]*) err "端口必须是数字"; continue ;; esac
                edit_exit_field "$name" 4 "$val" || continue
                edit_apply_changes
                ;;
            4)
                [ "$proto" = "logic" ] && { echo "无效选择"; sleep 1; continue; }
                if [ "$proto" = "ss2022" ]; then
                    methods="2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305"
                elif [ "$proto" = "ss" ]; then
                    methods="aes-256-gcm aes-192-gcm aes-128-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305"
                else
                    info "WireGuard 的加密方式固定，不能修改"; pause_back; continue
                fi
                i=1; for m in $methods; do printf '  %s[%s]%s %s\n' "$GREEN" "$i" "$NC" "$m"; i=$((i + 1)); done
                printf '  %s[0]%s 返回\n' "$YELLOW" "$NC"
                printf '请选择 [0-%s]: ' "$((i - 1))"; read -r msel || return 0
                case "$msel" in 0|"") continue ;; esac
                case "$msel" in *[!0-9]*) err "请输入序号"; continue ;; esac
                val="$(printf '%s\n' $methods | sed -n "${msel}p")"
                [ -n "$val" ] || { err "无效选择"; continue; }
                edit_exit_field "$name" 5 "$val" || continue
                warn "加密方式变了，密码通常也要一起改（[5]）"
                edit_apply_changes
                ;;
            5)
                [ "$proto" = "logic" ] && { echo "无效选择"; sleep 1; continue; }
                while :; do
                    printf '新密码（0 返回）: '; read -r val || return 0
                    case "$val" in 0|"") break ;; esac
                    if [ "$proto" = "ss2022" ]; then
                        if np="$(ss2022_pass_check "$method" "$val")"; then
                            [ "$np" != "$val" ] && info "已自动补齐 base64 填充"
                            val="$np"
                        else
                            err "密码不符合 $method 的格式：$np"; continue
                        fi
                    fi
                    edit_exit_field "$name" 6 "$val" && edit_apply_changes
                    break
                done
                ;;
            6)
                printf '新期望出口 IP（留空=用服务器地址，输入 - 清空，0 返回）: '; read -r val || return 0
                case "$val" in 0) continue ;; esac
                if [ "$val" = "-" ]; then
                    val=""                # 显式清空
                elif [ -z "$val" ]; then
                    val="$host"           # 留空 = 用服务器地址
                fi
                edit_exit_field "$name" 11 "$val" || continue
                ok "已保存（这一项只用于显示与核对，不需要重启）"
                ;;
            7)
                exit_set_enable "$name" "$([ "$enable" = "0" ] && echo 1 || echo 0)"
                apply_all
                ok "状态已切换并重新下发"
                pause_back
                ;;
            8)
                [ "$proto" = "ss" ] || [ "$proto" = "ss2022" ] || { echo "无效选择"; sleep 1; continue; }
                printf ' 第二隧道地址（v6 侧；留空=关闭双隧道，0 返回）: '; read -r val || return 0
                case "$val" in 0) continue ;; esac
                if [ -n "$val" ]; then
                    case "$(addr_family "$val")" in
                        v6|both) ;;
                        *) err "这不是 IPv6 地址，也没有 AAAA 记录：$val"; continue ;;
                    esac
                    case "$(addr_family "$host")" in
                        v4|both) ;;
                        *) err "主地址不是 v4 侧（$host）：请先把 [2] 服务器地址改成 IPv4 或带 A 记录的域名"; continue ;;
                    esac
                fi
                edit_exit_field "$name" 14 "$val" || continue
                host6="$val"
                edit_apply_changes
                ;;
            *) echo "无效选择"; sleep 1 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

edit_apply_changes() {
    info "正在重新下发（只有配置变化的出口才会重启）..."
    apply_all
    info "用户端无需重新授权；out list 只显示出口名，改地址/端口/密码对用户透明"
    # 不 pause：直接回到修改菜单，方便连续改多项
}

edit_exit_field() {  # $1=出口名 $2=字段号 $3=新值
    local name="$1" fn="$2" val="$3" line a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14
    [ -f "$EXITS_CONF" ] || return 1
    : > "$EXITS_CONF.tmp"
    while IFS= read -r line; do
        case "$line" in ''|'#'*) printf '%s\n' "$line" >> "$EXITS_CONF.tmp"; continue ;; esac
        IFS='|' read -r a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 <<< "$line"
        if [ "$a1" = "$name" ]; then
            case "$fn" in
                1) a1="$val" ;;
                3) a3="$val" ;;
                4) a4="$val" ;;
                5) a5="$val" ;;
                6) a6="$val" ;;
                11) a11="$val" ;;
                12) a12="$val" ;;
                13) a13="$val" ;;
                14) a14="$val" ;;
            esac
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" "$a9" "$a10" "$a11" "$a12" "$a13" "$a14" >> "$EXITS_CONF.tmp"
        else
            printf '%s\n' "$line" >> "$EXITS_CONF.tmp"
        fi
    done < "$EXITS_CONF"
    mv -f "$EXITS_CONF.tmp" "$EXITS_CONF"
}

edit_logic_member_field() {  # $1=节点名 $2=成员序号 $3=字段号(4..8) $4=新值
    local node="$1" midx="$2" fn="$3" val="$4" line a1 a2 a3 a4 a5 a6 a7 a8 a9
    [ -f "$LOGIC_CONF" ] || return 1
    : > "$LOGIC_CONF.tmp"
    while IFS= read -r line; do
        case "$line" in ''|'#'*) printf '%s\n' "$line" >> "$LOGIC_CONF.tmp"; continue ;; esac
        IFS='|' read -r a1 a2 a3 a4 a5 a6 a7 a8 a9 <<< "$line"
        if [ "$a1" = "$node" ] && [ "$a2" = "$midx" ]; then
            case "$fn" in
                4) a4="$val" ;;
                5) a5="$val" ;;
                6) a6="$val" ;;
                7) a7="$val" ;;
                8) a8="$val" ;;
                9) a9="$val" ;;
            esac
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" "$a9" >> "$LOGIC_CONF.tmp"
        else
            printf '%s\n' "$line" >> "$LOGIC_CONF.tmp"
        fi
    done < "$LOGIC_CONF"
    mv -f "$LOGIC_CONF.tmp" "$LOGIC_CONF"
}

exit_edit_members() {  # $1=节点名
    local node="$1" num midx proto host port method pass fam tp val reason methods m msel i
    while :; do
        title "成员管理：$node"
        printf '  %-4s %-18s %-6s %-6s %-22s\n' "序号" "协议" "出站" "接入" "地址"
        subline
        while IFS='|' read -r a1 a2 a3 a4 a5 a6 a7 a8 a9; do
            case "$a1" in ''|'#'*) continue ;; esac
            [ "$a1" = "$node" ] || continue
            printf '  %-4s %-18s %-6s %-6s %-22s\n' "$a2" "$(proto_label "$a3")" "$a8" "${a9:-auto}" "$([ "$a3" = direct ] && echo 本机直出 || echo "${a4:-—}:${a5:-—}")"
        done < "$LOGIC_CONF"
        subline
        printf '输入成员序号修改（0 返回）: '; read -r num || return 0
        case "$num" in 0|"") return 0 ;; esac
        midx="$num"
        local ml
        ml="$(awk -F'|' -v n="$node" -v i="$midx" '$1==n && $2==i' "$LOGIC_CONF" 2>/dev/null | head -1)"
        [ -n "$ml" ] || { err "没有这个成员"; pause_back; continue; }
        IFS='|' read -r _ proto host port method pass fam tp <<< "$ml"
        if [ "$proto" = "direct" ]; then
            info "本机直出成员，没有可改的字段（地址/端口/密码都不用填）"
            pause_back; continue
        fi
        printf '    %s[1]%s 地址（当前 %s）\n' "$GREEN" "$NC" "$host"
        printf '    %s[2]%s 端口（当前 %s）\n' "$GREEN" "$NC" "$port"
        printf '    %s[3]%s 加密方式（当前 %s）\n' "$GREEN" "$NC" "$method"
        printf '    %s[4]%s 密码（已设置则不显示）\n' "$GREEN" "$NC"
        printf '    %s[5]%s 出站家族（当前 %s）\n' "$GREEN" "$NC" "$fam"
        printf '    %s[6]%s 接入家族（当前 %s）\n' "$GREEN" "$NC" "${tp:-auto}"
        printf '    %s[0]%s 返回\n' "$YELLOW" "$NC"
        printf '请选择: '; read -r msel || return 0
        case "$msel" in
            0|"") continue ;;
            1) printf '新地址（0 返回）: '; read -r val || return 0
               case "$val" in 0|"") continue ;; esac
               edit_logic_member_field "$node" "$midx" 4 "$val" ;;
            2) printf '新端口（0 返回）: '; read -r val || return 0
               case "$val" in 0|"") continue ;; esac
               case "$val" in *[!0-9]*) err "端口必须是数字"; continue ;; esac
               edit_logic_member_field "$node" "$midx" 5 "$val" ;;
            3) if [ "$proto" = "ss2022" ]; then
                   methods="2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305"
               else
                   methods="aes-256-gcm aes-192-gcm aes-128-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305"
               fi
               i=1; for m in $methods; do printf '  %s[%s]%s %s\n' "$GREEN" "$i" "$NC" "$m"; i=$((i + 1)); done
               printf '请选择 [1-%s]: ' "$((i - 1))"; read -r msel || return 0
               val="$(printf '%s\n' $methods | sed -n "${msel}p")"
               [ -n "$val" ] || { err "无效选择"; continue; }
               edit_logic_member_field "$node" "$midx" 6 "$val" ;;
            4) while :; do
                   printf '新密码（0 返回）: '; read -r val || return 0
                   case "$val" in 0|"") break ;; esac
                   if [ "$proto" = "ss2022" ]; then
                       if np="$(ss2022_pass_check "$method" "$val")"; then
                           [ "$np" != "$val" ] && info "已自动补齐 base64 填充"
                           val="$np"
                       else
                           err "密码不符合 $method 的格式：$np"; continue
                       fi
                   fi
                   edit_logic_member_field "$node" "$midx" 7 "$val"; break
               done ;;
            5) printf '出站家族 [1] IPv4 [2] IPv6（0 返回）: '; read -r val || return 0
               case "$val" in 0|"") continue ;; 2) val="v6" ;; 1) val="v4" ;; *) continue ;; esac
               edit_logic_member_field "$node" "$midx" 8 "$val" ;;
            6) printf '接入家族 [1] IPv4 [2] IPv6 [3] 与出站相同（0 返回）: '; read -r val || return 0
               case "$val" in 0|"") continue ;; 1) val="v4" ;; 2) val="v6" ;; 3) val="auto" ;; *) continue ;; esac
               edit_logic_member_field "$node" "$midx" 9 "$val" ;;
            *) echo "无效选择"; sleep 1; continue ;;
        esac
        info "正在重新下发 ..."
        apply_all
        pause_back
    done
}

exit_add_extend() {
    # 本机某个家族只能直出时，用远端节点补另一个家族，凑成双栈出口
    local b4 b6 g4 g6 localfam remfam name proto method pass host port m msel methods i reason mark expect
    clear_if_tty
    title "新增混合出口（本机直出一族 + 远端出另一族）"
    b4="$(bridge_ipv4 2>/dev/null)"; b6="$(bridge_ipv6 2>/dev/null)"
    g4=0; g6=0
    ip -4 route show default 2>/dev/null | grep -q default && g4=1
    ip -6 route show default 2>/dev/null | grep -q default && g6=1
    printf '  %-22s %s\n' "宿主机 IPv4 出网" "$([ "$g4" = 1 ] && echo 有 || echo 无)"
    printf '  %-22s %s\n' "宿主机 IPv6 出网" "$([ "$g6" = 1 ] && echo 有 || echo 无)"
    printf '  %-22s %s\n' "网桥 IPv4" "${b4:-未启用}"
    printf '  %-22s %s\n' "网桥 IPv6" "${b6:-未启用}"
    subline
    if [ "$g4" = "0" ] && [ "$g6" = "0" ]; then
        err "本机既没有 IPv4 也没有 IPv6 出网，无法做混合出口"
        pause_back; return 1
    fi
    if [ "$g4" = "1" ] && [ "$g6" = "1" ]; then
        info "本机是双栈：可以保留一族直出，让远端只出另一族"
        printf '  选择本机直出的地址族（另一族交给远端）:\n'
        printf '    %s[1]%s IPv4 本机直出，远端出 IPv6\n' "$GREEN" "$NC"
        printf '    %s[2]%s IPv6 本机直出，远端出 IPv4\n' "$GREEN" "$NC"
        printf '    %s[0]%s 返回\n' "$YELLOW" "$NC"
        printf '请输入 [0-2]: '; read -r fs1 || return 0
        case "$fs1" in
            0|"") info "已取消"; return 0 ;;
            2) localfam="v6"; remfam="v4" ;;
            *) localfam="v4"; remfam="v6" ;;
        esac
    elif [ "$g4" = "1" ]; then
        localfam="v4"; remfam="v6"
        info "本机只有 IPv4：IPv4 走本机直出，远端补 IPv6 出站"
    else
        localfam="v6"; remfam="v4"
        info "本机只有 IPv6：IPv6 走本机直出，远端补 IPv4 出站"
    fi
    # 网桥必须有"远端那一族"的地址，否则容器产生不了该族流量
    if [ "$remfam" = "v6" ] && [ -z "$b6" ]; then
        err "网桥没有 IPv6 地址：容器不会有 IPv6 流量，混合出口无从生效"
        info "请先到 菜单 [17] → [1] 辅助功能 · 网桥地址族 里开启网桥 IPv6，再回来做。";
        pause_back; return 1
    fi
    if [ "$remfam" = "v4" ] && [ -z "$b4" ]; then
        err "网桥没有 IPv4 地址：容器不会有 IPv4 流量，混合出口无从生效"
        info "请先到 菜单 [17] → [1] 辅助功能 · 网桥地址族 里开启网桥 IPv4，再回来做。";
        pause_back; return 1
    fi
    subline
    printf '节点名称（如 双栈-拓展，输入 0 取消）: '; read -r name || return 0
    case "$name" in 0|"") info "已取消"; return 0 ;; esac
    exit_exists "$name" && { err "出口已存在: $name"; pause_back; return 1; }
    while :; do
        printf '\n远端节点协议：\n'
        printf '  %s[1]%s Shadowsocks 2022（推荐）\n' "$GREEN" "$NC"
        printf '  %s[2]%s Shadowsocks（经典版）\n' "$GREEN" "$NC"
        printf '  %s[0]%s 返回上一步（重新输入节点名称）\n' "$YELLOW" "$NC"
        printf '请输入 [0-2]（回车=1）: '
        read -r msel || return 0
        case "$msel" in
            0) info "已返回节点名称输入"
               printf '节点名称: '; read -r name || return 0
               case "$name" in 0|"") info "已取消"; return 0 ;; esac
               continue ;;
            2) proto="ss" ;;
            *) proto="ss2022" ;;
        esac
        if [ "$proto" = "ss2022" ]; then
            methods="2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305"
        else
            methods="aes-256-gcm aes-192-gcm aes-128-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305"
        fi
        printf '加密方式：\n'
        i=1
        for m in $methods; do printf '  %s[%s]%s %s\n' "$GREEN" "$i" "$NC" "$m"; i=$((i + 1)); done
        printf '  %s[0]%s 返回上一步（重新选协议）\n' "$YELLOW" "$NC"
        printf '请选择 [0-%s]: ' "$((i - 1))"
        read -r msel || return 0
        case "$msel" in 0|"") continue ;; esac
        case "$msel" in *[!0-9]*) err "请输入序号"; continue ;; esac
        method="$(printf '%s\n' $methods | sed -n "${msel}p")"
        [ -n "$method" ] || { err "无效选择"; continue; }
        printf '服务器地址（输入 0 返回上一步）: '; read -r host || return 0
        case "$host" in 0|"") continue ;; esac
        # 隧道走的是“本机能出网”的那个家族，域名必须能解析出该家族的记录
        if [ "$localfam" = "v4" ]; then
            getent ahostsv4 "$host" >/dev/null 2>&1 \
                || warn "$host 没有 IPv4（A 记录）：本机只有 IPv4，隧道可能连不上"
        else
            getent ahostsv6 "$host" >/dev/null 2>&1 \
                || warn "$host 没有 IPv6（AAAA 记录）：本机只有 IPv6，隧道可能连不上"
        fi
        printf '端口（输入 0 返回上一步）: '; read -r port || return 0
        case "$port" in 0|"") continue ;; esac
        case "$port" in *[!0-9]*) err "端口必须是数字"; continue ;; esac
        while :; do
            printf '密码（输入 0 返回上一步）: '; read -r pass || return 0
            case "$pass" in 0|"") break ;; esac
            if [ "$proto" = "ss2022" ]; then
                if np="$(ss2022_pass_check "$method" "$pass")"; then
                    [ "$np" != "$pass" ] && info "已自动补齐 base64 填充"
                    pass="$np"; break
                fi
                err "密码不符合 $method 的格式：$np"
                continue
            fi
            break
        done
        [ -n "$pass" ] || continue
        break
    done
    printf '期望出口 IP（可留空，输入 0 取消整个节点）: '; read -r expect || return 0
    case "$expect" in 0) info "已取消"; return 0 ;; esac
    mark="$(mark_next)"
    # 成员 1：本机直出（占 localfam 槽）；成员 2：远端节点（占 remfam 槽，走 localfam 接入）
    printf '%s|1|direct||0|||%s|auto\n' "$name" "$localfam" >> "$LOGIC_CONF"
    printf '%s|2|%s|%s|%s|%s|%s|%s|%s\n' "$name" "$proto" "$host" "$port" "$method" "$pass" "$remfam" "$localfam" >> "$LOGIC_CONF"
    printf '%s|logic||0|||%s||||%s|1|\n' "$name" "$mark" "$expect" >> "$EXITS_CONF"
    ok "已新增混合出口 $name（$(proto_label "$proto") 补 $remfam，mark $mark）"
    info "IPv$([ "$localfam" = v4 ] && echo 4 || echo 6) 目标走本机直出；IPv$([ "$remfam" = v4 ] && echo 4 || echo 6) 目标走远端节点"
    info "正在下发规则 ..."
    apply_all
    pause_back
}

exit_add() {
    local name proto host port method pass wgkey wgif local expect mark lp reason host6 tunnel
    local methods m msel i proto_sel step="proto" owner np cand ssn
    clear_if_tty
    title "新增出口节点"
    while :; do
        case "$step" in
        proto)
            printf '协议类型：\n'
            printf '  %s[1]%s Shadowsocks 2022（推荐）\n' "$GREEN" "$NC"
            printf '  %s[2]%s Shadowsocks（经典版）\n' "$GREEN" "$NC"
            printf '  %s[3]%s WireGuard\n' "$GREEN" "$NC"
            printf '  %s[4]%s 逻辑节点（2 台机器拼 IPv4 + IPv6）\n' "$GREEN" "$NC"
            printf '  %s[5]%s 混合出口（本机直出一族 + 远端出另一族）\n' "$GREEN" "$NC"
            printf '  %s[0]%s 返回上一级\n' "$YELLOW" "$NC"
            printf '请输入 [0-5]: '
            read -r proto_sel || return 0
            case "$proto_sel" in
                0|"") info "已取消"; return 0 ;;
                1) proto="ss2022" ;;
                2) proto="ss" ;;
                3) proto="wg" ;;
                4) exit_add_logic; return $? ;;
                5) exit_add_extend; return $? ;;
                *) err "无效选择"; sleep 1; continue ;;
            esac
            case "$proto" in
                ss|ss2022) singbox_installed || {
                        err "还没有安装 sing-box（Shadowsocks / Shadowsocks 2022 客户端）"
                        info "请先到菜单 [15] → [3] 安装"; pause_back; return 1; } ;;
                wg) wg_installed || {
                        err "还没有安装 wireguard-tools"
                        info "请先到菜单 [15] → [2] 安装"; pause_back; return 1; } ;;
            esac
            step="name"
            ;;
        name)
            printf '名称（如 香港-01，输入 0 返回上一步）: '; read -r name || return 0
            case "$name" in 0|"") info "已返回协议选择"; step="proto"; continue ;; esac
            exit_exists "$name" && { err "出口已存在: $name"; continue; }
            step="host"
            ;;
        host)
            printf '服务器地址（IPv4 / IPv6 / 域名，输入 0 返回上一步）: '; read -r host || return 0
            case "$host" in 0|"") info "已返回名称输入"; step="name"; continue ;; esac
            case "$host" in \[*\]) host="$(printf '%s' "$host" | tr -d '[]')" ;; esac
            case "$host" in
                *:*) warn "这是 IPv6 地址：宿主机必须已有可用的 IPv6 出网，否则连不上" ;;
            esac
            if [ "$proto" = "wg" ]; then step="wgport"; else step="method"; fi
            ;;
        method)
            if [ "$proto" = "ss2022" ]; then
                methods="2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305"
                printf '\n加密方式（Shadowsocks 2022）：\n'
            else
                methods="aes-256-gcm aes-192-gcm aes-128-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305"
                printf '\n加密方式（Shadowsocks 经典版）：\n'
            fi
            i=1
            for m in $methods; do printf '  %s[%s]%s %s\n' "$GREEN" "$i" "$NC" "$m"; i=$((i + 1)); done
            printf '  %s[0]%s 返回上一步（重新输入服务器地址）\n' "$YELLOW" "$NC"
            printf '请输入 [0-%s]: ' "$((i - 1))"
            read -r msel || return 0
            case "$msel" in 0|"") info "已返回服务器地址"; step="host"; continue ;; esac
            case "$msel" in *[!0-9]*) err "请输入序号"; continue ;; esac
            method="$(printf '%s\n' $methods | sed -n "${msel}p")"
            [ -n "$method" ] || { err "无效选择"; continue; }
            step="port"
            ;;
        port)
            printf '端口（输入 0 返回上一步）: '
            read -r port || return 0
            case "$port" in 0|"") info "已返回上一步"; step="method"; continue ;; esac
            [ -n "$port" ] || port=$([ "$proto" = "wg" ] && echo 51820 || echo 2525)
            case "$port" in *[!0-9]*) err "端口必须是数字"; continue ;; esac
            if [ "$proto" = "wg" ]; then step="wgkey"; else step="password"; fi
            ;;
        password)
            printf '密码（输入 0 返回上一步）: '; read -r pass || return 0
            case "$pass" in 0|"") info "已返回端口输入"; step="port"; continue ;; esac
            if [ "$proto" = "ss2022" ]; then
                if np="$(ss2022_pass_check "$method" "$pass")"; then
                    [ "$np" != "$pass" ] && info "已自动补齐 base64 填充：$np"
                    pass="$np"
                else
                    err "密码不符合 $method 的格式：$np"
                    info "单密钥示例: $(printf '%*s' 16 '' | tr ' ' 'A' | base64 -w0)"
                    info "双密钥示例: 两段各自 base64 后用 : 连接"
                    continue
                fi
            else
                reason="$(ss_classic_pass_check "$pass")" || { err "$reason"; continue; }
            fi
            # 双栈宿主：可选双隧道分流（v4/v6 各走自己的隧道）
            if { [ "$proto" = "ss" ] || [ "$proto" = "ss2022" ]; } && \
               ip -4 route show default 2>/dev/null | grep -q default && ip -6 route show default 2>/dev/null | grep -q default; then
                step="tunnel"
            else
                step="expect"
            fi
            ;;
        tunnel)
            printf '\n隧道模式（宿主机双栈）：\n'
            printf '  %s[1]%s 单隧道（默认）：所有目标共用一条隧道\n' "$GREEN" "$NC"
            printf '  %s[2]%s 双隧道分流：IPv4 目标走 v4 隧道、IPv6 目标走 v6 隧道\n' "$GREEN" "$NC"
            printf '  %s[0]%s 返回上一步\n' "$YELLOW" "$NC"
            printf '请输入 [0-2]（回车=1）: '; read -r tsel || return 0
            case "$tsel" in
                0) info "已返回密码输入"; step="password"; continue ;;
                2) ;;
                *) host6=""; step="expect"; continue ;;
            esac
            # 判断已填地址属于哪一族，补齐另一族
            local fam; fam="$(addr_family "$host")"
            if [ "$fam" = "v6" ]; then
                printf 'IPv4 隧道地址（IPv4 或 有 A 记录的域名，0 返回上一步）: '; read -r v4addr || return 0
                case "$v4addr" in 0|"") info "已返回模式选择"; step="tunnel"; continue ;; esac
                case "$(addr_family "$v4addr")" in
                    v4|both) ;;
                    *) err "这不是 IPv4 地址，也没有 A 记录：$v4addr"; continue ;;
                esac
                host6="$host"; host="$v4addr"
            else
                printf 'IPv6 隧道地址（IPv6 或 有 AAAA 记录的域名，0 返回上一步）: '; read -r v6addr || return 0
                case "$v6addr" in 0|"") info "已返回模式选择"; step="tunnel"; continue ;; esac
                case "$(addr_family "$v6addr")" in
                    v6|both) ;;
                    *) err "这不是 IPv6 地址，也没有 AAAA 记录：$v6addr"; continue ;;
                esac
                host6="$v6addr"
            fi
            ok "已启用双隧道：v4 → $host ；v6 → $host6"
            step="expect"
            ;;
        wgport)
            printf '端口 [51820]（输入 0 返回上一步）: '; read -r port || return 0
            case "$port" in 0|"") info "已返回服务器地址"; step="host"; continue ;; esac
            [ -n "$port" ] || port=51820
            step="wgkey"
            ;;
        wgkey)
            ensure_wg_key || { pause_back; return 1; }
            printf '出口机公钥（输入 0 返回上一步）: '; read -r wgkey || return 0
            case "$wgkey" in 0|"") info "已返回端口输入"; step="wgport"; continue ;; esac
            step="wgif"
            ;;
        wgif)
            printf '本机接口名 [wg-exitN]（输入 0 返回上一步）: '; read -r wgif || return 0
            case "$wgif" in 0|"") info "已返回出口机公钥"; step="wgkey"; continue ;; esac
            [ -n "$wgif" ] || wgif="wg-exit$(($(exits_count) + 1))"
            step="wglocal"
            ;;
        wglocal)
            printf '本机隧道地址（如 10.200.1.2/32，输入 0 返回上一步）: '; read -r local || return 0
            case "$local" in 0|"") info "已返回接口名"; step="wgif"; continue ;; esac
            method=""; pass=""
            step="expect"
            ;;
        expect)
            printf '期望出口 IP（留空=服务器地址，输入 0 返回上一步）: '; read -r expect || return 0
            case "$expect" in 0)
                info "已返回上一步"
                if [ "$proto" = "wg" ]; then step="wglocal"
                elif ip -4 route show default 2>/dev/null | grep -q default && ip -6 route show default 2>/dev/null | grep -q default; then step="tunnel"
                else step="password"; fi
                continue ;;
            esac
            [ -n "$expect" ] || expect="$host"
            mark="$(mark_next)"
            lp=""
            case "$proto" in
                ss|ss2022)
                    ssn="$(grep -v '^#' "$EXITS_CONF" 2>/dev/null | awk -F'|' '$2=="ss"||$2=="ss2022"{n++} END{print n+0}')"
                    cand=$((TPROXY_BASE + ssn + 1))
                    owner="$(port_owner "$cand" 2>/dev/null)"
                    case "$owner" in
                        ""|*sing-box*) ;;
                        *)
                            warn "默认端口 $cand 已被占用（$owner）"
                            info "老出口不受影响，只给这个新出口指定一个本地端口"
                            while :; do
                                printf ' 新出口本地端口（留空取消）: '; read -r np || return 0
                                case "$np" in ''|0) info "已取消，未做任何改动"; return 0 ;; esac
                                case "$np" in *[!0-9]*) err "请输入数字"; continue ;; esac
                                if [ "$np" -lt 1024 ] || [ "$np" -gt 65535 ]; then err "端口范围 1024-65535"; continue; fi
                                if [ -n "$(port_owner "$np" 2>/dev/null)" ]; then warn "$np 也被占用，换一个"; continue; fi
                                if grep -q "|$np\$" "$EXITS_CONF" 2>/dev/null; then warn "$np 已被其它出口使用"; continue; fi
                                lp="$np"; break
                            done
                            ;;
                    esac
                    ;;
            esac
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|1|%s|%s\n' "$name" "$proto" "$host" "$port" "$method" "$pass" "$mark" "$wgkey" "$wgif" "$local" "$expect" "$lp" "$host6" >> "$EXITS_CONF"
            ok "已新增出口 $name（$(proto_label "$proto")，mark $mark）"
            info "正在自动下发规则 ..."
            apply_all
            pause_back
            return 0
            ;;
        esac
    done
}

exit_set_enable() {
    # $1=出口名 $2=1/0
    local want="$1" val="$2" l a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14
    : > "$EXITS_CONF.tmp"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) printf '%s\n' "$l" >> "$EXITS_CONF.tmp"; continue ;; esac
        IFS='|' read -r a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 <<< "$l"
        if [ "$a1" = "$want" ]; then
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" "$a9" "$a10" "$a11" "$val" "$a13" "$a14" >> "$EXITS_CONF.tmp"
        else
            printf '%s\n' "$l" >> "$EXITS_CONF.tmp"
        fi
    done < "$EXITS_CONF"
    mv -f "$EXITS_CONF.tmp" "$EXITS_CONF"
}

exits_print_numbered() {
    # $1 = 把名称按顺序写入的文件
    local idx=1 l name proto host port meth pass mark wgkey wgif local expect enable lp st
    : > "$1"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto host port meth pass mark wgkey wgif local expect enable lp mhost6 <<< "$l"
        [ "$enable" = "0" ] && st="${YELLOW}停用${NC}" || st="${GREEN}启用${NC}"
        local tn="单"
        [ -n "${mhost6:-}" ] && tn="${GREEN}双${NC}"
        printf '  %s%2s%s  %-16s %-18s %-24s %-6s %-8s %-4b %b\n' "$GREEN" "$idx" "$NC" "$name" "$(proto_label "$proto")" "$host" "$port" "$mark" "$tn" "$st"
        printf '%s\n' "$name" >> "$1"
        idx=$((idx + 1))
    done < "$EXITS_CONF"
}

containers_print_numbered() {
    # $1 = 把容器名按顺序写入的文件
    local idx=1 n ip b
    : > "$1"
    while IFS=$'\t' read -r n ip; do
        [ -n "$n" ] || continue
        b="$(bind_get "$n" 2>/dev/null | awk -F'|' '{print $3}')"
        [ -n "$b" ] || b="入口机"
        printf '  %s%2s%s  %-22s %-16s %s\n' "$GREEN" "$idx" "$NC" "$n" "$ip" "$b"
        printf '%s\n' "$n" >> "$1"
        idx=$((idx + 1))
    done <<< "$(containers_scan 2>/dev/null)"
}

exits_show_table() {
    local f
    f="$(mktemp)"
    printf '  %-3s %-16s %-18s %-24s %-6s %-8s %-4s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "隧道" "状态"
    subline
    exits_print_numbered "$f"
    rm -f "$f"
}

exit_del() {
    local f n name
    clear_if_tty
    title "删除出口节点"
    f="$(mktemp)"
    printf '  %-3s %-16s %-18s %-24s %-6s %-8s %-4s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "隧道" "状态"
    subline
    exits_print_numbered "$f"
    subline
    printf '  输入编号 ：删除该出口\n'
    printf '  输入 99  ：删除全部出口\n'
    printf '  输入 0   ：返回\n'
    printf '请输入: '
    read -r n || return 0
    case "$n" in
        0|"") rm -f "$f"; return 0 ;;
        99)
            printf ' 确认删除全部 %s 个出口? 输入 yes: ' "$(exits_count)"
            read -r a || return 0
            [ "$a" = "yes" ] || { info "已取消"; rm -f "$f"; return 0; }
            printf '%s\n' '# 名称|协议|地址|端口|加密|密码|mark|wg公钥|wg接口|隧道本端|期望出口IP|启用|指定本地端口|第二地址(双隧道)' > "$EXITS_CONF"
            printf '%s\n' '# 容器|IPv4|出口|mark' > "$BIND_CONF"
            apply_all >/dev/null 2>&1
            ok "已删除全部出口，相关绑定已清空"
            pause_back
            rm -f "$f"
            return 0
            ;;
    esac
    case "$n" in *[!0-9]*) err "请输入编号"; rm -f "$f"; pause_back; return 1 ;; esac
    name="$(sed -n "${n}p" "$f")"
    rm -f "$f"
    [ -n "$name" ] || { err "无效编号"; pause_back; return 1; }
    grep -v "^$name|" "$EXITS_CONF" > "$EXITS_CONF.tmp"
    mv -f "$EXITS_CONF.tmp" "$EXITS_CONF"
    awk -F'|' -v n="$name" '$3!=n' "$BIND_CONF" > "$BIND_CONF.tmp" 2>/dev/null || :
    mv -f "$BIND_CONF.tmp" "$BIND_CONF"
        logic_del_node "$name" 2>/dev/null || true
    ok "已删除 $name，相关绑定已解除"
    # 网桥地址族由 菜单 [17] → [1] 管理，这里不再自动关闭
    apply_all >/dev/null 2>&1
    pause_back
}

show_exit_row() {
    local name="$1" proto="$2" host="$3" port="$4" m="$5" pw="$6" mark="$7" wgkey="$8" wgif="$9" local="${10}" expect="${11}" enable="${12}"
    local st
    [ "$enable" = "0" ] && st="${YELLOW}停用${NC}" || st="${GREEN}启用${NC}"
    printf '  %-14s %-18s %-20s %-6s %-8s %s\n' "$name" "$(proto_label "$proto")" "$host" "$port" "$mark" "$st"
}

exits_list() {
    local f n name cur
    while :; do
        clear_if_tty
        title "出口节点（启用开关）"
        f="$(mktemp)"
        printf '  %-3s %-16s %-18s %-24s %-6s %-8s %-4s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "隧道" "状态"
        subline
        exits_print_numbered "$f"
        subline
        printf '  输入编号：切换该出口 启用/停用（停用后用户端不再显示）\n'
        printf '  输入 0   ：返回\n'
        printf '请输入: '
        read -r n || return 0
        case "$n" in
            0|"") rm -f "$f"; return 0 ;;
        esac
        case "$n" in *[!0-9]*) rm -f "$f"; err "请输入编号"; sleep 1; continue ;; esac
        name="$(sed -n "${n}p" "$f")"
        rm -f "$f"
        [ -n "$name" ] || { err "无效编号"; sleep 1; continue; }
        cur="$(exit_fld "$(exit_get "$name")" 12)"
        if [ "$cur" = "0" ]; then
            exit_set_enable "$name" 1
            ok "$name 已启用"
        else
            exit_set_enable "$name" 0
            ok "$name 已停用（用户端不再显示）"
        fi
        apply_all >/dev/null 2>&1
        sleep 1
    done
}

exit_test_one() {
    local name="$1" l proto host expect rc
    l="$(exit_get "$name")" || return 1
    proto="$(exit_fld "$l" 2)"
    host="$(exit_fld "$l" 3)"
    expect="$(exit_fld "$l" 11)"
    case "$proto" in
        wg)
            local wgif ifp
            wgif="$(exit_fld "$l" 9)"
            ifp="$(curl -s --max-time 6 --interface "$wgif" https://api.ipify.org 2>/dev/null || true)"
            if [ -n "$ifp" ]; then
                printf '  %-14s %s实际出口 %s（期望 %s）%s\n' "$name" "$GREEN" "$ifp" "$expect" "$NC"
            else
                printf '  %-14s %s不可用%s\n' "$name" "$RED" "$NC"
            fi
            ;;
        ss|ss2022|logic)
            local u port
            u="mr-ss-$(exit_fld "$l" 7).service"
            port="$(exit_ss_port "$name")"
            if [ "$proto" = "logic" ]; then
                local _m _f _h
                while IFS='|' read -r _n _idx _p _h _pt _me _pa _f; do
                    case "$_n" in ''|'#'*) continue ;; esac
                    printf '  %-14s   成员 %s：%s / %s / %s:%s\n' "" "$_idx" "$(proto_label "$_p")" "$_f" "$_h" "$_pt"
                done < <(logic_members "$name")
            fi
            if systemctl is-active --quiet "$u" 2>/dev/null && ss -ltn 2>/dev/null | grep -q ":$port "; then
                printf '  %-14s %s本地 %s 就绪（端到端请在容器内实测）%s\n' "$name" "$GREEN" "$port" "$NC"
            else
                printf '  %-14s %s客户端未就绪（单元 %s / 端口 %s）%s\n' "$name" "$RED" "$u" "$port" "$NC"
            fi
            ;;
        *) printf '  %-14s 未知协议 %s\n' "$name" "$proto" ;;
    esac
}

exit_test_menu() {
    local f n name
    clear_if_tty
    title "测试出口连通性"
    f="$(mktemp)"
    printf '  %-3s %-16s %-18s %-24s %-6s %-8s %-4s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "隧道" "状态"
    subline
    exits_print_numbered "$f"
    subline
    printf '  输入编号：测试该出口    输入 all：测试全部    输入 0：返回\n'
    printf '请输入: '
    read -r n || return 0
    case "$n" in
        0|"") rm -f "$f"; return 0 ;;
        all|ALL)
            subline
            while IFS= read -r name; do
                [ -n "$name" ] && exit_test_one "$name"
            done < "$f"
            rm -f "$f"; pause_back; return 0
            ;;
    esac
    case "$n" in *[!0-9]*) err "请输入编号或 all"; rm -f "$f"; pause_back; return 1 ;; esac
    name="$(sed -n "${n}p" "$f")"
    rm -f "$f"
    [ -n "$name" ] || { err "无效编号"; pause_back; return 1; }
    subline
    exit_test_one "$name"
    pause_back
}

# ---------------------------------------------------------------- 绑定菜单

containers_list() {
    local f
    title "容器列表（含当前出口）"
    f="$(mktemp)"
    printf '  %-3s %-22s %-16s %s\n' "编号" "容器" "IPv4" "当前出口"
    subline
    containers_print_numbered "$f"
    subline
    rm -f "$f"
    pause_back
}

sel_parse_multi() {  # $1=输入 $2=上限 $3=允许 all(默认1) → 输出 "编号 编号" 或 "ALL"
    local in max tok out="" n
    in="${1//,/ }"; max="$2"
    [ -n "$in" ] || return 1
    for tok in $in; do
        case "$tok" in
            all|ALL|All|a|A|全选|全部)
                [ "${3:-1}" = "1" ] && { printf 'ALL'; return 0; }
                return 1 ;;
        esac
        case "$tok" in ''|*[!0-9]*) return 1 ;; esac
        [ "$tok" -ge 1 ] 2>/dev/null && [ "$tok" -le "$max" ] || return 1
        case " $out " in *" $tok "*) continue ;; esac
        out="$out $tok"
    done
    [ -n "$out" ] || return 1
    printf '%s' "${out# }"
}

bind_menu_choose() {
    local cf ef n e name exit_name sel picks k cnt failed
    clear_if_tty
    title "绑定容器到出口"
    cf="$(mktemp)"
    printf '  %-3s %-22s %-16s %s\n' "编号" "容器" "IPv4" "当前出口"
    subline
    containers_print_numbered "$cf"
    subline
    printf ' 支持多选：空格分隔，如 %s1 2 8%s；%sall%s = 全部容器\n' "$YELLOW" "$NC" "$YELLOW" "$NC"
    printf ' 输入容器编号（0 返回）: '; read -r n || return 0
    case "$n" in 0|"") rm -f "$cf"; info "已取消"; return 1 ;; esac
    sel="$(sel_parse_multi "$n" "$(grep -c . "$cf")")" || {
        rm -f "$cf"; err "编号无效：$n（示例：1 2 8 或 all）"; pause_back; return 1
    }
    picks=""
    if [ "$sel" = "ALL" ]; then
        picks="$(cat "$cf")"
    else
        for k in $sel; do picks="$picks$(sed -n "${k}p" "$cf")"$'\n'; done
    fi
    rm -f "$cf"
    picks="$(printf '%s' "$picks" | sed '/^$/d')"
    [ -n "$picks" ] || { err "没有可用容器"; pause_back; return 1; }
    ok "本次操作 $(printf '%s\n' "$picks" | grep -c .) 个容器"

    clear_if_tty
    ef="$(mktemp)"
    printf '  %-3s %-16s %-18s %-24s %-6s %-8s %-4s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "隧道" "状态"
    subline
    exits_print_numbered "$ef"
    subline
    printf '  输入出口编号；输入 0 = 入口机直出；直接回车 = 取消\n'
    printf '请输入: '; read -r e || return 0
    case "$e" in "") rm -f "$ef"; info "已取消"; return 1 ;; esac
    case "$e" in *[!0-9]*) rm -f "$ef"; err "请输入编号"; pause_back; return 1 ;; esac
    local cnt=0 failed=0
    if [ "$e" = "0" ]; then
        rm -f "$ef"
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            bind_clear "$name" >/dev/null 2>&1 || true
            cnt=$((cnt + 1))
        done <<< "$picks"
        ok "已把 $cnt 个容器设为入口机直出"
    else
        exit_name="$(sed -n "${e}p" "$ef")"
        rm -f "$ef"
        [ -n "$exit_name" ] || { err "无效编号"; pause_back; return 1; }
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            if bind_set "$name" "$exit_name" >/dev/null 2>&1; then
                cnt=$((cnt + 1))
            else
                failed=$((failed + 1)); warn "$name 绑定失败"
            fi
        done <<< "$picks"
        ok "已绑定 $cnt 个容器到 $exit_name$([ "$failed" -gt 0 ] && echo "（失败 $failed 个）")"
    fi
    bindings_refresh
    apply_nft_only
    pause_back
}

bind_menu_remove() {
    local f n name sel picks k cnt
    clear_if_tty
    title "解除容器绑定（回到入口机直出）"
    f="$(mktemp)"
    printf '  %-3s %-22s %-16s %s\n' "编号" "容器" "IPv4" "当前出口"
    subline
    containers_print_numbered "$f"
    subline
    printf ' 支持多选：空格分隔，如 %s1 2 8%s；%sall%s = 全部容器\n' "$YELLOW" "$NC" "$YELLOW" "$NC"
    printf ' 输入容器编号（0 返回）: '; read -r n || return 0
    case "$n" in 0|"") rm -f "$f"; info "已取消"; return 0 ;; esac
    sel="$(sel_parse_multi "$n" "$(grep -c . "$f")")" || {
        rm -f "$f"; err "编号无效：$n（示例：1 2 8 或 all）"; pause_back; return 1
    }
    picks=""
    if [ "$sel" = "ALL" ]; then
        picks="$(cat "$f")"
    else
        for k in $sel; do picks="$picks$(sed -n "${k}p" "$f")"$'\n'; done
    fi
    rm -f "$f"
    picks="$(printf '%s' "$picks" | sed '/^$/d')"
    [ -n "$picks" ] || { err "没有可用容器"; pause_back; return 1; }
    local cnt=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        bind_clear "$name" >/dev/null 2>&1 || true
        cnt=$((cnt + 1))
    done <<< "$picks"
    ok "已解除 $cnt 个容器的绑定（回到入口机直出）"
    apply_nft_only
    pause_back
}

# ---------------------------------------------------------------- 用户端菜单

pick_container() {
    # 界面全部走 stderr，只有选中的容器名走 stdout（否则会被调用方一起捕获）
    local title_txt="$1" f n name
    clear_if_tty >&2
    title "$title_txt" >&2
    f="$(mktemp)"
    printf '  %-3s %-22s %-16s %s\n' "编号" "容器" "IPv4" "当前出口" >&2
    subline >&2
    containers_print_numbered "$f" >&2
    subline >&2
    printf ' 输入容器编号（0 返回）: ' >&2
    read -r n || return 0
    case "$n" in 0|"") rm -f "$f"; info "已取消" >&2; return 1 ;; esac
    case "$n" in *[!0-9]*) rm -f "$f"; err "请输入编号" >&2; pause_back >&2; return 1 ;; esac
    name="$(sed -n "${n}p" "$f")"
    rm -f "$f"
    [ -n "$name" ] || { err "无效编号" >&2; pause_back >&2; return 1; }
    printf '%s\n' "$name"
}

client_menu() {
    while true; do
        clear_if_tty
        title "用户端 out"
        printf '  %-20s %s\n' "基准脚本" "$CLIENT_BASE"
        printf '  %-20s %s\n' "基准哈希" "$(client_hash_base 2>/dev/null || echo 未安装)"
        printf '  %-20s %s\n' "自动校验" "$(sync_timer_state)"
        subline
        printf '  %-20s %s\n' "已授权" "$(allowed_count) 个用户"
        subline
        printf '    %s[1]%s 查看授权与同步状态\n' "$GREEN" "$NC"
        printf '    %s[2]%s 授权并下发（单个用户）\n' "$GREEN" "$NC"
        printf '    %s[3]%s 撤销授权并回收（单个用户）\n' "$GREEN" "$NC"
        printf '    %s[4]%s 全部授权并下发（所有容器）\n' "$GREEN" "$NC"
        printf '    %s[5]%s 全部撤销授权并回收\n' "$GREEN" "$NC"
        printf '    %s[6]%s 校验并修复（仅已授权用户）\n' "$GREEN" "$NC"
        printf '    %s[7]%s 开启自动校验（自定义间隔，最小 5 分钟）\n' "$GREEN" "$NC"
        printf '    %s[8]%s 关闭自动校验\n' "$GREEN" "$NC"
        printf '    %s[9]%s 更新基准脚本（从指定路径）\n' "$GREEN" "$NC"
        if [ "${AUTO_GRANT:-0}" = "1" ]; then
            printf '    %s[10]%s 新容器自动授权：%s已开启%s\n' "$GREEN" "$NC" "$GREEN" "$NC"
        else
            printf '    %s[10]%s 新容器自动授权：%s未开启%s\n' "$GREEN" "$NC" "$YELLOW" "$NC"
        fi
        printf '    %s[11]%s 清理失效记录（已删除的容器）\n' "$GREEN" "$NC"
        printf '    %s[0]%s 返回上一层\n' "$YELLOW" "$NC"
        line
        printf '请输入选项 [0-11]: '
        read -r c || return 0
        case "$c" in
            1) client_status; pause_back ;;
            2) CN="$(pick_container "授权并下发" 1)" && [ -n "$CN" ] && client_grant "$CN" ;;
            3) CN="$(pick_container "撤销授权并回收" 3)" && [ -n "$CN" ] && client_revoke "$CN" ;;
            4) client_grant_all ;;
            5) client_revoke_all ;;
            6) client_sync ;;
            7) sync_timer_on; pause_back ;;
            8) sync_timer_off; pause_back ;;
            9) client_update_base ;;
            10) auto_grant_toggle; pause_back ;;
            11) clients_prune; bindings_refresh; apply_nft_only >/dev/null 2>&1; ok "清理完成"; pause_back ;;
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

auto_grant_toggle() {
    if [ "${AUTO_GRANT:-0}" = "1" ]; then
        save_main_var AUTO_GRANT 0
        AUTO_GRANT=0
        ok "已关闭：新容器不再自动授权（已授权的保持不变）"
    else
        save_main_var AUTO_GRANT 1
        AUTO_GRANT=1
        ok "已开启：定时器每次运行都会把新容器自动授权并下发 out"
        [ -n "$(sync_timer_state 2>/dev/null)" ] && sync_timer_state | grep -q 已启用 ||             warn "注意：自动校验定时器当前未开启，新容器只会在你手动执行 [6] 或 mr sync 时纳管"
    fi
}

client_update_base() {
    local src
    title "更新用户端基准脚本"
    info "当前基准: $CLIENT_BASE"
    printf '新脚本路径（输入 0 或留空取消）: '
    read -r src || return 0
    case "$src" in 0|"") info "已取消"; return 0 ;; esac
    [ -f "$src" ] || { err "文件不存在"; pause_back; return 1; }
    cp -f "$src" "$CLIENT_BASE"
    chmod 755 "$CLIENT_BASE"
    client_inject_api_url
    client_hash_base > "$CLIENT_HASH"
    ok "基准已更新，哈希 $(cat "$CLIENT_HASH")"
    info "选择菜单 2 可立即下发到全部容器"
    pause_back
}

# ---------------------------------------------------------------- 主菜单

banner_status() {
    local incus_ver bridge_gw c_count b_count exits_n
    incus_ver="$(incus version 2>/dev/null | head -1 | awk '{print $3}' || true)"
    [ -n "$incus_ver" ] || incus_ver="未安装"
    bridge_gw="$(detect_gateway)"
    exits_n="$(exits_count)"
    b_count="$(grep -v '^#' "$BIND_CONF" 2>/dev/null | grep -c '|' || true)"
    c_count="$(containers_scan 2>/dev/null | grep -c '	' || true)"
    line
    printf '        %sIncus MultiRoute 出口管理 v%s%s\n' "$CYAN" "$SCRIPT_VERSION" "$NC"
    line
    local os_name
    os_name="$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    [ -n "$os_name" ] || os_name="未知系统"
    printf '  %s系统%s    %s\n' "$BLUE" "$NC" "$os_name"
    printf '  %s版本%s    incus %s\n' "$BLUE" "$NC" "$incus_ver"
    printf '  %s网桥%s    %s（%s）\n' "$BLUE" "$NC" "$BRIDGE" "$bridge_gw"
    printf '  %s出口%s    %s 个      %s容器%s  %s 个，已绑定 %s\n' "$BLUE" "$NC" "$exits_n" "$BLUE" "$NC" "$c_count" "$b_count"
    printf '  %s用户%s    基准 %s，自动校验 %s\n' "$BLUE" "$NC" "$([ -f "$CLIENT_BASE" ] && echo 已就绪 || echo 未安装)" "$(sync_timer_state)"
    comp_line
    subline
}

menu_main() {
    while true; do
        clear_if_tty
        banner_status
        printf '  %s【出口节点】%s\n' "$CYAN" "$NC"
        printf '    %s[1]%s 出口节点列表\n' "$GREEN" "$NC"
        printf '    %s[2]%s 新增出口节点\n' "$GREEN" "$NC"
        printf '    %s[3]%s 修改出口节点\n' "$GREEN" "$NC"
        printf '    %s[4]%s 删除出口节点\n' "$GREEN" "$NC"
        printf '    %s[5]%s 测试出口连通性\n' "$GREEN" "$NC"
        printf '  %s【容器绑定】%s\n' "$CYAN" "$NC"
        printf '    %s[6]%s 容器列表（含当前出口）\n' "$GREEN" "$NC"
        printf '    %s[7]%s 绑定容器到出口\n' "$GREEN" "$NC"
        printf '    %s[8]%s 解除容器绑定\n' "$GREEN" "$NC"
        printf '    %s[9]%s 按 incus 实际状态校正\n' "$GREEN" "$NC"
        printf '  %s【用户端】%s\n' "$CYAN" "$NC"
        printf '    %s[10]%s 用户端 out 管理\n' "$GREEN" "$NC"
        printf '  %s【系统】%s\n' "$CYAN" "$NC"
        printf '    %s[11]%s 重新下发全部规则\n' "$GREEN" "$NC"
        printf '    %s[12]%s 环境体检\n' "$GREEN" "$NC"
        printf '    %s[13]%s API 服务管理\n' "$GREEN" "$NC"
        printf '    %s[14]%s 安装本脚本到系统\n' "$GREEN" "$NC"
        printf '  %s【环境】%s\n' "$CYAN" "$NC"
        printf '    %s[15]%s 依赖安装（分类选择）\n' "$GREEN" "$NC"
        printf '    %s[16]%s 检查并更新脚本（GitHub）\n' "$GREEN" "$NC"
        printf '    %s[17]%s 辅助功能（网桥地址族 / 安全加固）\n' "$GREEN" "$NC"
        printf '    %s[99]%s 一键卸载 Incus MultiRoute\n' "$RED" "$NC"
        printf '  ------------------------------------------------------------\n'
        printf '    %s[0]%s 退出\n' "$RED" "$NC"
        line
        printf '请输入选项 [0-17 / 99]: '
        read -r choice || exit 0
        case "$choice" in
            1) exits_list ;;
            2) exit_add ;;
            3) exit_edit ;;
            4) exit_del ;;
            5) exit_test_menu ;;
            6) containers_list ;;
            7) bind_menu_choose ;;
            8) bind_menu_remove ;;
            9) bindings_refresh; apply_nft_only; pause_back ;;
            10) client_menu ;;
            11) apply_all 1; pause_back ;;
            12) doctor ;;
            13) api_menu ;;
            14) install_self ;;
            15) deps_menu ;;
            16) update_menu ;;
            17) aux_menu ;;
            99) uninstall_all ;;
            0) printf '%s再见%s\n' "$YELLOW" "$NC"; exit 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------- 安装与入口

install_self() {
    local d
    d="$(cd "$(dirname "$0")" && pwd)"
    install -m 755 "$0" /usr/local/bin/mr
    if [ -f "$d/mr-api.py" ]; then
        install -m 755 "$d/mr-api.py" /usr/local/bin/mr-api.py
        ok "API 服务已安装到 /usr/local/bin/mr-api.py"
    else
        warn "同目录未找到 mr-api.py，API 服务不可用"
    fi
    api_install_unit
    systemctl enable --now mr-api >/dev/null 2>&1 || true
    if [ -f "$d/out" ]; then
        cp -f "$d/out" "$CLIENT_BASE"
        chmod 755 "$CLIENT_BASE"
        client_inject_api_url
        client_hash_base > "$CLIENT_HASH"
        ok "用户端基准脚本已就绪（hash $(cat "$CLIENT_HASH")）"
    else
        warn "同目录未找到 out，请在菜单 10 -> 5 指定基准脚本路径"
    fi
    warn "自动下发默认关闭：装完之后不会给任何容器推送 out"
    info "需要开给某个用户时：菜单 [10] -> [2] 授权并下发"
    ok "安装完成，任意位置输入 mr 即可运行菜单"
    pause_back
}

usage() {
    cat <<EOF
Incus MultiRoute 宿主机出口管理

用法:
  mr                    进入交互菜单
  mr apply              重新下发全部规则（强制重启 sing-box）
  mr apply-nft          只重建 nft 规则（绑定变化时用，不打断现有连接）
  mr refresh            按 incus 实际状态校正容器 IP 后下发
  mr sync               校验并下发用户端 out（供定时器调用）
  mr doctor             环境体检
  mr harden             为所有容器开启源 IP 防伪（IPv4/IPv6 按宿主机实际情况）
  mr --install          安装到 /usr/local/bin/mr

配置目录: $CONF_DIR
数据目录: $DATA_DIR
EOF
}

main() {
    require_root
    load_conf
    BRIDGE="${BRIDGE:-incusbr0}"
}

case "${1:-menu}" in
    menu|"")
        main; menu_main ;;
    apply)
        main; apply_all 1 ;;
    apply-nft)
        main; apply_nft_only; exit $? ;;
    refresh)
        main; bindings_refresh; apply_nft_only ;;
    sync)
        main; client_sync quiet ;;
    doctor)
        main; doctor ;;
    harden)
        main; sec_apply_all 1 ;;
    --install)
        require_root; main; install_self ;;
    help|-h|--help)
        usage ;;
    *)
        usage; exit 1 ;;
esac
