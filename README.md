# Incus MultiRoute

在 Incus 宿主机上管理 **LXC 用户的多出口出网**：每个容器可以自选从哪台落地机出网，支持 **ss / ss2022 / wg** 三种落地协议，全程交互式菜单，不改动 Incus 自身配置。

---

## 一键安装

在 Incus 宿主机上以 root 执行**这一条命令**即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CinnieMochi/incus-multiroute/main/install.sh)
```

装完直接输入 `mr` 进入菜单。

> 安装过程只做四件事：补齐基础依赖（已装的自动跳过）、下载 mr 与 API 服务、准备用户端 out 基准脚本、写入 API 监听地址。
> **它不会启用任何定时器，也不会给任何容器下发 out** —— 授权谁使用，必须管理员在菜单里逐个操作。

---

## 它解决什么问题

一台宿主机上跑几十个用户的 LXC，每个用户希望能选"我这台机器从哪出去"：

```
[容器 c1] ──┐
[容器 c2] ──┼─→ incusbr0（宿主机，容器默认网关）
[容器 c3] ──┘        │
                     │ nft 按容器身份打 mark（只打标记，不做 NAT、不做 DNAT）
                     ▼
              ip rule fwmark → 策略路由表
                     │
        ┌────────────┴─────────────┐
        ▼                          ▼
   wg 出口（内核态）          ss/ss2022 出口（sslocal redir）
   wg-exit-a 接口             本地重定向端口 41001 / 41002 …
        │                          │
        └────────────┬─────────────┘
                     ▼
              落地机（出口机）解密 → SNAT → 互联网
```

用户在容器里敲 out 就能切换出口，宿主侧由本项目下发规则、校验客户端版本。

---

## 支持范围

| 项目 | 支持 |
|---|---|
| 宿主系统 | Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 |
| 容器管理 | Incus 7.x（实测），兼容 LXD 命名的 lxdbr0 |
| 出口协议 | ss、ss2022（2022-blake3-aes-128-gcm / 256-gcm）、wg |
| 出口客户端 | sslocal（shadowsocks-rust）、内核 wireguard |
| 用户端 | 现有 out 脚本，**无需修改**（网桥为 10.10.0.1 时零改动） |

---

## 安装后 5 步跑通

```
1. mr                          → 进入菜单
2. [2] 新增出口节点             → 填落地机 IP / 端口 / 密码（或 wg 公钥）
3. [10] 重新下发全部规则        → 宿主侧路由生效
4. [9] → [2] 授权并下发        → 只开给一个测试容器
5. 进入该容器敲 out             → 只有它能看到 out
```

确认无误后再用 `[9] → [4] 全部授权并下发`，或继续逐个授权。

---

## 菜单总览

```
============================================================
        Incus MultiRoute 出口管理 v1.2.4
============================================================
  系统    Ubuntu 22.04.5 LTS
  版本    incus 7.2
  网桥    incusbr0（10.10.0.1）
  出口    3 个      容器  34 个，已绑定 8
  用户    基准 已就绪，自动校验 未启用
  wireguard-tools 已安装   sslocal 已安装（运行中 2 个出口）
------------------------------------------------------------
  【出口节点】
    [1] 出口节点列表
    [2] 新增出口节点
    [3] 删除出口节点
    [4] 测试出口连通性
  【容器绑定】
    [5] 容器列表（含当前出口）
    [6] 绑定容器到出口
    [7] 解除容器绑定
    [8] 按 incus 实际状态校正
  【用户端】
    [9] 用户端 out 管理
  【系统】
    [10] 重新下发全部规则
    [11] 环境体检
    [12] API 服务管理
    [13] 安装本脚本到系统
  【环境】
    [14] 依赖安装（分类选择）
    [16] 检查并更新脚本（GitHub）
    [99] 一键卸载
  ------------------------------------------------------------
    [0] 退出
