# ZeroNews 群晖（Synology）套件

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: Synology DSM](https://img.shields.io/badge/Platform-Synology%20DSM-blue)](https://www.synology.com)

将 [ZeroNews（零讯）](https://zeronews.cc) 内网穿透客户端打包为群晖 DSM 原生套件（`.spk`），
安装后在 NAS 上常驻运行，并在 DSM 主菜单提供可视化的运行状态与运行日志面板。

## 相关仓库

本项目是 ZeroNews 的**群晖套件**版本。其他平台版本见原仓库：

| 仓库 | 平台 | 地址 |
|------|------|------|
| **zeronews-lzcapp**（原仓库） | 懒猫云（LazyCat Cloud） | https://github.com/lazycat-contrib/zeronews-lzcapp |

> 懒猫云版本以 Docker 镜像 + `lzc-manifest.yml` 清单形式发布；本仓库则是面向群晖 DSM 的
> 原生二进制套件，二者共用同一份 ZeroNews 客户端二进制与同一套认证 Token。

## 简介

ZeroNews（零讯）是一个边缘云内网穿透平台，通过自研高性能 zeronews tunnel 协议，帮助用户快速解决
内网与外网之间的安全、快速访问需求。无需更改内网网络环境或安装 VPN，即可便捷地访问内网应用及资源。

- 🚀 **免安装 Agent** — 下载即可运行，客户端为静态链接单二进制，无额外系统依赖
- 🔒 **安全可靠** — 采用先进的加密技术，确保数据传输安全
- ⚡ **高性能协议** — 自研 zeronews tunnel 协议，提供超快的传输速度
- 🌐 **无需 VPN** — 不需要复杂的 VPN 配置，简单快捷
- 🖥️ **原生套件** — 不依赖 Docker，随 DSM 开机自启，支持套件中心一键启停

## 支持平台

| 平台 | 说明 |
|------|------|
| **群晖 DSM 6.2+** | x86_64（Intel / AMD）机型，本仓库目标平台 |
| Windows / macOS / Linux | 见 ZeroNews 官网客户端 |
| 懒猫云 | 见[原仓库](https://github.com/lazycat-contrib/zeronews-lzcapp) |

## 前置要求

1. 注册 ZeroNews 账户并获取 Token
   - 访问 https://user.zeronews.cc/login 并登录
   - 在 Token 页面复制您的认证令牌
2. 构建环境：`bash`、`curl`、`tar`、`md5sum`；如需生成图标还需 `python3`

## 构建套件

```bash
./build-spk.sh
# 产物：zeronews-<版本>-<构建号>-x86_64.spk
```

可通过环境变量指定版本号与构建号：

```bash
ZERONEWS_VERSION=4.0.8 PKG_BUILD=0006 ./build-spk.sh
```

构建脚本会完成以下工作：

1. 下载并校验 x86-64 客户端（默认从 `https://download.v2.zeronews.cc`，命中缓存则跳过）
2. 组装 `package.tgz`（客户端二进制、`VERSION`、桌面 UI）
3. 写入套件元数据 `INFO`，版本号跟随构建号，并追加 `package.tgz` 的 md5 `checksum`
4. 以 DSM 6 要求的格式（**未压缩 tar**、归档条目**不带 `./` 前缀**）打包为 `.spk`

## 安装

1. 打开 DSM **套件中心 → 手动安装**，选择生成的 `.spk` 文件
2. 若提示未签名，先将 **套件中心 → 设置 → 常规 → 信任层级** 设为「任何发行者」
3. 在弹出的安装向导中填入 **ZeroNews Token**，安装完成后会自动完成账号绑定

命令行安装：

```bash
sudo synopkg install /volume2/docker/zeronews-4.0.8-0006-x86_64.spk
```

## 使用

套件启动后客户端常驻运行，并随 DSM 开机自启、断线自动重连。DSM 主菜单会出现 **ZeroNews** 图标，
点击即可打开面板，查看：

- **服务状态** — 客户端是否运行及 PID
- **账号绑定** — Token 是否已绑定
- **云端连接** — 是否已连接 ZeroNews 云端
- **隧道数量** — 已配置的隧道条数及明细（隧道名称 / 本地地址 / 公网地址 / 状态）
- **运行日志** — 最近 200 行客户端日志，页面每 5 秒自动刷新

## 实现要点

- **运行身份**：`conf/privilege` 中 `run-as` 设为 `root`，以便在 `/var/packages/zeronews/var`
  下创建运行目录并维护 pid 文件
- **服务管理**：DSM 6.x 无 systemd 可用，`scripts/start-stop-status` 直接以常驻前台进程方式启动客户端，
  并自行维护 pid 文件；`status` 按 DSM 约定返回「运行 0 / 未运行 3」
- **桌面图标**：DSM 依据 `INFO` 中的 `dsmuidir` 把 `target/ui` 软链到
  `/usr/syno/synoman/webman/3rdparty/zeronews`，`ui/config` 定义入口为
  `/webman/3rdparty/zeronews/index.html`
- **面板数据**：客户端 HTTP API 仅监听 `127.0.0.1`（来自其他主机的请求返回 403 且无 CORS 头），
  浏览器无法直接访问。因此由 `scripts/ui-publish.sh` 在 NAS 端把状态与日志落成 `ui/data/` 下的
  静态文件，页面以**同源**方式读取
- **Token 绑定**：`scripts/postinst` 在安装时调用 `zeronews authtoken` 完成绑定，并通过
  `zeronews status --json` 的 `configured` 字段校验绑定结果

## 目录结构

```
.
├── build-spk.sh              # 套件构建脚本（下载客户端、组装 package.tgz、打包 .spk）
├── INFO                      # 套件元数据（版本、架构、dsmuidir、dsmappname 等）
├── conf/privilege            # 套件运行身份配置
├── WIZARD_UIFILES/           # 安装向导（采集 ZeroNews Token）
├── scripts/
│   ├── postinst              # 安装后绑定 Token
│   ├── start-stop-status     # 服务启停与状态查询
│   └── ui-publish.sh         # 生成桌面面板所需的状态/日志静态文件
├── ui/                       # 桌面入口：状态/日志页面与多尺寸图标
│   ├── config                # DSM 桌面应用注册配置
│   ├── index.html            # 状态 / 日志面板
│   └── images/               # 主菜单图标（16/24/32/48/64/72/256）
├── tools/make-ui-icons.py    # 由 256px 源图生成各尺寸图标（纯 Python）
└── icons/                    # 套件中心列表图标（72px / 256px）
```

## 配置与日志路径

| 项目 | 路径 |
|------|------|
| 套件安装目录 | `/var/packages/zeronews/target` |
| 运行数据 / 配置 | `/var/packages/zeronews/var` |
| 运行日志 | `/var/packages/zeronews/var/logs/service.log` |
| Token 绑定日志 | `/var/packages/zeronews/var/logs/authtoken.log` |
| 桌面入口软链接 | `/usr/syno/synoman/webman/3rdparty/zeronews` |

## 常见问题

**Q：Token 填错了怎么办？**

重新安装套件并在向导中填入正确的 Token 即可；也可在 SSH 中手动绑定：

```bash
sudo /var/packages/zeronews/target/bin/zeronews \
  --workdir /var/packages/zeronews/var authtoken "<你的 Token>"
```

**Q：如何确认 Token 已绑定、设备已上线？**

```bash
sudo /var/packages/zeronews/target/bin/zeronews \
  --workdir /var/packages/zeronews/var status --json
# 期望：{"configured":true,"connected":true,...}
```

**Q：桌面图标点开显示「您所指定的页面不存在」？**

说明入口 URL 少了 `/webman` 前缀，正确地址为
`http://<NAS 地址>:5000/webman/3rdparty/zeronews/index.html`。

**Q：安装或启动失败怎么办？**

参见 [DEVELOPMENT.md](DEVELOPMENT.md)，其中记录了套件格式、权限、Token 绑定、桌面图标等
常见问题的排查方法与结论。

## 资源链接

- **ZeroNews 官网**：https://zeronews.cc
- **用户登录 / 获取 Token**：https://user.zeronews.cc/login
- **懒猫云版本（原仓库 zeronews-lzcapp）**：https://github.com/lazycat-contrib/zeronews-lzcapp
- **群晖开发者文档**：https://help.synology.com/developer-guide/

## 许可证

MIT License

## 作者

ZeroNews Team