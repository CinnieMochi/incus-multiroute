# Changelog

## v1.3.6

### 新增
- **开机自动恢复**：新增 mr-restore.service（oneshot），重启后自动执行 mr apply 重建 nftables 规则。此前重启后规则会丢失，所有容器静默回宿主直出
- sslocal 单元加 After/Wants=incus.service，避免开机时网桥地址还没就绪导致绑定失败

### 验证
- 模拟重启（停服务 + 删 nft 表 → 拉起 enabled 单元）：容器出网从 198.51.100.10 → 192.0.2.10 → 自动恢复 198.51.100.10

## v1.3.4