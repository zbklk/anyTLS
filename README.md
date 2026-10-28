# AnyTLS 一键安装管理 · sing-box 官方内核 v2

独立安装的 **AnyTLS / sing-box** 中文交互管理脚本。使用 [SagerNet/sing-box](https://github.com/SagerNet/sing-box) 官方稳定版内核，支持 Debian / Ubuntu / Alpine / RHEL 系及常见 x86_64、ARM64、ARMv7 架构。原仓库 v1 脚本最后更新于 2026-06-08，本版重点解决覆盖现有 `sing-box` 服务、升级内核、证书安全和节点管理的问题。

> **重要迁移提示：v2 是独立实例，不会自动读取、修改或卸载旧版的 `/etc/sing-box` 和 `sing-box` 服务。** 如果旧节点已运行，请选用未占用的监听端口。切换客户端并确认新节点连通后，再决定是否手动停用旧节点。v2 不会覆盖旧节点，也不会自动复制旧密码。

## 快速安装

在服务器 SSH 终端使用 root 权限执行：

```bash
curl -fsSLo /tmp/install-anytls-sb.sh https://raw.githubusercontent.com/zbklk/anyTLS/main/install-anytls-sb.sh && bash /tmp/install-anytls-sb.sh
```

普通 sudo 用户可改为：

```bash
curl -fsSLo /tmp/install-anytls-sb.sh https://raw.githubusercontent.com/zbklk/anyTLS/main/install-anytls-sb.sh && sudo bash /tmp/install-anytls-sb.sh
```

**先阅读脚本并确认代码来源，再以 root 执行。** 安装脚本会修改独立的系统服务文件、证书、依赖和指定 TCP 防火墙规则。

### 管理已安装节点

以后重新运行上面的命令，即可下载当前最新版管理脚本并打开菜单；升级**管理脚本**不等于升级 sing-box **内核**。内核单独在菜单 7 更新，用户密码和节点设置不会因此改变。

## 管理菜单

| 菜单 | 功能 |
| --- | --- |
| 1 | 安装独立 AnyTLS 节点（安装中自动检测系统和架构） |
| 2 | 查看节点信息、每个用户的链接和终端二维码 |
| 3 | 新增 / 删除 AnyTLS 用户 |
| 4 | 修改监听端口、客户端地址、TLS SNI、NAT 映射端口 |
| 5 | 查询服务状态和内核版本 |
| 6 | 启动 / 停止 / 重启独立服务 |
| 7 | 从官方稳定版 Release 更新 sing-box 内核（校验 SHA-256） |
| 8 | 证书管理、更换证书和手动续签 |
| 9 | 查看服务日志 |
| 10 | 备份 / 恢复配置（包含私钥、用户凭据） |
| 11 | 卸载 v2 独立服务，不触碰旧 `sing-box` |
| 0 | 退出 |

## 节点和 TLS 设置

- **地址**：客户端连接用 IPv4、IPv6 或域名。
- **监听端口**：VPS 本机 TCP 端口；建议先检查 443 是否被现有服务占用，可改用高位端口。
- **外部端口**：普通 VPS 填与监听端口相同；NAT VPS 可填写服务商映射的公网端口，须自行设置外部 TCP 端口至内部 TCP 端口映射。
- **监听地址**：`0.0.0.0` 默认 IPv4，`::` 则取决于系统 IPv6/双栈配置。
- **TLS SNI**：**真实且与证书 SAN 匹配的域名**；不能将随意填写的 IP 当作证书域名。
- **用户**：可管理多个独立密码。添加或删除用户不更改其他用户的凭据。

### 证书方式

| 方式 | 特点 | 建议 |
| --- | --- | --- |
| 已有证书 | 使用现成 fullchain 与私钥的绝对路径 | **优先推荐**，路径需可被独立服务读取 |
| Let's Encrypt HTTP-01 | 使用 acme.sh 申请与安排自动续签 | 需要域名正确解析到 VPS，公网 TCP/80 可访问且未被占用 |
| Let's Encrypt DNS-01 | 通过 acme.sh DNS API 插件申请 | NAT VPS / 无法开放 80 端口时适用，须预先按照 acme.sh 官方说明配置对应的 DNS API 授权 |
| 自签名 | 无需公网 80 端口，也无需 ACME | **仅用于测试**，多数客户端须手动开启跳过证书验证 |

选择 ACME 时，脚本如发现没有 `acme.sh`，会询问后才从其官方安装站点下载安装器。证书自动续签由 acme.sh 的定时任务处理；已有证书的自动续签由原证书管理程序负责。**菜单 8 的“手动续签”仅适用于本脚本使用 acme.sh 申请的证书。**

自签名证书虽然便于测试，但客户端开启“不验证证书”会降低连接的身份验证安全性。建议正式使用有效公开信任证书。切换证书、重建用户或更改端口后应重新导入节点链接。

## 与旧节点的隔离

| 项目 | v2 独立位置 |
| --- | --- |
| 服务名 | `sing-box-anytls` |
| 配置目录 | `/etc/sing-box-anytls/` |
| 服务端配置 | `/etc/sing-box-anytls/config.json` |
| 节点凭据 / 用户状态 | `/etc/sing-box-anytls/state.json` |
| 独立内核 | `/usr/local/libexec/sing-box-anytls/sing-box` |
| systemd 服务 | `/etc/systemd/system/sing-box-anytls.service` |
| OpenRC 服务 | `/etc/init.d/sing-box-anytls` |
| 备份目录 | `/var/backups/sing-box-anytls/` |

**原有 `/etc/sing-box/config.json`、`sing-box.service`、其他 sing-box/Xray/NaiveProxy/Hysteria2 配置均不应被本脚本修改。**

## 安全和维护说明

1. 脚本下载官方最新**稳定版** Release（不自动选 alpha / beta），按官方资产 SHA-256 摘要校验后安装；升级前使用新内核检查配置，服务重启失败时回滚。
2. 为避免私钥泄露，配置、账号状态及本地备份均使用限制性权限；二维码和 AnyTLS 链接含明文登录凭据，**不要上传 GitHub、发到公开群聊或分享终端截图**。
3. 自动识别已启用的 UFW 或 firewalld 后可尝试放行节点 TCP 端口；**云服务器安全组、NAT 映射、iptables/nftables 特殊规则不在自动处理范围**。
4. 卸载 v2 节点不删除备份、不清理已经开放的防火墙规则，也不会卸载其他 sing-box。建议定期检查是否还有其他业务使用该端口。
5. 备份包含用户密码和证书私钥，恢复仅建议使用由本项目生成、存放在可信位置的备份文件。恢复后旧客户端参数可能重新生效。
6. 若已有证书路径位于 `/root` 等受 systemd `ProtectHome` 保护的位置，独立服务可能无法读取；请将要使用的证书安全安装到如 `/etc/ssl` 等可读取位置。
7. 客户端需要支持 AnyTLS，部分客户端不完整支持 `anytls://` URI 的证书选项；使用自签名证书时可能必须手动调整“不验证证书”设置。
8. 建议首次安装前创建 VPS 快照并保留 SSH 连接，先使用测试 VPS 验证 DNS、证书与客户端实际流量。
9. 本版通过 GitHub Actions Bash 语法检查、ShellCheck 错误检查与 JSON 配置结构测试；**尚未在你的实际服务器上验证全部发行版、ACME 续签或 iOS 客户端连通性**。

## 官方参考

- [AnyTLS 入站配置](https://sing-box.sagernet.org/configuration/inbound/anytls/)
- [sing-box TLS 设置](https://sing-box.sagernet.org/configuration/shared/tls/)
- [sing-box 官方 Release](https://github.com/SagerNet/sing-box/releases)
- [acme.sh](https://github.com/acmesh-official/acme.sh)

更新日期：2026-10-28。
