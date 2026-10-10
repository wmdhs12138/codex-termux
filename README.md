# codex-termux

让官方 [Codex CLI](https://github.com/openai/codex) 在 Termux 原生运行。

官方只发布 `aarch64-unknown-linux-musl` 的静态二进制，在 Android 上要靠 proot 才能勉强使用，并且会遇到文件锁、DNS、证书、沙箱等一连串问题。本项目从上游源码出发，打上少量补丁，直接编译成 Bionic 原生程序：无 glibc、无 proot、无兼容层。

[![build](https://github.com/wmdhs12138/codex-termux/actions/workflows/build.yml/badge.svg)](https://github.com/wmdhs12138/codex-termux/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/wmdhs12138/codex-termux?display_name=tag&sort=semver)](https://github.com/wmdhs12138/codex-termux/releases/latest)

## 安装

要求：AArch64、Android 9（API 28）或更高版本。

```bash
curl -fsSL https://raw.githubusercontent.com/wmdhs12138/codex-termux/main/install.sh | bash
```

安装器会下载最新 Release、校验 SHA-256，并安装到 `$PREFIX/bin/codex`，同时安装运行时依赖 `openssl` 与 `liblzma`。

安装指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/wmdhs12138/codex-termux/main/install.sh | VERSION=0.160.0 bash
```

## 更新

```bash
codex update
```

`codex update` 已被改为从本项目的 Release 更新（上游版本会去下载官方的 musl 版本）：它运行本项目的 `install.sh`，下载最新 Release、校验 SHA-256 并原子替换。已经是最新时（按二进制哈希判断，`vX.Y.Z-rN` 重发布也能识别）直接提示并退出；强制重装用 `CODEX_TERMUX_FORCE=1 codex update`。启动时的"有新版本"提示和 `codex doctor` 的更新检查也查询本项目的 Release。装入了不同的二进制后，如果共享后台服务在运行，安装器会把它重启到新版本。

## 功能一览

| 功能 | 状态 |
| --- | --- |
| 交互界面、`codex exec`、登录、`apply_patch`、网络搜索 | 可用，CI 里真实执行并检查 |
| Code Mode（模型写 JavaScript 编排工具调用） | 可用，引擎是 QuickJS；`Intl`、`toLocaleString`、`localeCompare` 由自带实现补上（只有英语区域数据），没有 `Temporal`，详见 [限制](docs/limitations.md) |
| 共享后台服务、`codex agents` | 可用，和官方一样**默认开启**，[详情](docs/daemon-and-remote-control.md) |
| 远程控制（ChatGPT 应用连到这台手机） | 可用，和官方一样**需要主动开启**并配对，[详情](docs/daemon-and-remote-control.md) |
| 操作系统沙箱、`codex sandbox` | **不可用**（Android 内核限制，见下） |
| 语音和实时对话、剪贴板图片粘贴、`/copy` | 不可用（音频依赖不支持 Android；剪贴板上游在 Android 上关闭） |
| 系统钥匙串 | 不可用，凭据存在 `$CODEX_HOME/auth.json` |
| `daemon update`、守护进程的自动更新器 | 不支持，更新走 `codex update` |

`mcp`、`plugin`、`resume` / `fork`、`archive` / `delete`、`queue`、`review`、`cloud list` 等其余子命令都逐个验证过可用，验证范围和没验证的部分见 [docs/limitations.md](docs/limitations.md)，那里还有未实现功能的原因和可以补的办法。

## 使用前请知道

- **没有沙箱隔离。** Android 没有可用的内核沙箱机制，`codex sandbox` 不可用。`workspace-write`、`network_access = false` 等沙箱设置对 shell 命令**不会被强制执行**，命令以当前 Termux 用户的权限运行；只有 `apply_patch` 会在进程内检查目标路径是否在可写范围内。审批提示属于应用层逻辑，未做改动，请据此评估风险，需要把关时使用 `approval_policy = "untrusted"`。
- **共享后台服务会常驻**，约 270 MB 内存；被 Android 杀掉或被 `codex update` 重启时，已连上的界面会报错退出。不想用：`codex --no-daemon`，或在 `config.toml` 里设 `features.daemon_auto_start = false`。
- **远程控制会把设备登记到你的 ChatGPT 账号**，只有主动开启并配对后才生效；配对后的客户端能在这台手机上执行命令。

## 解决了什么

| 相关上游问题 | 现象 | 原因与处理 |
| --- | --- | --- |
| [#26277](https://github.com/openai/codex/issues/26277)、[#11809](https://github.com/openai/codex/issues/11809) | `lock() not supported` | Rust 标准库从 1.98 起才支持 Android 的 `File::lock`，上游钉在 1.95。本项目要求 rustc ≥ 1.98，Termux 源里是 1.99，无需改代码。 |
| [#37316](https://github.com/openai/codex/issues/37316)、[#36318](https://github.com/openai/codex/issues/36318) | 登录和请求失败 | 官方 musl 静态二进制在 Android 上找不到 `/etc/resolv.conf` 等系统文件（以往的 proot 方案就是为了绕开这一点）。Bionic 版本走系统解析和系统证书，已实测可连通 `api.openai.com`。 |
| [#24507](https://github.com/openai/codex/issues/24507) | `oboe-sys` 链接失败 | 语音相关依赖只在 macOS、Linux、Windows 下启用，Android 构建不会引入。 |
| [#47402](https://github.com/openai/codex/issues/47402)、[#30153](https://github.com/openai/codex/issues/30153) | proot Debian 下 bwrap 沙箱初始化失败 | 原生构建不再需要 proot。Android 构建不编译 bwrap、landlock、seccomp，平台沙箱选择返回空，不会尝试创建沙箱（代价见下文"已知限制"）。 |

## 文档

| | |
| --- | --- |
| [docs/daemon-and-remote-control.md](docs/daemon-and-remote-control.md) | 共享后台服务与远程控制：开关、代价与实测数据、配对与目录信任 |
| [docs/limitations.md](docs/limitations.md) | 已知限制、未实现的功能和可以补的办法 |
| [docs/patches.md](docs/patches.md) | 每个补丁解决什么问题，以及 Code Mode 的 QuickJS overlay |
| [docs/ci.md](docs/ci.md) | CI 流水线，以及 Bionic 里真实执行的测试 |
| [docs/maintaining.md](docs/maintaining.md) | 维护手册：跟进上游版本、改补丁、发版、踩过的坑 |
| [tests/README.md](tests/README.md) | 各测试文件的作用 |

## 从源码构建

不推荐在手机上构建：完整 release 构建约一小时，峰值内存接近 13 GB。如确有需要：

```bash
pkg install rust clang cmake make git jq openssl liblzma pkg-config protobuf python
VERSION=0.162.0 scripts/build.sh      # 产物在 dist/
```

第三方组件及许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。本项目与 OpenAI 无关联。
