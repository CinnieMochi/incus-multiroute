#!/bin/bash
#
# Incus MultiRoute 宿主机出口管理脚本 v1.2.9
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
SS_DIR="$CONF_DIR/sslocal"
CLIENT_BASE="$DATA_DIR/client/out"
CLIENT_HASH="$CONF_DIR/client.sha256"
CLIENT_ALLOW_CONF="$CONF_DIR/clients.conf"
NFT_FILE="$DATA_DIR/mr.nft"
UNIT_DIR="/etc/systemd/system"
API_PY="/usr/local/bin/mr-api.py"
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

SCRIPT_VERSION="1.2.9"
REPO_OWNER="CinnieMochi"
REPO_NAME="incus-multiroute"
REPO_BRANCH="main"
UPDATE_BASE="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH"

BRIDGE="incusbr0"
SUBNET_GW=""
TPROXY_BASE="41000"
WG_PRIVATE_KEY=""
SS_CLIENT_CMD="/usr/local/bin/sslocal --protocol redir"

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
        echo 'TPROXY_BASE="41000"'
        echo 'WG_PRIVATE_KEY=""'
        echo 'SS_CLIENT_CMD="/usr/local/bin/sslocal --protocol redir"'
    } > "$MAIN_CONF"
    chmod 600 "$MAIN_CONF"
}

load_conf() {
    ensure_dirs
    init_main_conf
    . "$MAIN_CONF"
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
    # ss 出口的本地重定向端口 = TPROXY_BASE + 序号
    local want="$1" l i=0
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        i=$((i + 1))
        if [ "${l%%|*}" = "$want" ]; then
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

containers_scan() {
    # 输出：容器名<TAB>IPv4
    has_cmd incus || return 1
    incus list --format=csv -c n4 2>/dev/null | awk -F, '{ip=$2; sub(/ *\(.*/,"",ip); if (ip != "") printf "%s\t%s\n", $1, ip}'
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
    local elems="" redirs="" l cb
    local ts="$(date +%Y-%m-%d\ %H:%M:%S)"
    elems="$(grep -v '^#' "$BIND_CONF" 2>/dev/null | awk -F'|' 'NF>=4 && $2!="" && $4!="" {printf "%s%s : %s", (n++ ? ",\n        " : "\n        "), $2, $4}')"
    {
        echo "# 由 Incus MultiRoute 生成于 $ts —— 请勿手改"
        echo 'table inet multiroute {'
        # nft 1.0.x 要求 set/map 的右花括号在新行（同一行会报 unexpected '}'）
        printf '    set bypass4 {\n        type ipv4_addr\n        flags interval\n        elements = { 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }\n    }\n'
        if [ -n "$elems" ]; then
            printf '    map c_ip {\n        type ipv4_addr : mark\n        elements = {%s\n        }\n    }\n' "$elems"
        else
            printf '    map c_ip {\n        type ipv4_addr : mark\n    }\n'
        fi
        echo '    chain prerouting {'
        echo '        type filter hook prerouting priority -160; policy accept;'
        echo "        iifname \"$BRIDGE\" ip daddr @bypass4 return"
        echo "        iifname \"$BRIDGE\" meta mark set ip saddr map @c_ip"
        echo '    }'
        echo '    chain prerouting_nat {'
        echo '        type nat hook prerouting priority -150; policy accept;'
        echo '        meta mark 0x0 return'
        echo '        ip daddr @bypass4 return'
        exits_each emit_redirect
        echo '    }'
        echo '    chain postrouting {'
        echo '        type nat hook postrouting priority 100; policy accept;'
        echo '        oifname "wg-*" tcp flags syn tcp option maxseg size set 1380'
        echo '    }'
        echo '    chain forward {'
        echo '        type filter hook forward priority 0; policy accept;'
        echo '        meta mark != 0x0 udp dport 443 counter drop'
        echo '    }'
        echo '}'
    } > "$NFT_FILE"
}

emit_redirect() {
    local name="$1" proto="$2" mark="$7" enable="${12}"
    [ "$enable" = "0" ] && return 0
    case "$proto" in
        ss|ss2022)
            local port
            port="$(exit_ss_port "$name")"
            echo "        meta mark $mark meta l4proto tcp redirect to :$port"
            echo "        meta mark $mark udp dport != 53 counter drop"
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
    wg set "$wgif" private-key "$DATA_DIR/wg.key" peer "$wgkey" endpoint "$host:$port" allowed-ips 0.0.0.0/0 persistent-keepalive 25
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

apply_ss_units() {
    local name proto host port method pass enable l cmd
    while IFS= read -r l; do
        case "$l" in ''|'#'*) continue ;; esac
        IFS='|' read -r name proto host port method pass mark wgkey wgif local expect enable <<< "$l"
        case "$proto" in ss|ss2022) ;; *) continue ;; esac
        # systemd 单元名必须是 ASCII，中文名称会被 escape 导致 systemctl 失效，这里用 mark 命名
        local u="mr-ss-$mark.service"
        if [ "$enable" = "0" ]; then
            systemctl disable --now "$u" >/dev/null 2>&1 || true
            continue
        fi
        local lport
        lport="$(exit_ss_port "$name")"
        cat > "$SS_DIR/$name.json" <<EOF
{
  "server": "$(json_esc "$host")",
  "server_port": $port,
  "password": "$(json_esc "$pass")",
  "method": "$(json_esc "$method")",
  "mode": "tcp_only"
}
EOF
        chmod 600 "$SS_DIR/$name.json"
        cat > "$UNIT_DIR/$u" <<EOF
