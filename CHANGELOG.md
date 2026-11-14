# Changelog

## v1.2.0

项目更名为 **Incus MultiRoute**，命令改为 `mr`，新增真·一键安装。

### 新增
- **一键安装**：`bash <(curl -fsSL .../main/install.sh)` 一条命令完成
- wg 出口自动生成宿主机密钥对并打印公钥（原来是手填）
- 依赖分类安装：基础套件 / wireguard-tools / sslocal / 全部 / 检查更新
- 全部授权下发、全部撤销回收（需输入 yes）
- 脚本自更新：读远端 version.txt 比对，已最新则提示；替换前语法校验并备份
- 环境体检新增两项：外部 fwmark 越界冲突、容器未开 ipv4_filtering
- 删除出口后自动清理遗留的 sslocal 单元
- API 增加停用出口校验（409）与 api.conf 缺失告警

### 修复
- **锁定缺陷**：切回"入口机"时删除绑定行，导致该容器随后被判定为"未识别来源"，再也切不回来。改为保留行、只清空出口与 mark
- 频率限制在参数校验之前消耗额度，导致正常的首次切换被 429 误伤。改为校验通过后才计速
- `incus version` 解析取错列，导航页显示成 `incus version:`
- incus 7.2 的 `incus list --format=csv` 带 `(eth0)` 后缀，导致 IP 解析错误
- `IFS='\t'` 实际不是制表符，导致容器名与 IP 解析错位
- 项目更名后 API 仍读取旧配置路径

### 安全
- `/host-ping.txt` 的 ip 参数严格校验为 IP 字面量，杜绝 ping 选项注入
- 令牌使用 `hmac.compare_digest` 比较
- 同一容器切换最小间隔 2 秒
- 只操作自建 `inet multiroute` 表，从不 flush ruleset、从不重启 nftables.service
- 安装 nftables 后检测 `nftables.service` 的 `flush ruleset`，命中则提示停用

## v1.1.0

首个公开版本：出口管理、容器绑定、客户端授权/回收、依赖分类安装、自更新、一键卸载。