============================================================
```

### 二级菜单：[9] 用户端 out

| 选项 | 作用 |
|---|---|
| [1] 查看授权与同步状态 | 列出全部容器：是否授权、客户端是否一致/缺失 |
| [2] 授权并下发（单个） | 写白名单 + 推送 out 与令牌，只影响一个容器 |
| [3] 撤销授权并回收（单个） | 删白名单 + 删容器内 out/令牌 + 解绑出口 |
| [4] 全部授权并下发 | 对所有容器授权并推送，需输入 yes |
| [5] 全部撤销授权并回收 | 回收全部已授权用户，需输入 yes |
| [6] 校验并修复 | 仅遍历已授权用户，版本不一致才补推 |
| [7] / [8] 开关自动校验 | 每 10 分钟的 systemd timer，**默认关闭** |
| [9] 更新基准脚本 | 指定新的 out 文件作为基准 |

### 二级菜单：[14] 依赖安装

| 选项 | 内容 |
|---|---|
| [1] 基础套件 | nftables / iproute2 / curl / jq / python3 / ca-certificates，逐个检测、已装跳过 |
| [2] wireguard-tools | 使用 wg 出口时必需 |
| [3] sslocal | 使用 ss/ss2022 出口时必需（apt 优先，回落 GitHub 静态二进制） |
| [4] 全部安装 | 依次执行 1 → 2 → 3 |
| [5] 检查组件更新 | 只检查已安装组件，逐项询问是否更新 |

---

## 出口机部署

### 方案 A：ss2022 / ss（shadowsocks-rust）

在出口机上跑 ss-rust 服务端，记录三样填进菜单 [2]：

```json
{ "server": "203.0.113.7", "server_port": 2525,
  "password": "<base64>", "method": "2022-blake3-aes-128-gcm",
  "mode": "tcp_and_udp" }
```

宿主机侧会自动为每个 ss 出口生成一个 sslocal 单元（mr-ss-<名称>.service），redir 模式，本地端口从 41001 起。

### 方案 B：wg（WireGuard）

出口机 /etc/wireguard/wg0.conf：

```ini
[Interface]
Address    = 10.200.1.1/32
ListenPort = 51820
PrivateKey = <出口机私钥>
PostUp = sysctl -w net.ipv4.ip_forward=1; nft 'add rule ip nat POSTROUTING oifname "eth0" masquerade'

[Peer]
PublicKey  = <菜单里显示的宿主机公钥>
AllowedIPs = 10.10.0.0/22      # 只允许该网段的源地址从隧道进来（防伪造）
```

- 出口机防火墙只放行宿主机公网 IP 到 51820/UDP，不要做成开放代理。
- 宿主机侧私钥由菜单 [2] → wg 分支自动生成并保存，公钥会打印出来。

---

## 配置文件

```
/etc/incus-multiroute/
  mr.conf          主配置（网桥名、API 端口、wg 私钥、sslocal 启动命令）
  exits.conf       出口定义
  bindings.conf    容器 → 出口 绑定
  clients.conf     授权使用 out 的容器白名单
  tokens.conf      容器 → 令牌（0600）
  api.conf         API 监听地址
  client.sha256    用户端 out 基准哈希
  sslocal/         每个 ss 出口的 sslocal 配置
/var/lib/incus-multiroute/
  mr.nft           生成后的 nft 规则（可审计）
  client/out       用户端 out 基准脚本