[Unit]
Description=Incus MultiRoute sslocal ($name)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SS_CLIENT_CMD -b 127.0.0.1:$lport -c "$SS_DIR/$name.json"
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$u" >/dev/null 2>&1 || true
        systemctl restart "$u" >/dev/null 2>&1 || warn "$name: sslocal 启动失败，检查 $SS_CLIENT_CMD"
    done < "$EXITS_CONF"
    # 清理已删除出口遗留的单元
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

apply_all() {
    load_conf
    require_root
    title "下发规则"
    gen_nft
    nft delete table inet multiroute 2>/dev/null || true
    if nft -f "$NFT_FILE"; then
        ok "nft 规则已加载"
    else
        err "nft 规则加载失败，见 $NFT_FILE"
        pause_back
        return 1
    fi
    gen_wg
    apply_ss_units
    # 只做最小必要改动：ip_forward 本就是 incus 要求开启的；
    # rp_filter 仅在严格模式(1)时放宽为宽松(2)，已经是 0 或 2 就完全不去动它。
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    if [ "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)" = "1" ]; then
        sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 && info "rp_filter: 1 -> 2（策略路由必需，仅在严格模式时调整）"
    fi
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
    sed -i "s|10\.10\.0\.1:18988|$gw:18988|g" "$CLIENT_BASE"
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
    apply_all >/dev/null 2>&1 || true
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
    if [ "$(allowed_count)" = "0" ]; then
        warn "尚未授权任何用户，定时器开启后也不会有任何下发动作"
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
OnUnitActiveSec=10min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now mr-sync.timer >/dev/null 2>&1
    ok "自动校验定时器已启用（每 10 分钟）"
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
sslocal_installed() { has_cmd sslocal; }

wg_iface_count() {
    ip -o link show type wireguard 2>/dev/null | wc -l | tr -d ' '
}

ss_active_units() {
    systemctl list-units 'mr-ss-*.service' --state=running --no-legend --no-pager 2>/dev/null | wc -l | tr -d ' '
}

comp_line() {
    local wg_badge ss_badge ss_n
    if wg_installed; then wg_badge="${GREEN}已安装${NC}"; else wg_badge="${RED}未安装${NC}"; fi
    if sslocal_installed; then ss_badge="${GREEN}已安装${NC}"; else ss_badge="${RED}未安装${NC}"; fi
    ss_n="$(ss_active_units)"
    printf '  %swireguard-tools%s %b   %ssslocal%s %b（运行中 %s 个出口）\n' "$BLUE" "$NC" "$wg_badge" "$BLUE" "$NC" "$ss_badge" "$ss_n"
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

install_sslocal() {
    local arch url tmp bin suffix ver
    if sslocal_installed; then
        ver="$(sslocal --version 2>&1 | head -1)"
        case "$ver" in
            *GLIBC*) warn "已安装的 sslocal 与当前系统 glibc 不兼容，将重新安装"; rm -f /usr/local/bin/sslocal ;;
            *) ok "sslocal 已安装（$ver），跳过"; return 0 ;;
        esac
    fi
    info "尝试从 apt 安装 shadowsocks-rust ..."
    apt-get update -qq >/dev/null 2>&1 || true
    if apt-get install -y shadowsocks-rust >/dev/null 2>&1 && sslocal_installed; then
        ok "sslocal 安装完成（apt）"
        return 0
    fi
    case "$(uname -m)" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="aarch64" ;;
        *) err "不支持的架构: $(uname -m)"; return 1 ;;
    esac
    has_cmd jq || { err "需要 jq 才能解析 release 列表"; return 1; }
    tmp="$(mktemp -d)"
    # 先 musl（静态，跨发行版通用），再 gnu（动态，可能要求更新的 glibc）
    for suffix in "unknown-linux-musl.tar.xz" "unknown-linux-gnu.tar.xz"; do
        url="$(curl -s --max-time 25 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
            | jq -r '.assets[].browser_download_url' 2>/dev/null | grep -m1 "$arch-$suffix" || true)"
        [ -n "$url" ] || continue
        info "下载 $url ..."
        rm -rf "$tmp"; mkdir -p "$tmp"
        if ! curl -fsSL --max-time 180 -o "$tmp/ss.tar.xz" "$url"; then
            warn "下载失败，尝试下一个构建"
            continue
        fi
        tar -xJf "$tmp/ss.tar.xz" -C "$tmp" >/dev/null 2>&1 || tar -xf "$tmp/ss.tar.xz" -C "$tmp" >/dev/null 2>&1
        bin="$(find "$tmp" -maxdepth 2 -type f -name sslocal 2>/dev/null | head -1)"
        [ -n "$bin" ] || { warn "包里没有 sslocal，尝试下一个构建"; continue; }
        install -m 755 "$bin" /usr/local/bin/sslocal
        ver="$(/usr/local/bin/sslocal --version 2>&1 | head -1)"
        case "$ver" in
            *GLIBC*|"")
                warn "该构建无法运行（$ver），回退下一个构建"
                rm -f /usr/local/bin/sslocal
                continue
                ;;
            *)
                rm -rf "$tmp"
                ok "sslocal 安装完成（$ver）"
                return 0
                ;;
        esac
    done
    rm -rf "$tmp"
    err "sslocal 安装失败：请手动放置可运行的二进制到 /usr/local/bin/sslocal"
    return 1
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
    if sslocal_installed; then
        printf '  %-20s %s\n' "sslocal 路径" "$(command -v sslocal)"
        latest="$(curl -s --max-time 15 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null || true)"
        printf '  %-20s %s\n' "shadowsocks-rust 最新" "${latest:-未知}"
        printf ' 是否重新下载并覆盖为最新版? [y/N]: '
        read -r a
        case "$a" in
            [yY]) rm -f /usr/local/bin/sslocal
                  install_sslocal ;;
            *) info "已跳过 sslocal" ;;
        esac
    else
        info "sslocal 未安装，跳过"
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
        printf '  %s[3]%s 隧道组件 · ss\n' "$GREEN" "$NC"
        printf '        shadowsocks-rust 客户端 sslocal —— 使用 ss / ss2022 出口时必需\n'
        printf '  %s[4]%s 全部安装（1 + 2 + 3）\n' "$GREEN" "$NC"
        printf '  %s[5]%s 检查组件更新（已装的才会检查）\n' "$GREEN" "$NC"
        printf '  ------------------------------------------------------------\n'
        printf '  %s[0]%s 返回上一层\n' "$GREEN" "$NC"
        line
        printf '请输入选项 [0-4]: '
        read -r c
        case "$c" in
            1) install_base; pause_back ;;
            2) install_wireguard; pause_back ;;
            3) install_sslocal; pause_back ;;
            4) install_base; install_wireguard; install_sslocal; pause_back ;;
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
    info "不会自动卸载 wireguard-tools / sslocal 二进制，也不会动 incus 与其它面板的表"
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
    systemctl disable --now mr-sync.timer  >/dev/null 2>&1 || true
    systemctl disable --now mr-api.service >/dev/null 2>&1 || true
    while IFS='|' read -r name proto l; do
        case "$name" in ''|'#'*) continue ;; esac
        systemctl disable --now "mr-ss-$name.service" >/dev/null 2>&1 || true
    done < "$EXITS_CONF" 2>/dev/null

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
    rm -rf "$CONF_DIR" "$DATA_DIR"
    rm -f /usr/local/bin/mr /usr/local/bin/mr-api.py
    subline
    ok "卸载完成（wireguard-tools / sslocal / incus 均未改动）"
    printf '\n'
    exit 0
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
    has_cmd sslocal; check_item "sslocal（ss-rust）" "$?" "ss/ss2022 出口依赖"
    has_cmd wg;     check_item "wireguard-tools" "$?" "wg 出口依赖"
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; check_item "ip_forward=1" "$?" "转发必需"
    [ "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)" = "2" ]; check_item "rp_filter=2（loose）" "$?" "策略路由必需"
    nft list table inet multiroute >/dev/null 2>&1; check_item "nft 表 inet multiroute" "$?" "未下发过规则时属于正常"
    [ -f "$CLIENT_BASE" ]; check_item "用户端基准脚本" "$?" "$CLIENT_BASE"
    [ -n "$(client_hash_base 2>/dev/null)" ]; check_item "基准哈希" "$?" "$CLIENT_HASH"
    systemctl is-active --quiet mr-sync.timer 2>/dev/null; check_item "自动校验定时器" "$?" "菜单 11 可开启"
    local dup
    dup="$(grep -v '^#' "$EXITS_CONF" 2>/dev/null | awk -F'|' 'NF>=7 && $7!="" {print $7}' | sort | uniq -d | tr '\n' ' ')"
    if [ -n "$dup" ]; then
        printf '  %s[FAIL]%s %-26s %s\n' "$RED" "$NC" "出口 mark 重复" "$dup"
        info "重复 mark 会让两个出口抢同一张路由表，请在 [3] 删除后重新 [2] 添加"
    else
        check_item "出口 mark 唯一" 0 "无重复"
    fi
    local conflict
    conflict="$(ip rule show 2>/dev/null | grep -oE 'fwmark 0x[0-9a-fA-F]+' | awk '{print $2}' | sort -u | grep -viE '^0x1[0-9a-fA-F]{3}$' | head -5 || true)"
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
            info "这些容器可以伪造源 IP 冒用他人出口；建议："
            info "  incus config device set <容器> eth0 security.ipv4_filtering true"
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
    ok "API 服务单元已写入"
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
        printf '    %s[0]%s 返回上一层\n' "$GREEN" "$NC"
        line
        printf '请输入选项 [0-4]: '
        read -r c
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
    local name proto host port method pass wgkey wgif local expect mark l
    clear_if_tty
    title "新增出口节点"
    printf '协议类型：\n'
    printf '  %s[1]%s ss2022\n' "$GREEN" "$NC"
    printf '  %s[2]%s ss（经典）\n' "$GREEN" "$NC"
    printf '  %s[3]%s wg\n' "$GREEN" "$NC"
    printf '请输入协议 [1-3]: '
    read -r proto_sel
    case "$proto_sel" in
        1) proto="ss2022" ;;
        2) proto="ss" ;;
        3) proto="wg" ;;
        *) err "无效选择"; pause_back; return 1 ;;
    esac
    printf '名称（如 东京-01）: '; read -r name
    [ -n "$name" ] || { err "名称不能为空"; pause_back; return 1; }
    exit_exists "$name" && { err "出口已存在: $name"; pause_back; return 1; }
    printf '服务器地址: '; read -r host
    if [ "$proto" = "wg" ]; then
        printf '端口 [51820]: '; read -r port; [ -n "$port" ] || port=51820
        ensure_wg_key || { pause_back; return 1; }
        printf '出口机公钥: '; read -r wgkey
        printf '本机接口名 [wg-exit1]: '; read -r wgif; [ -n "$wgif" ] || wgif="wg-exit$(($(exits_count) + 1))"
        printf '本机隧道地址（如 10.200.1.2/32）: '; read -r local
        method=""; pass=""
    else
        printf '端口 [2525]: '; read -r port; [ -n "$port" ] || port=2525
        printf '加密方式 [2022-blake3-aes-128-gcm]: '; read -r method
        [ -n "$method" ] || method="2022-blake3-aes-128-gcm"
        printf '密码: '; read -r pass
        wgkey=""; wgif=""; local=""
    fi
    printf '期望出口 IP（留空则用服务器地址）: '; read -r expect
    [ -n "$expect" ] || expect="$host"
    mark="$(mark_next)"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|1\n' "$name" "$proto" "$host" "$port" "$method" "$pass" "$mark" "$wgkey" "$wgif" "$local" "$expect" >> "$EXITS_CONF"
    ok "已新增出口 $name（mark $mark）"
    pause_back
}

