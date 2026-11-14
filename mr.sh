#!/bin/bash
#
# Incus MultiRoute 宿主机出口管理脚本 v2.3.1
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
NFT_FILE="$DATA_DIR/mr.nft"
UNIT_DIR="/etc/systemd/system"
API_PY="/usr/local/bin/mr-api.py"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

SCRIPT_VERSION="2.3.1"
REPO_OWNER="CinnieMochi"
REPO_NAME="incus-multiroute"
REPO_BRANCH="main"
UPDATE_BASE="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH"

BRIDGE="incusbr0"
SUBNET_GW=""
TPROXY_BASE="27000"
WG_PRIVATE_KEY=""
SINGBOX_BIN="/usr/local/bin/sing-box"
TPROXY_BASE="${TPROXY_BASE:-27000}"
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
    [ -f "$EXITS_CONF" ] || printf '%s\n' '# 名称|协议|地址|端口|加密|密码|mark|wg公钥|wg接口|隧道本端|期望出口IP|启用' > "$EXITS_CONF"
    [ -f "$BIND_CONF" ]  || printf '%s\n' '# 容器|IPv4|出口|mark' > "$BIND_CONF"
    [ -f "$TOKEN_CONF" ] || { : > "$TOKEN_CONF"; chmod 600 "$TOKEN_CONF"; }
    [ -f "$CONF_DIR/api.conf" ] || printf 'LISTEN="0.0.0.0:18988"\n' > "$CONF_DIR/api.conf"
    [ -f "$CLIENT_ALLOW_CONF" ] || printf '%s\n' '# 授权使用 out 的容器，一行一个；不在本表的容器永远不会被下发' > "$CLIENT_ALLOW_CONF"
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
        echo 'WG_PRIVATE_KEY=""'
        echo 'SS_CLIENT_CMD="/usr/local/bin/sing-box run"'
    } > "$MAIN_CONF"
    chmod 600 "$MAIN_CONF"
}

load_conf() {
    ensure_dirs
    init_main_conf
    . "$MAIN_CONF"
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
        IFS='|' read -r e_name e_proto e_host e_port e_method e_pass e_mark e_wgkey e_wgif e_local e_expect e_enable <<< "$l"
        "$cb" "$e_name" "$e_proto" "$e_host" "$e_port" "$e_method" "$e_pass" "$e_mark" "$e_wgkey" "$e_wgif" "$e_local" "$e_expect" "$e_enable"
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
    # 只对 ss/ss2022 计数：wg 出口不占端口，不该挤掉端口号
    local want="$1" l i=0 name proto a1 a2 a3 a4 a5 a6 a7 a8 a9 enable
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto a1 a2 a3 a4 a5 a6 a7 a8 a9 enable <<< "$l"
        case "$proto" in ss|ss2022) ;; *) continue ;; esac
        i=$((i + 1))
        if [ "$name" = "$want" ]; then
            echo $((TPROXY_BASE + i))
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

