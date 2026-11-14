# IncuShlii Egress

在 Incus 宿主机上管理 LXC 用户出站出口的工具。纯 Bash + 单文件 Python API，支持 Debian 12 / Ubuntu 22.04 / 24.04。

## 它解决什么

一台宿主机上跑几十个用户的 LXC，每个用户要能自选"从哪台落地机出网"：

```
容器 → incusbr0(宿主) → nft 打身份 mark → 策略路由
                                  ├── wg   → 内核 wireguard 接口 → 出口机
                                  └── ss   → sslocal(redir) → 出口机
出口机 → 解密 / SNAT → 互联网
```

用户在容器里敲 `out` 就能切出口，宿主侧由本脚本下发与校验。

## 安装

```sh
# 把 egress.sh / egress-api.py 以及你现有的 out 客户端放到同一目录
bash egress.sh --install      # 装到 /usr/local/bin/egress
egress                        # 进菜单
```

## 菜单

```
【出口节点】 [1]列表 [2]新增 [3]删除 [4]测试
【容器绑定】 [5]容器列表 [6]绑定 [7]解绑 [8]校正
【用户端】   [9]out 管理（授权/回收/校验/定时器/更新基准）
【系统】     [10]下发 [11]体检 [12]API [13]安装 [16]更新脚本
【环境】     [14]依赖安装    [99]一键卸载
```

## 安全边界

- 本脚本只操作自建的 `inet shlii_egress` 表，不碰 `inet incus` 与其它面板的表
- 从不 `nft flush ruleset`，从不重启 `nftables.service`
- `out` 默认不下发，必须管理员逐个授权
- 建议对每个容器开启 `security.ipv4_filtering`，防伪造源 IP 冒用他人出口（菜单 [11] 会提示）