exit_del() {
    local name
    clear_if_tty
    title "删除出口节点"
    exits_each show_exit_row
    subline
    printf '请输入要删除的出口名称（0 返回）: '
    read -r name
    [ "$name" = "0" ] && return 0
    exit_exists "$name" || { err "出口不存在"; pause_back; return 1; }
    grep -v "^$name|" "$EXITS_CONF" > "$EXITS_CONF.tmp"
    mv -f "$EXITS_CONF.tmp" "$EXITS_CONF"
    awk -F'|' -v n="$name" '$4!=n' "$BIND_CONF" > "$BIND_CONF.tmp" 2>/dev/null || :
    mv -f "$BIND_CONF.tmp" "$BIND_CONF"
    ok "已删除 $name，相关绑定已解除"
    pause_back
}

show_exit_row() {
    local name="$1" proto="$2" host="$3" port="$4" m="$5" pw="$6" mark="$7" wgkey="$8" wgif="$9" local="${10}" expect="${11}" enable="${12}"
    local st
    [ "$enable" = "0" ] && st="${YELLOW}停用$NC" || st="${GREEN}启用$NC"
    printf '  %-14s %-8s %-20s %-6s %-8s %s\n' "$name" "$proto" "$host" "$port" "$mark" "$st"
}

exits_list() {
    title "出口节点"
    printf '  %-14s %-8s %-20s %-6s %-8s %s\n' "名称" "协议" "地址" "端口" "mark" "状态"
    subline
    exits_each show_exit_row
    subline
    info "共 $(exits_count) 个出口"
    pause_back
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
    local name
    clear_if_tty
    title "测试出口连通性"
    exits_each show_exit_row >/dev/null 2>&1
    printf '直接输入名称测试单个，或输入 all 全部测试（0 返回）: '
    read -r name
    [ "$name" = "0" ] && return 0
    if [ "$name" = "all" ]; then
        exits_each exit_test_one
    else
        exit_exists "$name" || { err "出口不存在"; pause_back; return 1; }
        exit_test_one "$name"
    fi
    pause_back
}

