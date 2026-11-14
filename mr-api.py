#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Incus MultiRoute 用户端 API
供容器内的 out 客户端调用，只做三件事：报状态、改绑定、触发下发。
鉴权：请求源 IP 必须对应某个已绑定的容器，且 X-Egress-Token 与该容器的令牌一致。
"""

import hmac
import ipaddress
import json
import os
import re
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF_DIR = "/etc/incus-multiroute"
EXITS_CONF = os.path.join(CONF_DIR, "exits.conf")
BIND_CONF = os.path.join(CONF_DIR, "bindings.conf")
TOKEN_CONF = os.path.join(CONF_DIR, "tokens.conf")
ALLOW_CONF = os.path.join(CONF_DIR, "clients.conf")
API_CONF = os.path.join(CONF_DIR, "api.conf")
EGRESS_BIN = "/usr/local/bin/mr"

LOCK = threading.Lock()
RATE = {}
RATE_LOCK = threading.Lock()
RATE_MIN_INTERVAL = 2.0   # 同一容器两次切换的最小间隔，防止刷接口导致 nft 反复重载


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip() and not l.startswith("#")]
    except FileNotFoundError:
        return []


def load_exits():
    """name -> dict"""
    out = {}
    for line in read_lines(EXITS_CONF):
        f = line.split("|")
        if len(f) < 12 and len(f) < 11:
            continue
        while len(f) < 12:
            f.append("")
        out[f[0]] = dict(name=f[0], proto=f[1], host=f[2], port=f[3],
                         method=f[4], password=f[5], mark=f[6],
                         wgkey=f[7], wgif=f[8], local=f[9],
                         expect=f[10], enable=f[11])
    return out


def load_bindings():
    out = {}
    for line in read_lines(BIND_CONF):
        f = line.split("|")
        if len(f) < 4:
            continue
        out[f[0]] = dict(name=f[0], ip=f[1], exit=f[2], mark=f[3])
    return out


def load_tokens():
    out = {}
    for line in read_lines(TOKEN_CONF):
        f = line.split("|")
        if len(f) >= 2:
            out[f[0]] = f[1]
    return out


def load_allow():
    out = set()
    for line in read_lines(ALLOW_CONF):
        out.add(line.split("|")[0].strip())
    return out


_LOOKUP = {"ts": 0.0, "map": {}}


def incus_ip_map():
    """从 incus 实时取 容器IP -> 容器名 映射（5 秒缓存）。

    绑定表里没有记录时用它兜底，避免"授权了但没绑定"就直接 403。
    """
    now = time.time()
    if now - _LOOKUP["ts"] < 5 and _LOOKUP["map"]:
        return _LOOKUP["map"]
    m = {}
    try:
        out = subprocess.run(["incus", "list", "--format=csv", "-c", "n4"],
                             capture_output=True, timeout=10).stdout
        for line in out.decode("utf-8", "ignore").splitlines():
            parts = line.split(",")
            if len(parts) < 2:
                continue
            ip = parts[1].split(" (")[0].strip()
            name = parts[0].strip()
            if ip and name:
                m[ip] = name
    except Exception:  # noqa: BLE001
        return _LOOKUP["map"]
    _LOOKUP["ts"] = now
    _LOOKUP["map"] = m
    return m


def container_by_ip(ip):
    for name, b in load_bindings().items():
        if b["ip"] == ip:
            return name
    return incus_ip_map().get(ip)


def exit_display(name):
    return name if name else "入口机"


def write_binding(name, ip, exit_name, mark):
    lines = []
    replaced = False
    with open(BIND_CONF, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("#") or not line.strip():
                lines.append(line)
                continue
            if line.split("|")[0] == name:
                lines.append("%s|%s|%s|%s" % (name, ip, exit_name, mark))
                replaced = True
            else:
                lines.append(line)
    if not replaced:
        lines.append("%s|%s|%s|%s" % (name, ip, exit_name, mark))
    tmp = BIND_CONF + ".api.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, BIND_CONF)


def clear_binding(name):
    """保留行、只清空出口与 mark：否则该容器会因“未识别来源”而再也切不回来"""
    lines = []
    ip = ""
    with open(BIND_CONF, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("#") or not line.strip():
                lines.append(line)
                continue
            parts = line.split("|")
            if parts[0] == name:
                ip = parts[1] if len(parts) > 1 else ""
                lines.append("%s|%s||" % (name, ip))
            else:
                lines.append(line)
    if not ip:
        return
    tmp = BIND_CONF + ".api.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, BIND_CONF)


def drop_binding(name):
    lines = []
    with open(BIND_CONF, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("#") or not line.strip():
                lines.append(line)
                continue
            if line.split("|")[0] == name:
                continue
            lines.append(line)
    tmp = BIND_CONF + ".api.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, BIND_CONF)


def apply_rules():
    try:
        r = subprocess.run([EGRESS_BIN, "apply"], capture_output=True, timeout=90)
        return r.returncode == 0, (r.stderr or b"").decode("utf-8", "ignore")[-400:]
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def host_ping(ip):
    # 严格校验，绝不把容器传来的字符串当参数传给 ping（防 -f 之类的选项注入）
    try:
        addr = str(ipaddress.ip_address(ip.strip()))
    except ValueError:
        return ""
    try:
        r = subprocess.run(["ping", "-c", "3", "-W", "2", addr],
                           capture_output=True, timeout=15)
        text = r.stdout.decode("utf-8", "ignore")
    except Exception:  # noqa: BLE001
        return ""
    times = re.findall(r"time=([0-9.]+)", text)
    return "\n".join(times)


class Handler(BaseHTTPRequestHandler):
    server_version = "shlii-egress/1.0"

    def log_message(self, fmt, *args):
        pass

    # ---------------- helpers

    def reply(self, body, code=200, ctype="application/json; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def jreply(self, obj, code=200):
        # 用户端 out 用 sed 's/.*"key":"\([^"]*\)".*/\1/p' 解析，必须是紧凑 JSON（冒号后不能有空格）
        self.reply(json.dumps(obj, ensure_ascii=False, separators=(",", ":")), code)

    def client_ip(self):
        return self.client_address[0]

    def auth(self):
        ip = self.client_ip()
        name = container_by_ip(ip)
        if not name:
            self.jreply({"ok": False,
                         "error": "未识别的容器来源 %s：该容器还没有身份记录，请管理员在菜单 [6] 绑定，或 [9] 重新授权" % ip}, 403)
            return None
        if name not in load_allow():
            self.jreply({"ok": False, "error": "该容器未获授权使用 out"}, 403)
            return None
        token = self.headers.get("X-Egress-Token", "")
        expect = load_tokens().get(name, "")
        if not expect or not hmac.compare_digest(token, expect):
            self.jreply({"ok": False, "error": "令牌无效"}, 403)
            return None
        return name

    def rate_ok(self, name):
        # 检查与写入必须原子，否则并发请求会同时通过，导致规则被重复下发
        with RATE_LOCK:
            now = time.time()
            last = RATE.get(name, 0)
            if now - last < RATE_MIN_INTERVAL:
                wait = round(RATE_MIN_INTERVAL - (now - last), 1)
                ok = False
            else:
                RATE[name] = now
                ok = True
        if not ok:
            self.jreply({"ok": False, "error": "操作太频繁，请 %.1f 秒后再试" % wait}, 429)
        return ok

    def current_of(self, name):
        b = load_bindings().get(name)
        return b["exit"] if b and b["exit"] else None

    # ---------------- routes

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/health":
            return self.reply("ok", 200, "text/plain; charset=utf-8")
        if path == "/host-ping.txt":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            ip = (q.get("ip") or [""])[0]
            return self.reply(host_ping(ip), 200, "text/plain; charset=utf-8")
        if path == "/split.txt":
            return self.reply("", 200, "text/plain; charset=utf-8")
        if path == "/split-targets.txt":
            return self.reply("", 200, "text/plain; charset=utf-8")
        if path == "/exits":
            name = self.auth()
            if not name:
                return
            exits = [e for e, v in load_exits().items() if v["enable"] != "0"]
            current = self.current_of(name)
            return self.jreply({"ok": True, "container": name,
                                "current": exit_display(current),
                                "exits": ["入口机"] + exits})
        return self.reply("not found", 404, "text/plain; charset=utf-8")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length).decode("utf-8", "ignore")
        form = urllib.parse.parse_qs(body)

        if path == "/use":
            name = self.auth()
            if not name:
                return
            target = (form.get("exit") or [""])[0].strip()
            if not target:
                return self.jreply({"ok": False, "error": "缺少 exit 参数"}, 400)

            bindings = load_bindings()
            ip = bindings.get(name, {}).get("ip", self.client_ip())

            if target in ("-", "入口机"):
                if not self.rate_ok(name):
                    return
                with LOCK:
                    clear_binding(name)
                    good, err = apply_rules()
                if not good:
                    return self.jreply({"ok": False, "error": "下发失败: %s" % err}, 500)
                return self.jreply({"ok": True, "current": "入口机"})

            exits = load_exits()
            if target not in exits:
                return self.jreply({"ok": False, "error": "出口不存在: %s" % target}, 404)
            if exits[target].get("enable") == "0":
                return self.jreply({"ok": False, "error": "出口已停用: %s" % target}, 409)
            if not self.rate_ok(name):
                return
            with LOCK:
                write_binding(name, ip, target, exits[target]["mark"])
                good, err = apply_rules()
            if not good:
                return self.jreply({"ok": False, "error": "下发失败: %s" % err}, 500)
            return self.jreply({"ok": True, "current": target})

        if path == "/split/use":
            return self.jreply({"ok": False, "error": "应用分流未启用"}, 501)
        return self.reply("not found", 404, "text/plain; charset=utf-8")


def listen_addr():
    try:
        with open(API_CONF, "r", encoding="utf-8") as f:
            for line in f:
                m = re.match(r'\s*LISTEN\s*=\s*"?([^"\s]+)"?', line)
                if m:
                    return m.group(1)
    except FileNotFoundError:
        # 没有 api.conf 时退回监听全部地址，并在日志里明确提示
        print("WARN: %s 不存在，API 将监听 0.0.0.0:18988（建议只绑定网桥地址）"
              % API_CONF, flush=True)
        return "0.0.0.0:18988"


def main():
    addr = listen_addr()
    host, _, port = addr.rpartition(":")
    host = host or "0.0.0.0"
    server = ThreadingHTTPServer((host, int(port)), Handler)
    print("incus-multiroute api listening on %s:%s" % (host, port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
