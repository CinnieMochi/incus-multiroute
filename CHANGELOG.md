# Changelog

## v1.1.0

首个公开版本。

### 功能
- 出口节点管理：ss / ss2022 / wg 三种协议，新增 / 列表 / 删除 / 连通性测试
- 容器出口绑定：按容器选择出口，支持按 incus 实际状态自动校正 IP
- 数据面：nftables 身份标记 + 策略路由（wg 走内核接口，ss/ss2022 走 sslocal redir）
- 防泄漏：私网段全量旁路、UDP/443(QUIC) 阻断、MSS clamp
- 用户端 out 脚本分发：哈希比对，缺失或不一致才推送；**默认关闭**，按白名单逐用户授权
- 单用户授权 / 单用户回收（回收会清除容器内的 out 与令牌并解绑出口）
- 依赖安装：基础套件 / wireguard-tools / sslocal 分类安装，已装自动跳过
- 组件更新检查：仅对已安装组件生效
- 脚本自更新：从 GitHub 拉取，版本相同则提示"已是最新"，替换前做语法校验并备份旧版
- 一键卸载（输入 99，两次确认），只清理本脚本自己的对象

### 安全
- API 令牌与容器源 IP 双向绑定，未授权容器一律 403
- 令牌比较使用常量时间比较
- host-ping 入参严格校验为 IP 字面量，杜绝参数注入
- 同一容器切换出口最小间隔 2 秒，防止刷接口导致规则反复重载
- nftables 只操作自建表 `inet shlii_egress`，从不 flush ruleset、从不重启 nftables 服务
- 安装 nftables 后检测 `nftables.service` 与 `/etc/nftables.conf` 中的 `flush ruleset`（默认会清空 incus 的表），发现即提示停用