```

exits.conf 字段（竖线分隔）：

```
名称|协议|地址|端口|加密|密码|mark|wg公钥|wg接口|隧道本端|期望出口IP|启用
东京-01|ss2022|203.0.113.7|2525|2022-blake3-aes-128-gcm|<b64>|0x1001||||203.0.113.7|1
同城-02|wg|203.0.113.9|51820|||0x1002|<公钥>|wg-exit2|10.200.2.2/32|203.0.113.9|1
```

---

## 不影响 Incus 的保证

| 关注点 | 做法 |
|---|---|
| nft 表隔离 | 只建 `inet multiroute`；inet incus、incushlii_host_guard、dstatus_* 一律不读不写 |
| 端口映射 | 自建表里**没有任何 DNAT**；nat prerouting 只对"已打 mark + 目的地非私网"的包做 redirect，私网段在最前面 return |
| 不 flush | 全文没有 nft flush ruleset，也不重启 nftables.service；只 delete table inet multiroute |
| 装 nftables 的雷 | Debian/Ubuntu 的 nftables.service 配有 flush ruleset，开机可能清空 incus 表 —— 安装时自动检测并建议停用 |
| rp_filter | 仅在严格模式(1) 时放宽为 2，已经是 0/2 不动 |
| mark 段 | 固定使用 0x1000-0x1fff，体检会扫描越界冲突 |
| 卸载 | 只删自己的表 / 单元 / 目录，以及自己授权过的容器里的 out |

---

## 安全模型

| 威胁 | 缓解 |
|---|---|
| 容器伪造源 IP 冒用他人出口 | 令牌与容器源 IP 双向绑定；建议开 security.ipv4_filtering（菜单 [11] 会列出未开启的容器） |
| 未授权容器调用 API | 四重校验：源 IP → 容器名 → 白名单 → 令牌，任一不符返回 403 |
| 令牌侧信道比较 | 使用 hmac.compare_digest |
| 参数注入 | /host-ping.txt 的 IP 参数强制用 ipaddress 校验；API 内无任何 shell 拼接 |
| 刷接口导致规则抖动 | 同容器切换最小间隔 2 秒，超限返回 429 |
| QUIC 泄漏 | 已打 mark 的流量 udp dport 443 直接丢弃，强制回落 TCP |
| API 暴露公网 | 默认只监听网桥网关地址 |

---

## 更新与卸载

- **更新**：菜单 [16]，从 GitHub 拉取 version.txt 比对，已最新则提示"已是最新版本"；有更新会显示 CHANGELOG、做语法校验、备份旧版本后替换。**只替换程序，不动 /etc/incus-multiroute**。
- **卸载**：菜单输入 99，两次输入 yes 确认。清理自己的 nft 表、wg 接口与策略路由、systemd 单元、配置目录、已授权容器里的 out；不卸载 wireguard-tools / sslocal，不碰 incus。

---

## 目录结构

```
mr.sh            宿主机主脚本（菜单 + 规则引擎）
mr-api.py        用户端 API 服务（python3 标准库）
install.sh       一键安装引导
client/out       用户端 out 基准脚本
version.txt      当前版本
CHANGELOG.md     更新日志（更新时展示）
```

---

## 常见问题

**Q：装完输入 mr 提示命令不存在？**
重新登录一次，或确认 /usr/local/bin 在 PATH 里。

**Q：容器里敲 out 连不上宿主？**
确认网桥地址与 out 里的 http://10.10.0.1:18988 一致；不一致时安装脚本会自动改写，也可以手动改那一行。

**Q：切换了出口但网页还是旧 IP？**
切换只影响**新建连接**，已建立的 TCP 不会断。关掉重开即可。

**Q：ping 不通外网？**
ss 出口只代理 TCP/UDP，ICMP 不经过隧道；这是协议限制，不是故障。

**Q：想换仓库地址做自更新？**
改 mr.sh 顶部 REPO_OWNER / REPO_NAME / REPO_BRANCH 三个变量即可。

---

## 版本

| 版本 | 说明 |
|---|---|
| v1.2.0 | 项目更名 Incus MultiRoute，命令改为 mr；新增一键安装；wg 密钥自动生成；失效单元清理；API 增加停用出口校验 |
| v1.1.0 | 首个公开版本：出口管理、容器绑定、客户端授权/回收、依赖分类安装、自更新、一键卸载 |
