#!/bin/sh
# Incus MultiRoute 一键安装脚本
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/CinnieMochi/incus-multiroute/main/install.sh)
set -eu

REPO="CinnieMochi/incus-multiroute"
BRANCH="main"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
CONF_DIR="/etc/incus-multiroute"
DATA_DIR="/var/lib/incus-multiroute"

G="$(printf '\033[0;32m')"; R="$(printf '\033[0;31m')"; Y="$(printf '\033[1;33m')"
C="$(printf '\033[0;36m')"; N="$(printf '\033[0m')"
ok()   { printf "%s[完成]%s %s\n" "$G" "$N" "$1"; }
err()  { printf "%s[错误]%s %s\n" "$R" "$N" "$1"; }
warn() { printf "%s[警告]%s %s\n" "$Y" "$N" "$1"; }
info() { printf "%s[信息]%s %s\n" "$C" "$N" "$1"; }

[ "$(id -u)" = "0" ] || { err "请用 root 运行"; exit 1; }
command -v apt-get >/dev/null 2>&1 || { err "仅支持 Debian / Ubuntu"; exit 1; }

printf "%s\n" "============================================================"
printf "        %sIncus MultiRoute 安装程序%s\n" "$C" "$N"
printf "%s\n" "============================================================"

info "检查基础依赖 ..."
apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 有告警，继续"
for p in curl python3 nftables iproute2 jq ca-certificates; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        printf "  [跳过] %s\n" "$p"
    else
        printf "  [安装] %s\n" "$p"
        apt-get install -y "$p" >/dev/null 2>&1 || warn "$p 安装失败"
    fi
done

info "下载脚本 ..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --max-time 60 -o "$TMP/mr.sh"     "$RAW/mr.sh"     || { err "下载 mr.sh 失败"; exit 1; }
curl -fsSL --max-time 60 -o "$TMP/mr-api.py" "$RAW/mr-api.py" || { err "下载 mr-api.py 失败"; exit 1; }

bash -n "$TMP/mr.sh" 2>/dev/null || { err "mr.sh 语法校验失败，已中止"; exit 1; }
python3 -c "import py_compile; py_compile.compile('$TMP/mr-api.py', doraise=True)" >/dev/null 2>&1 \
    || { err "mr-api.py 语法校验失败，已中止"; exit 1; }

[ -f /usr/local/bin/mr ] && cp -f /usr/local/bin/mr "/usr/local/bin/mr.bak.$(date +%Y%m%d%H%M%S)" && warn "已备份旧版本"
install -m 755 "$TMP/mr.sh"     /usr/local/bin/mr
install -m 755 "$TMP/mr-api.py" /usr/local/bin/mr-api.py

mkdir -p "$CONF_DIR" "$DATA_DIR/client"

info "准备用户端 out 基准脚本 ..."
if curl -fsSL --max-time 60 -o "$DATA_DIR/client/out.tmp" "$RAW/client/out" 2>/dev/null; then
    mv -f "$DATA_DIR/client/out.tmp" "$DATA_DIR/client/out"
    chmod 755 "$DATA_DIR/client/out"
    GW="$(incus network list --format=csv 2>/dev/null | awk -F, '$2=="bridge"{print $1; exit}')"
    [ -n "$GW" ] || GW="incusbr0"
    ADDR="$(ip -4 -o addr show dev "$GW" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    if [ -n "$ADDR" ] && [ "$ADDR" != "10.10.0.1" ]; then
        sed -i "s|10\.10\.0\.1:18988|$ADDR:18988|g" "$DATA_DIR/client/out"
        info "用户端 API 地址已指向 $ADDR:18988"
    else
        info "网桥地址为 10.10.0.1，用户端脚本保持原样"
    fi
    sha256sum "$DATA_DIR/client/out" | awk '{print $1}' > "$CONF_DIR/client.sha256"
else
    warn "未取到用户端 out（可稍后在菜单 [9]->[9] 指定本地路径）"
fi

# API 监听地址默认绑定网桥网关，避免暴露到公网
if [ ! -f "$CONF_DIR/api.conf" ]; then
    GW="$(incus network list --format=csv 2>/dev/null | awk -F, '$2=="bridge"{print $1; exit}')"
    [ -n "$GW" ] || GW="incusbr0"
    ADDR="$(ip -4 -o addr show dev "$GW" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    printf 'LISTEN="%s:18988"\n' "${ADDR:-0.0.0.0}" > "$CONF_DIR/api.conf"
    info "API 监听地址: ${ADDR:-0.0.0.0}:18988"
fi

printf "%s\n" "============================================================"
ok "安装完成"
info "输入 mr 进入菜单"
warn "自动下发默认关闭：不会给任何容器推送 out"
info "需要开给某个用户：菜单 [9] -> [2] 授权并下发"
printf "%s\n" "============================================================"