containers_scan() {
    # 输出：容器名<TAB>IPv4
    has_cmd incus || return 1
    # 容器可能有多张网卡/多个地址：优先取网桥网段内的地址
    # （否则用户在容器里加个 dummy 地址，就会把绑定记录带偏）
    local cidr n ips a best first
    cidr="$(detect_subnet 2>/dev/null)"
    while IFS=, read -r n ips; do
        n="${n//\"/}"; ips="${ips//\"/}"
        ips="${ips%%(*}"
        best=""; first=""
        for a in $ips; do
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

bindings_refresh() {
    # 用 incus 的真实 IP 校正 bindings，容器内改 IP 也能自愈
    local l name ip changed=0
    : > "$BIND_CONF.tmp"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) printf '%s\n' "$l" >> "$BIND_CONF.tmp"; continue ;; esac
        IFS='|' read -r b_name b_ip b_exit b_mark <<< "$l"
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
    {
        echo "# 由 Incus MultiRoute 生成于 $ts —— 请勿手改"
        echo 'table inet multiroute {'
        printf '    set bypass4 {\n        type ipv4_addr\n        flags interval\n        elements = { 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }\n    }\n'
        if [ -n "$elems" ]; then
            printf '    map c_ip {\n        type ipv4_addr : mark\n        elements = {%s\n        }\n    }\n' "$elems"
        else
            printf '    map c_ip {\n        type ipv4_addr : mark\n    }\n'
        fi
        # 透明代理：TCP + UDP 都走 tproxy（需要 br_netfilter=0）
        echo '    chain prerouting {'
        echo '        type filter hook prerouting priority mangle; policy accept;'
        echo "        iifname \"$BRIDGE\" ip daddr @bypass4 return"
        echo "        iifname \"$BRIDGE\" meta mark set ip saddr map @c_ip"
        echo "        iifname \"$BRIDGE\" meta mark 0x0 return"
        # 注意：这里绝不能加 "socket transparent 1 accept"，它会把所有包直接放行走宿主，
        # 导致 tproxy 永远不执行（实测踩过这个坑）
        exits_each emit_tproxy
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

emit_tproxy() {
    local name="$1" proto="$2" mark="$7" enable="${12}"
    [ "$enable" = "0" ] && return 0
    case "$proto" in
        ss|ss2022)
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
    [ -n "$wgif" ] || { warn "$name: 缺少 wg 接口名"; return 1; }
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
    ok "$name: wg 接口 $wgif 就绪（表 $table）"
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
    has_cmd wg || { err "需要先安装 wireguard-tools（菜单 14 -> 2）"; return 1; }
    printf ' 尚未生成宿主机 wg 私钥，现在生成? [Y/n]: '
    read -r a
    case "$a" in [nN]) err "已取消"; return 1 ;; esac
    k="$(wg genkey 2>/dev/null)"
    [ -n "$k" ] || { err "生成失败"; return 1; }
    pub="$(printf '%s' "$k" | wg pubkey 2>/dev/null)"
    save_main_var WG_PRIVATE_KEY "$k"
    WG_PRIVATE_KEY="$k"
    ok "已生成并保存宿主机 wg 私钥"
    printf ' %s宿主机公钥%s（填进出口机 wg 配置的 [Peer] PublicKey）:\n  %s%s%s\n' "$BLUE" "$NC" "$GREEN" "$pub" "$NC"
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
    local n=0 l name proto a1 a2 a3 a4 a5 a6 a7 a8 a9 enable
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto a1 a2 a3 a4 a5 a6 a7 a8 a9 enable <<< "$l"
        case "$proto" in
            ss|ss2022) [ "${enable:-1}" != "0" ] && n=$((n + 1)) ;;
        esac
    done < "$EXITS_CONF"
    echo "$n"
}

tproxy_routing_on() {
    ip rule del fwmark 0x80000001 lookup 1001 2>/dev/null || true
    ip rule add fwmark 0x80000001 lookup 1001 priority 900 2>/dev/null || true
    ip route replace local 0.0.0.0/0 dev lo table 1001 2>/dev/null || true
}

tproxy_routing_off() {
    ip rule del fwmark 0x80000001 lookup 1001 2>/dev/null || true
    ip route flush table 1001 2>/dev/null || true
}

ensure_tproxy_sysctl() {
    local cur
    cur="$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo 1)"
    if [ "$cur" != "0" ]; then
        printf '%s\n' '# Incus MultiRoute：TPROXY 需要关闭 br_netfilter 对桥接帧的劫持' \
            'net.bridge.bridge-nf-call-iptables = 0' > /etc/sysctl.d/90-incus-multiroute.conf
        sysctl -qw net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
        warn "已关闭 net.bridge.bridge-nf-call-iptables（容器间二层流量不再经过防火墙）"
    fi
}

remove_tproxy_sysctl() {
    rm -f /etc/sysctl.d/90-incus-multiroute.conf
    sysctl -qw net.bridge.bridge-nf-call-iptables=1 2>/dev/null || true
}

apply_ss_units() {
    local force="${1:-0}"
    local name proto host port method pass enable l cmd
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto host port method pass mark wgkey wgif local expect enable <<< "$l"
        case "$proto" in ss|ss2022) ;; *) continue ;; esac
        local u="mr-ss-$mark.service"
        if [ "$enable" = "0" ]; then
            systemctl disable --now "$u" >/dev/null 2>&1 || true
            continue
        fi
        local lport
        lport="$(exit_ss_port "$name")"
        if [ "$lport" -gt "$((TPROXY_BASE + 99))" ]; then
            warn "$name: 端口 $lport 超出 $TPROXY_BASE-$((TPROXY_BASE + 99)) 范围，该出口不可用"
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
        newcfg="$(cat <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "tproxy", "tag": "tproxy-in",
    "listen": "${SUBNET_GW:-0.0.0.0}", "listen_port": $lport,
    "network": ["tcp", "udp"]
  }],
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
        newunit="$(cat <<EOF
[Unit]
Description=Incus MultiRoute sing-box ($name)
After=network-online.target incus.service
Wants=network-online.target
Wants=incus.service