# ---------------------------------------------------------------- 绑定菜单

containers_list() {
    local n ip b
    title "容器列表"
    printf '  %-22s %-16s %s\n' "容器" "IPv4" "当前出口"
    subline
    while IFS=$'\t' read -r n ip; do
        [ -n "$n" ] || continue
        b="$(bind_get "$n" 2>/dev/null | awk -F'|' '{print $3}')"
        [ -n "$b" ] || b="入口机"
        printf '  %-22s %-16s %s\n' "$n" "$ip" "$b"
    done <<< "$(containers_scan 2>/dev/null)"
    subline
    pause_back
}

bind_menu_choose() {
    local n e
    clear_if_tty
    title "绑定容器到出口"
    printf '可选出口：\n'
    exits_each show_exit_row
    subline
    printf '容器名: '; read -r n
    [ -n "$n" ] || return 1
    printf '出口名（输入 入口机 表示直出）: '; read -r e
    [ -n "$e" ] || return 1
    if [ "$e" = "入口机" ] || [ "$e" = "-" ]; then
        bind_remove "$n"
    else
        bind_set "$n" "$e" || { pause_back; return 1; }
    fi
    bindings_refresh
    apply_all
    pause_back
}

bind_menu_remove() {
    local n
    clear_if_tty
    title "解除容器绑定"
    containers_scan 2>/dev/null | while IFS=$'\t' read -r n ip; do
        [ -n "$n" ] && printf '  %-22s %s\n' "$n" "$ip"
    done
    subline
    printf '容器名: '; read -r n
    [ -n "$n" ] || return 0
    bind_clear "$n"
    apply_all
    pause_back
}

