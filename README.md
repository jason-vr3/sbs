# sbs · 极简纯净的 Sing-box 一键部署与管理脚本

![OS](https://img.shields.io/badge/OS-Debian%2012%20%7C%20Ubuntu%2022.04%2F24.04-blue)
![Arch](https://img.shields.io/badge/Arch-amd64%20%7C%20arm64-green)
![Protocols](https://img.shields.io/badge/Protocols-VLESS--Reality%20%7C%20Hysteria2-orange)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

**`sbs`** 是一个极简、纯净的 `sing-box` 一键部署与管理脚本，只做目前最主流、抗封锁能力最强的 **VLESS-Reality + Hysteria2** 双协议，不捆绑 Argo、WARP、Telegram 机器人或任何第三方二进制文件，内核与证书全部从官方源获取。

## 🚀 一键部署

全新 Debian 12 / Ubuntu 22.04 / 24.04 的 VPS 上，以 `root` 运行：

```bash
curl -fsSL -o /root/sbs.sh https://raw.githubusercontent.com/jason-vr3/sbs/main/sbs.sh && chmod +x /root/sbs.sh && bash /root/sbs.sh
```

装完输入 `sbs` 即可呼出菜单。选 `1` 一键安装，一路回车用默认值即可：VLESS 端口 443（TCP）、Hysteria2 端口 8443（UDP）、Reality SNI `www.icloud.com`、带宽 100 / 100 Mbps；域名留空就是免域名自签模式，填域名则走 ACME 真实证书。

## 🖥️ 主界面

![sbs 主界面](docs/screenshot-v1.1.png)

*上图为测试机实拍（IP 为测试机地址，状态为未安装）。*

## ✨ 实用功能

**双协议，一键装好就能用**
- VLESS-Reality（TCP 443）+ Hysteria2（UDP 8443），一次安装，两个节点同时上线。
- Hysteria2 有域名 / 免域名双模式：没域名也能直接部署，自动生成自签证书与 `pinSHA256` 指纹；有域名自动申请并续期 Let's Encrypt 真实证书，也支持一键导入本机已有证书，避免重复签发。

**节点导出，手机扫码即用**
- 菜单 `5` 一键输出 URI 分享链接、终端二维码（`qrencode`，v2rayNG / Shadowrocket / NekoBox / sing-box 直接扫码）、Clash Verge（Mihomo）YAML、sing-box 客户端 `outbounds` JSON。
- 免域名模式下，Xray 内核客户端（v2rayN / NekoBox）用 `insecure=0 + pinSHA256` 的链接；官方 Hysteria2 客户端用 `insecure=1 + pinSHA256` 的链接，两条都在菜单 `5` 里分开给出，不用自己改。

**按协议实时流量观察**
- 菜单 `11` 每秒刷新，分 VLESS-Reality（TCP）和 Hysteria2（UDP）各自显示：实时上下行速率、当前活跃连接数、累计流量，支持一键清零。
- 主界面上也能直接看到两个协议的启用状态、端口和累计流量，不用进日志翻。

**日常运维都在菜单里**
- 菜单 `3` 改端口、改域名、改 SNI、换密钥、改带宽；菜单 `4` 单独启停或重置某一个协议，停用保留原参数，再启用不用重新生成。
- 菜单 `6` 启停服务，菜单 `8` 按协议过滤看日志，菜单 `7` 更新 / 切换内核（校验失败自动回滚），菜单 `9` 一键开 BBR+FQ，菜单 `10` 管证书，菜单 `12` 更新脚本本身。
- 每次改配置前自动备份到 `/root/`，写配置先经 `sing-box check` 校验，失败自动回滚；卸载时可自选是否保留证书和密钥。

**干净、透明**
- 只用两个官方来源：`sing-box` 官方安装脚本和 `acme.sh` 官方安装脚本；全部配置收敛于单个 `/etc/sing-box/config.json`，备份绝不放进该目录。

## ⌨️ 命令行快捷方式

```bash
sbs              # 进入交互式管理菜单
sbs --nodes      # 直接打印节点分享链接
sbs --qr         # 直接输出节点二维码
sbs --clash      # 生成并查看 Clash YAML 配置片段
sbs --sb-client  # 生成并查看 sing-box 客户端 outbounds JSON
sbs --traffic    # 直接进入实时流量监控面板
sbs --version    # 查看当前脚本版本
```

## 📋 菜单一览

| 菜单 | 功能 |
| :---: | :--- |
| 1 | 一键安装 Sing-box（VLESS-Reality + Hysteria2） |
| 2 | 卸载 Sing-box（可选保留证书与密钥备份） |
| 3 | 变更配置（端口 / 证书模式与域名 / SNI / 密钥 / 带宽） |
| 4 | 管理协议（单独启停 / 重置单个协议） |
| 5 | 查看节点（URI / 二维码 / Clash / sing-box 客户端导出） |
| 6 | 服务控制（启动 / 重启 / 停止） |
| 7 | 更新 / 切换内核 |
| 8 | 查看运行日志（按协议过滤） |
| 9 | 一键开启 BBR+FQ |
| 10 | 管理证书（ACME 申请 / 续期 / 导入 / 切换自签） |
| 11 | 实时流量监控（按协议分速率、连接数、累计流量） |
| 12 | 更新本脚本 |

## ❓ 常见问题

- **Hysteria2 测速超时？** 它走 UDP（默认 8443），先放行 VPS 安全组里的 UDP 端口；部分线路会拦截 UDP 443，改用 8443 即可。
- **ACME 证书申请失败？** 域名 A 记录要解析到本机 IP，Cloudflare 先设灰云（仅 DNS），本机 TCP 80 端口不能被其他服务占用；同一组域名 7 天内最多签发 5 张重复证书，已有证书可用菜单 `10` 导入复用。
- **v2rayN 提示 `allowInsecure` 已移除？** 用菜单 `5` 的 Xray 专用链接（`insecure=0 + pinSHA256`），不要用带 `insecure=1` 的旧链接；官方 Hysteria2 客户端则用另一条 `insecure=1 + pinSHA256` 的链接。
- **重装 VPS 后旧节点还能用吗？** 不能。重装会清空配置、密钥和证书，重新安装会生成全新的 UUID 与密码，请用菜单 `5` 的新链接重新导入。

## ⚠️ 免责声明

本项目仅用于个人学习 Linux Shell 编程、网络协议研究及合法的跨境网络加速测试。请遵守服务器所在地及您所在国家/地区的法律法规，严禁用于任何违法违规用途。

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 开源。