[Service]
Type=simple
ExecStart=$SS_CLIENT_CMD -c "$SS_DIR/$mark.json"
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
)"
        # 只有配置真的变了才重启：新增/删除/停用出口时，不能打断其它出口的连接
        local changed=1
        if [ -f "$SS_DIR/$mark.json" ] && [ -f "$UNIT_DIR/$u" ] \
            && [ "$newcfg" = "$(cat "$SS_DIR/$mark.json")" ] \
            && [ "$newunit" = "$(cat "$UNIT_DIR/$u")" ]; then
            changed=0
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
    if ! nft -c -f "$NFT_FILE" 2>/tmp/mr.nft.err; then
        err "生成的 nft 规则不合法，已保留现有规则不动"
        sed -n '1,5p' /tmp/mr.nft.err >&2
        rm -f /tmp/mr.nft.err
        return 1
    fi
    rm -f /tmp/mr.nft.err
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
    incus exec "$name" -- sh -c 'sha256sum /usr/local/bin/out 2>/dev/null | cut -d" " -f1' 2>/dev/null | tr -d '\r' | head -1
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

client_grant() {
    local name="$1"
    [ -n "$name" ] || { err "用法: client_grant 容器名"; return 1; }
    client_allowed "$name" || printf '%s\n' "$name" >> "$CLIENT_ALLOW_CONF"
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
    incus exec "$name" -- sh -c 'rm -f /usr/local/bin/out /etc/incus-egress-token' >/dev/null 2>&1 || true
    bind_remove "$name" >/dev/null 2>&1 || true
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
    read -r a
    case "$a" in
        [yY][eE][sS]) ;;
        *) info "已取消，未做任何改动"; pause_back; return 0 ;;
    esac
    for c in $names; do
        client_allowed "$c" || printf '%s\n' "$c" >> "$CLIENT_ALLOW_CONF"
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
    read -r a
    case "$a" in
        [yY][eE][sS]) ;;
        *) info "已取消，未做任何改动"; pause_back; return 0 ;;
    esac
    for c in $list; do
        incus exec "$c" -- sh -c 'rm -f /usr/local/bin/out /etc/incus-egress-token' >/dev/null 2>&1 && cnt=$((cnt + 1))
        bind_remove "$c" >/dev/null 2>&1 || true
    done
    printf '%s\n' '# 授权使用 out 的容器，一行一个；不在本表的容器永远不会被下发' > "$CLIENT_ALLOW_CONF"
    apply_nft_only >/dev/null 2>&1 || true
    subline
    ok "已回收 $cnt / $n 个容器，白名单已清空"
    pause_back
}

client_push_one() {
    local name="$1" tok tmp
    [ -f "$CLIENT_BASE" ] || { err "缺少基准脚本 $CLIENT_BASE（先在菜单 15 安装本脚本）"; return 1; }
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
}

client_sync() {
    local quiet="${1:-}" base n h pushed=0 tot=0
    base="$(client_hash_base 2>/dev/null || true)"
    [ -n "$base" ] || { [ -n "$quiet" ] || err "缺少基准脚本 $CLIENT_BASE"; return 1; }
    tot="$(allowed_count)"
    if [ "$tot" = "0" ]; then
        if [ -n "$quiet" ]; then
            return 0
        fi
        title "下发用户端 out"
        warn "当前没有任何已授权用户，未做任何下发"
        info "如需给某用户开通：菜单 [9] -> [3] 授权并下发"
        pause_back
        return 0
    fi
    local c
    for c in $(allowed_list); do
        h="$(client_hash_in "$c")"
        if [ "$h" != "$base" ]; then
            client_push_one "$c" >/dev/null 2>&1 && pushed=$((pushed + 1))
        fi
    done
    if [ -n "$quiet" ]; then
        [ "$pushed" -gt 0 ] && echo "$(date '+%F %T') 已同步 $pushed/$tot 个已授权容器" >> "$DATA_DIR/sync.log"
    else
        title "下发用户端 out"
        ok "已授权 $tot 个容器，本次推送 $pushed 个"
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
    read -r m
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
singbox_installed() { has_cmd sing-box; }

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
        ok "sing-box 已安装（$("$SINGBOX_BIN" version 2>/dev/null | head -1)），跳过"
        return 0
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
    ok "sing-box 安装完成（$ver）"
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
    read -r a
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
    read -r a
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
            read -r a
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
        read -r a
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
        printf '  %s[2]%s 隧道组件 · wg\n' "$GREEN" "$NC"
        printf '        wireguard-tools —— 使用 wg 出口时必需\n'
        printf '  %s[3]%s 隧道组件 · ss / ss2022（sing-box）\n' "$GREEN" "$NC"
        printf '        sing-box 客户端 —— 使用 ss / ss2022 出口时必需（支持 TCP+UDP）\n'
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
    read -r a
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
    ok "已更新到 v$rv"
    info "旧版本备份: $SELF_PATH.bak.*"
    info "配置未改动；重新进入菜单即可使用新版本"
    pause_back
}