# ---------------------------------------------------------------- 用户端菜单

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
        printf '    %s[7]%s 开启自动校验（每 10 分钟）\n' "$GREEN" "$NC"
        printf '    %s[8]%s 关闭自动校验\n' "$GREEN" "$NC"
        printf '    %s[9]%s 更新基准脚本（从指定路径）\n' "$GREEN" "$NC"
        printf '    %s[0]%s 返回上一层\n' "$GREEN" "$NC"
        line
        printf '请输入选项 [0-9]: '
        read -r c
        case "$c" in
            1) client_status; pause_back ;;
            2) printf '容器名: '; read -r cn; client_grant "$cn" ;;
            3) printf '容器名: '; read -r cn; client_revoke "$cn" ;;
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
    printf '新脚本路径（留空取消）: '
    read -r src
    [ -n "$src" ] || return 0
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
        printf '    %s[16]%s 检查并更新脚本（GitHub）\n' "$GREEN" "$NC"
        printf '    %s[99]%s 一键卸载 Incus MultiRoute\n' "$RED" "$NC"
        printf '  ------------------------------------------------------------\n'
        printf '    %s[0]%s 退出\n' "$RED" "$NC"
        line
        printf '请输入选项 [0-14 / 16 / 99]: '
        read -r choice
        case "$choice" in
            1) exits_list ;;
            2) exit_add ;;
            3) exit_del ;;
            4) exit_test_menu ;;
            5) containers_list ;;
            6) bind_menu_choose ;;
            7) bind_menu_remove ;;
            8) bindings_refresh; apply_all; pause_back ;;
            9) client_menu ;;
            10) apply_all; pause_back ;;
            11) doctor ;;
            12) api_menu ;;
            13) install_self ;;
            14) deps_menu ;;
            16) update_menu ;;
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
  mr apply              重新下发全部规则
  mr refresh            按 incus 实际状态校正容器 IP 后下发
  mr sync               校验并下发用户端 out（供定时器调用）
  mr doctor             环境体检
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
        main; apply_all ;;
    refresh)
        main; bindings_refresh; apply_all ;;
    sync)
        main; client_sync quiet ;;
    doctor)
        main; doctor ;;
    --install)
        require_root; main; install_self ;;
    help|-h|--help)
        usage ;;
    *)
        usage; exit 1 ;;
esac