# ---------------------------------------------------------------- 一键卸载

uninstall_all() {
    local ans name l proto wgif mark table
    title "一键卸载 Incus MultiRoute"
    warn "将删除：nft 表 inet multiroute、wg 出口接口与策略路由、全部 mr-* 单元、"
    warn "        /etc/incus-multiroute、/var/lib/incus-multiroute、/usr/local/bin/mr 与 mr-api.py"
    info "不会自动卸载 wireguard-tools / sing-box 二进制，也不会动 incus 与其它面板的表"
    subline
    printf ' %s第一次确认%s —— 输入 yes 继续，其它任意键取消: ' "$YELLOW" "$NC"
    read -r a1
    case "$a1" in
        [yY][eE][sS]) ;;
        *) info "已取消，未做任何改动"; pause_back; return 0 ;;
    esac
    printf ' %s第二次确认%s —— 最后机会，再次输入 yes: ' "$RED" "$NC"
    read -r a2
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
        IFS='|' read -r name proto host port meth pass mark wgkey wgif local expect enable <<< "$l"
        case "$proto" in
            ss|ss2022) systemctl disable --now "mr-ss-$mark.service" >/dev/null 2>&1 || true ;;
        esac
    done < "$EXITS_CONF" 2>/dev/null
    # 兜底：清掉任何残留的 mr-ss-* 单元
    systemctl disable --now 'mr-ss-*' >/dev/null 2>&1 || true

    info "清理 wg 接口与策略路由 ..."
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto host port meth pass mark wgkey wgif local expect enable <<< "$l"
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
        incus exec "$c" -- sh -c 'rm -f /usr/local/bin/out /etc/incus-egress-token' >/dev/null 2>&1 \
            && info "已回收 $c" || warn "$c 回收失败（容器可能已停）"
    done

    info "删除单元文件与目录 ..."
    rm -f /etc/systemd/system/mr-*.service /etc/systemd/system/mr-*.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    printf ' 是否一并卸载依赖组件 wireguard-tools / sing-box? 输入 yes 卸载（其它保留）: '
    read -r a3
    if [ "$a3" = "yes" ]; then
        if dpkg -s wireguard-tools >/dev/null 2>&1; then
            apt-get remove -y wireguard-tools >/dev/null 2>&1 && info "已卸载 wireguard-tools" || warn "wireguard-tools 卸载失败"
        fi
        rm -f "$SINGBOX_BIN" && info "已删除 sing-box"
    else
        info "已保留 wireguard-tools / sing-box（以后要用可直接复用）"
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
    for c in $(incus list --format=csv -c n 2>/dev/null | tail -n +2); do
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
    for c in $(incus list --format=csv -c n 2>/dev/null | tail -n +2); do
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
        printf '    %s[0]%s 返回
' "$YELLOW" "$NC"
        line
        printf '请输入选项 [0-4]: '
        read -r a || return 0
        case "$a" in
            0|"") return 0 ;;
            1) title "加固状态"; sec_status_table; pause_back ;;
            2)
                printf ' 确认给 %s 个容器开启防伪? 输入 yes 继续: ' "$(incus list --format=csv -c n 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
                read -r a
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
    has_cmd sing-box; check_item "sing-box" "$?" "ss/ss2022 出口依赖（TCP+UDP）"
    has_cmd wg;     check_item "wireguard-tools" "$?" "wg 出口依赖"
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; check_item "ip_forward=1" "$?" "转发必需"
    local rpv
    rpv="$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)"
    if [ "$rpv" = "2" ]; then
        check_item "rp_filter=2（loose）" 0 "策略路由已就绪"
    else
        printf '  %s[提示]%s %-26s 当前 %s；用 ss 出口不需要，用 wg 出口时建议设为 2\n' "$YELLOW" "$NC" "rp_filter" "${rpv:-未知}"
    fi
    nft list table inet multiroute >/dev/null 2>&1; check_item "nft 表 inet multiroute" "$?" "未下发过规则时属于正常"
    [ -f "$CLIENT_BASE" ]; check_item "用户端基准脚本" "$?" "$CLIENT_BASE"
    [ -n "$(client_hash_base 2>/dev/null)" ]; check_item "基准哈希" "$?" "$CLIENT_HASH"
    local pc
    pc="$(tproxy_port_conflicts 2>/dev/null)"
    if [ -n "$pc" ]; then
        printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "代理端口被占用" "$pc"
        info "端口段 $TPROXY_BASE-$((TPROXY_BASE + 99)) 归本脚本；请让用户端口映射避开"
    fi
    if ip -6 route show default 2>/dev/null | grep -q default; then
        printf '  %s[提示]%s %-26s %s\n' "$YELLOW" "$NC" "宿主机有 IPv6 出网" "容器 IPv6 流量不会走出口（只代理 IPv4），如需隐藏请禁用容器 IPv6"
    fi
    if [ "$(ss_enabled_count 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        if [ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" = "0" ]; then
            check_item "br_netfilter 已关闭" 0 "TPROXY 必需"
        else
            printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "br_netfilter 未关闭" "TPROXY 不通，按 10 重新下发"
        fi
        if ip rule show 2>/dev/null | grep -q "lookup 1001"; then
            check_item "tproxy 策略路由" 0 "fwmark 0x80000001 → table 1001"
        else
            printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "tproxy 策略路由" "缺失，按 10 重新下发"
        fi
    fi
    if systemctl is-active --quiet mr-sync.timer 2>/dev/null; then
        check_item "自动校验定时器" 0 "已启用（$(sync_timer_interval)）"
    else
        printf '  %s[提示]%s %-26s 未开启（可选功能，菜单 9 → 7 开启）\n' "$YELLOW" "$NC" "自动校验定时器"
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
    if [ -f "$BIND_CONF" ] && has_cmd incus; then
        local bc nofilter=""
        while IFS='|' read -r bc _ _ _; do
            case "$bc" in ''|'#'*) continue ;; esac
            incus config show "$bc" 2>/dev/null | grep -q 'ipv4_filtering: "true"' || nofilter="$nofilter $bc"
        done < "$BIND_CONF"
        if [ -n "$nofilter" ]; then
            printf '  %s[注意]%s %-26s %s\n' "$YELLOW" "$NC" "未开 ipv4_filtering" "$nofilter"
            info "这些容器可以伪造源 IP 发包（反射攻击 / 日志污染）"
            info "处理：菜单 [16] 安全加固 可一键开启（IPv4/IPv6 按宿主机实际情况）"
        else
            check_item "容器源 IP 防伪" 0 "已绑定容器均开启 ipv4_filtering"
        fi
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
    systemctl enable shlii-egress-api >/dev/null 2>&1 || systemctl enable mr-api >/dev/null 2>&1 || true
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

exit_add() {
    local name proto host port method pass wgkey wgif local expect mark
    local methods m msel i
    clear_if_tty
    title "新增出口节点"
    printf '协议类型：\n'
    printf '  %s[1]%s Shadowsocks 2022（推荐）\n' "$GREEN" "$NC"
    printf '  %s[2]%s Shadowsocks（经典版）\n' "$GREEN" "$NC"
    printf '  %s[3]%s WireGuard\n' "$GREEN" "$NC"
    printf '  %s[0]%s 返回上一级\n' "$YELLOW" "$NC"
    printf '请输入 [0-3]: '
    read -r proto_sel
    case "$proto_sel" in
        1) proto="ss2022" ;;
        2) proto="ss" ;;
        3) proto="wg" ;;
        0|"") info "已取消"; return 0 ;;
        *) err "无效选择"; pause_back; return 1 ;;
    esac

    # 依赖前置检查：缺客户端就不再往下问
    case "$proto" in
        ss|ss2022)
            if ! singbox_installed; then
                err "还没有安装 sing-box（ss/ss2022 客户端）"
                info "请先到 菜单 [14] → [3] 安装，装完再回来新增 $proto 出口"
                info "或在 菜单 [14] → [4] 一次装齐所有依赖"
                pause_back
                return 1
            fi
            ;;
        wg)
            if ! wg_installed; then
                err "还没有安装 wireguard-tools"
                info "请先到 菜单 [14] → [2] 安装，装完再回来新增 WireGuard 出口"
                info "或在 菜单 [14] → [4] 一次装齐所有依赖"
                pause_back
                return 1
            fi
            ;;
    esac

    printf '名称（如 香港-01，输入 0 返回）: '; read -r name
    case "$name" in 0|"") info "已取消"; return 0 ;; esac
    [ -n "$name" ] || { err "名称不能为空"; pause_back; return 1; }
    exit_exists "$name" && { err "出口已存在: $name"; pause_back; return 1; }

    printf '服务器地址（IPv4 / IPv6 / 域名，输入 0 返回）: '; read -r host
    case "$host" in 0|"") info "已取消"; return 0 ;; esac
    case "$host" in
        \[*\]) host="$(printf '%s' "$host" | tr -d '[]')" ;;
    esac
    case "$host" in
        *:*)
            warn "这是一个 IPv6 地址：宿主机必须已有可用的 IPv6 出网，否则该出口无法连接"
            info "容器侧仍然是 IPv4（10.10.0.0/22），只有宿主机到落地机这一段走 IPv6"
            ;;
    esac

    if [ "$proto" = "wg" ]; then
        info "WireGuard 的加密算法是协议固定的（ChaCha20-Poly1305），无需选择"
        printf '端口 [51820]: '; read -r port; [ -n "$port" ] || port=51820
        ensure_wg_key || { pause_back; return 1; }
        printf '出口机公钥（输入 0 返回）: '; read -r wgkey
        case "$wgkey" in 0|"") info "已取消"; return 0 ;; esac
        printf '本机接口名 [wg-exit1]: '; read -r wgif; [ -n "$wgif" ] || wgif="wg-exit$(($(exits_count) + 1))"
        printf '本机隧道地址（如 10.200.1.2/32，输入 0 返回）: '; read -r local
        case "$local" in 0|"") info "已取消"; return 0 ;; esac
        method=""; pass=""
    else
        if [ "$proto" = "ss2022" ]; then
            methods="2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305"
            printf '\n加密方式（Shadowsocks 2022）：\n'
        else
            methods="aes-256-gcm aes-192-gcm aes-128-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305"
            printf '\n加密方式（Shadowsocks 经典版）：\n'
        fi
        i=1
        for m in $methods; do
            printf '  %s[%s]%s %s\n' "$GREEN" "$i" "$NC" "$m"
            i=$((i + 1))
        done
        printf '  %s[0]%s 返回上一级\n' "$YELLOW" "$NC"
        printf '请输入 [0-%s]: ' "$((i - 1))"
        read -r msel
        case "$msel" in 0|"") info "已取消"; return 0 ;; esac
        case "$msel" in *[!0-9]*) err "请输入序号"; pause_back; return 1 ;; esac
        method="$(printf '%s\n' $methods | sed -n "${msel}p")"
        [ -n "$method" ] || { err "无效选择"; pause_back; return 1; }

        printf '端口 [2525]: '; read -r port; [ -n "$port" ] || port=2525
        printf '密码（输入 0 返回）: '; read -r pass
        case "$pass" in 0|"") info "已取消"; return 0 ;; esac
        case "$proto:$method" in
            ss2022:2022-blake3-aes-128-gcm|ss2022:2022-blake3-chacha20-poly1305)
                [ ${#pass} -ge 20 ] || warn "该算法要求 16 字节 base64 密码（通常 24 字符），当前 ${#pass} 字符，请确认" ;;
            ss2022:2022-blake3-aes-256-gcm)
                [ ${#pass} -ge 40 ] || warn "该算法要求 32 字节 base64 密码（通常 44 字符），当前 ${#pass} 字符，请确认" ;;
        esac
        wgkey=""; wgif=""; local=""
    fi

    printf '期望出口 IP（留空用服务器地址，输入 0 返回）: '; read -r expect
    case "$expect" in 0) info "已取消"; return 0 ;; esac
    [ -n "$expect" ] || expect="$host"
    mark="$(mark_next)"
    # ss 出口会独占一个本地代理端口，先确认这个端口没被别人占着
    case "$proto" in
        ss|ss2022)
            local cand owner nb ssn
            ssn="$(grep -v '^#' "$EXITS_CONF" 2>/dev/null | awk -F'|' '$2=="ss"||$2=="ss2022"{n++} END{print n+0}')"
            cand=$((TPROXY_BASE + ssn + 1))
            while :; do
                if [ "$cand" -gt "$((TPROXY_BASE + 99))" ]; then
                    err "端口段 $TPROXY_BASE-$((TPROXY_BASE + 99)) 已用尽"
                    info "请增大 TPROXY_BASE（如 28000）后重试"
                    pause_back; return 1
                fi
                owner="$(port_owner "$cand" 2>/dev/null)"
                case "$owner" in
                    *sing-box*) ;;
                    "") break ;;
                esac
                warn "端口 $cand 已被占用（$owner）"
                info "继续新增会导致这个出口起不来。可以换一个端口段基数（如 28000），或回车取消"
                printf ' 新端口段基数: '; read -r nb
                case "$nb" in ''|0) info "已取消，未做任何改动"; return 0 ;; esac
                case "$nb" in *[!0-9]*) err "请输入数字"; pause_back; return 1 ;; esac
                TPROXY_BASE="$nb"
                save_main_var TPROXY_BASE "$TPROXY_BASE"
                info "端口段已改为 $TPROXY_BASE-$((TPROXY_BASE + 99))"
                cand=$((TPROXY_BASE + ssn + 1))
            done
            ;;
    esac
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|1\n' "$name" "$proto" "$host" "$port" "$method" "$pass" "$mark" "$wgkey" "$wgif" "$local" "$expect" >> "$EXITS_CONF"
    ok "已新增出口 $name（$proto / $method，mark $mark）"
    info "正在自动下发规则（ss 出口会立即启动 sing-box）..."
    apply_all
    pause_back
}

# ---------------------------------------------------------------- 编号选择辅助

exit_set_enable() {
    # $1=出口名 $2=1/0
    local want="$1" val="$2" l a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12
    : > "$EXITS_CONF.tmp"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) printf '%s\n' "$l" >> "$EXITS_CONF.tmp"; continue ;; esac
        IFS='|' read -r a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 <<< "$l"
        if [ "$a1" = "$want" ]; then
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" "$a9" "$a10" "$a11" "$val" >> "$EXITS_CONF.tmp"
        else
            printf '%s\n' "$l" >> "$EXITS_CONF.tmp"
        fi
    done < "$EXITS_CONF"
    mv -f "$EXITS_CONF.tmp" "$EXITS_CONF"
}

exits_print_numbered() {
    # $1 = 把名称按顺序写入的文件
    local idx=1 l name proto host port meth pass mark wgkey wgif local expect enable st
    : > "$1"
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto host port meth pass mark wgkey wgif local expect enable <<< "$l"
        [ "$enable" = "0" ] && st="${YELLOW}停用${NC}" || st="${GREEN}启用${NC}"
        printf '  %s%2s%s  %-16s %-8s %-20s %-6s %-8s %b\n' "$GREEN" "$idx" "$NC" "$name" "$proto" "$host" "$port" "$mark" "$st"
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
    printf '  %-3s %-16s %-8s %-20s %-6s %-8s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "状态"
    subline
    exits_print_numbered "$f"
    rm -f "$f"
}

exit_del() {
    local f n name
    clear_if_tty
    title "删除出口节点"
    f="$(mktemp)"
    printf '  %-3s %-16s %-8s %-20s %-6s %-8s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "状态"
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
            read -r a
            [ "$a" = "yes" ] || { info "已取消"; rm -f "$f"; return 0; }
            printf '%s\n' '# 名称|协议|地址|端口|加密|密码|mark|wg公钥|wg接口|隧道本端|期望出口IP|启用' > "$EXITS_CONF"
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
    ok "已删除 $name，相关绑定已解除"
    apply_all >/dev/null 2>&1
    pause_back
}

show_exit_row() {
    local name="$1" proto="$2" host="$3" port="$4" m="$5" pw="$6" mark="$7" wgkey="$8" wgif="$9" local="${10}" expect="${11}" enable="${12}"
    local st
    [ "$enable" = "0" ] && st="${YELLOW}停用${NC}" || st="${GREEN}启用${NC}"
    printf '  %-14s %-8s %-20s %-6s %-8s %s\n' "$name" "$proto" "$host" "$port" "$mark" "$st"
}

exits_list() {
    local f n name cur
    while :; do
        clear_if_tty
        title "出口节点（启用开关）"
        f="$(mktemp)"
        printf '  %-3s %-16s %-8s %-20s %-6s %-8s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "状态"
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
        ss|ss2022)
            local u port
            u="mr-ss-$(exit_fld "$l" 7).service"
            port="$(exit_ss_port "$name")"
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
    printf '  %-3s %-16s %-8s %-20s %-6s %-8s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "状态"
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

bind_menu_choose() {
    local cf ef n e name exit_name
    clear_if_tty
    title "绑定容器到出口"
    cf="$(mktemp)"
    printf '  %-3s %-22s %-16s %s\n' "编号" "容器" "IPv4" "当前出口"
    subline
    containers_print_numbered "$cf"
    subline
    printf ' 输入容器编号（0 返回）: '; read -r n
    case "$n" in 0|"") rm -f "$cf"; info "已取消"; return 1 ;; esac
    case "$n" in *[!0-9]*) rm -f "$cf"; err "请输入编号"; pause_back; return 1 ;; esac
    name="$(sed -n "${n}p" "$cf")"
    rm -f "$cf"
    [ -n "$name" ] || { err "无效编号"; pause_back; return 1; }

    clear_if_tty
    ef="$(mktemp)"
    printf '  %-3s %-16s %-8s %-20s %-6s %-8s %s\n' "编号" "名称" "协议" "地址" "端口" "mark" "状态"
    subline
    exits_print_numbered "$ef"
    subline
    printf '  输入出口编号；输入 0 = 入口机直出；直接回车 = 取消\n'
    printf '请输入: '; read -r e
    case "$e" in "") rm -f "$ef"; info "已取消"; return 1 ;; esac
    case "$e" in *[!0-9]*) rm -f "$ef"; err "请输入编号"; pause_back; return 1 ;; esac
    if [ "$e" = "0" ]; then
        rm -f "$ef"
        bind_clear "$name"
    else
        exit_name="$(sed -n "${e}p" "$ef")"
        rm -f "$ef"
        [ -n "$exit_name" ] || { err "无效编号"; pause_back; return 1; }
        bind_set "$name" "$exit_name" || { pause_back; return 1; }
    fi
    bindings_refresh
    apply_nft_only
    pause_back
}

bind_menu_remove() {
    local f n name
    clear_if_tty
    title "解除容器绑定（回到入口机直出）"
    f="$(mktemp)"
    printf '  %-3s %-22s %-16s %s\n' "编号" "容器" "IPv4" "当前出口"
    subline
    containers_print_numbered "$f"
    subline
    printf ' 输入容器编号（0 返回）: '; read -r n
    case "$n" in 0|"") rm -f "$f"; info "已取消"; return 0 ;; esac
    case "$n" in *[!0-9]*) rm -f "$f"; err "请输入编号"; pause_back; return 1 ;; esac
    name="$(sed -n "${n}p" "$f")"
    rm -f "$f"
    [ -n "$name" ] || { err "无效编号"; pause_back; return 1; }
    bind_clear "$name"
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
        printf '    %s[0]%s 返回上一层\n' "$YELLOW" "$NC"
        line
        printf '请输入选项 [0-9]: '
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
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

client_update_base() {
    local src
    title "更新用户端基准脚本"
    info "当前基准: $CLIENT_BASE"
    printf '新脚本路径（输入 0 或留空取消）: '
    read -r src
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
        printf '    %s[3]%s 删除出口节点\n' "$GREEN" "$NC"
        printf '    %s[4]%s 测试出口连通性\n' "$GREEN" "$NC"
        printf '  %s【容器绑定】%s\n' "$CYAN" "$NC"
        printf '    %s[5]%s 容器列表（含当前出口）\n' "$GREEN" "$NC"
        printf '    %s[6]%s 绑定容器到出口\n' "$GREEN" "$NC"
        printf '    %s[7]%s 解除容器绑定\n' "$GREEN" "$NC"
        printf '    %s[8]%s 按 incus 实际状态校正\n' "$GREEN" "$NC"
        printf '  %s【用户端】%s\n' "$CYAN" "$NC"
        printf '    %s[9]%s 用户端 out 管理\n' "$GREEN" "$NC"
        printf '  %s【系统】%s\n' "$CYAN" "$NC"
        printf '    %s[10]%s 重新下发全部规则\n' "$GREEN" "$NC"
        printf '    %s[11]%s 环境体检\n' "$GREEN" "$NC"
        printf '    %s[12]%s API 服务管理\n' "$GREEN" "$NC"
        printf '    %s[13]%s 安装本脚本到系统\n' "$GREEN" "$NC"
        printf '  %s【环境】%s\n' "$CYAN" "$NC"
        printf '    %s[14]%s 依赖安装（分类选择）\n' "$GREEN" "$NC"
        printf '    %s[15]%s 检查并更新脚本（GitHub）\n' "$GREEN" "$NC"
        printf '    %s[16]%s 安全加固（源 IP 防伪）\n' "$GREEN" "$NC"
        printf '    %s[99]%s 一键卸载 Incus MultiRoute\n' "$RED" "$NC"
        printf '  ------------------------------------------------------------\n'
        printf '    %s[0]%s 退出\n' "$RED" "$NC"
        line
        printf '请输入选项 [0-16 / 99]: '
        read -r choice || exit 0
        case "$choice" in
            1) exits_list ;;
            2) exit_add ;;
            3) exit_del ;;
            4) exit_test_menu ;;
            5) containers_list ;;
            6) bind_menu_choose ;;
            7) bind_menu_remove ;;
            8) bindings_refresh; apply_nft_only; pause_back ;;
            9) client_menu ;;
            10) apply_all 1; pause_back ;;
            11) doctor ;;
            12) api_menu ;;
            13) install_self ;;
            14) deps_menu ;;
            15) update_menu ;;
            16) sec_menu ;;
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
        warn "同目录未找到 out，请在菜单 9 -> 5 指定基准脚本路径"
    fi
    warn "自动下发默认关闭：装完之后不会给任何容器推送 out"
    info "需要开给某个用户时：菜单 [9] -> [2] 授权并下发"
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
