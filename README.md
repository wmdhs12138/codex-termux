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

更新：重复运行安装命令即可。不要使用 `codex update`，它会下载官方的 musl 版本。

## 解决了什么

| 相关上游问题 | 现象 | 原因与处理 |
| --- | --- | --- |
| [#26277](https://github.com/openai/codex/issues/26277)、[#11809](https://github.com/openai/codex/issues/11809) | `lock() not supported` | Rust 标准库从 1.98 起才支持 Android 的 `File::lock`，上游钉在 1.95。本项目要求 rustc ≥ 1.98，Termux 源里是 1.99，无需改代码。 |
| [#37316](https://github.com/openai/codex/issues/37316)、[#36318](https://github.com/openai/codex/issues/36318) | 登录和请求失败 | 官方 musl 静态二进制在 Android 上找不到 `/etc/resolv.conf` 等系统文件（以往的 proot 方案就是为了绕开这一点）。Bionic 版本走系统解析和系统证书，已实测可连通 `api.openai.com`。 |
| [#24507](https://github.com/openai/codex/issues/24507) | `oboe-sys` 链接失败 | 语音相关依赖只在 macOS、Linux、Windows 下启用，Android 构建不会引入。 |
| [#47402](https://github.com/openai/codex/issues/47402)、[#30153](https://github.com/openai/codex/issues/30153) | proot Debian 下 bwrap 沙箱初始化失败 | 原生构建不再需要 proot。Android 构建不编译 bwrap、landlock、seccomp，平台沙箱选择返回空，不会尝试创建沙箱（代价见下文"已知限制"）。 |

## 补丁

补丁位于 [`patches/`](patches)，针对上游 `rust-v0.160.0`：

| 补丁 | 作用 |
| --- | --- |
| `0001-code-mode-protocol-honor-PROTOC.patch` | `protoc-bin-vendored` 没有 Android 版 protoc，改为优先读取 `PROTOC` 环境变量（Termux：`pkg install protobuf`）。 |
| `0002-chatgpt-raise-recursion-limit.patch` | 上游钉的是 rustc 1.95，用 1.99 编译时 `codex-chatgpt` 的类型求解会超出默认深度，沿用上游其他 crate 的 `recursion_limit = "256"`。 |
| `0003-keyring-store-android-unavailable.patch` | Android 上 `keyring` 没有后端，会退化成"保存成功但不落盘"的内存 mock，导致 `auto` 凭据模式丢失登录。改为明确报告不可用，让 `auto` 回落到 `auth.json`。 |
| `0004-daemon-auto-start-off-on-android.patch` | 交互界面默认会去拉起共享的 app-server 守护进程，而它要求官方的完整 package 目录（其中带 `codex-code-mode-host`），单文件构建会直接报 `no complete local package`。Android 上默认改为嵌入式运行，仍可用 `features.daemon_auto_start` 手动打开。 |
| `0005-code-mode-only-falls-back-to-direct-tools.patch` | 目录里大多数模型是 `code_mode_only`，shell 只存在于 Code Mode 的 JS `exec` 中。Android 没有 V8、不构建 `codex-code-mode-host`，上游此时给这类模型的工具列表是空的，模型一个命令也跑不了。补丁让它们回退到直连工具（`exec_command`、`apply_patch` 等），上游只给 `code_mode` 留了这个回退。 |
| `0006-apply-patch-auto-approve-without-platform-sandbox.patch` | 上游只在存在平台沙箱时才自动批准"路径在可写范围内"的补丁（防止硬链接绕过）。Android 没有任何平台沙箱，审批策略为 `never` 或 `granular` 时每个补丁都会被拒绝，错误信息还写成"writing outside of the project"，连工作目录里的相对路径也不例外，`apply_patch` 因此完全不可用。补丁让 Android 上仍按可写路径检查放行。 |
| `0007-web-search-defaults-to-live-on-android.patch` | 上游默认使用缓存搜索，行情、天气、体育等实时查询拿不到数据，只有开启 full access 时才会自动升级为实时。Android 上没有沙箱需要保护，默认改为实时；显式写 `web_search = "cached"` 仍然有效。实时搜索会读取实时网页，网页内容可能夹带提示词注入，介意的话改回 `cached`。 |
| `0008-fs-ops-skip-sandbox-helper-on-android.patch` | 权限配置为 `workspace-write` 时，`apply_patch` 的文件读写要经过一个沙箱化的文件系统助手进程；Android 没有平台沙箱，这条路径只会报 "filesystem sandbox cannot be enforced on this executor"，表现为 `Failed to write file`。补丁让 Android 上直接读写，目标路径是否在可写范围内由 0006 的检查在更早一步把关。 |

补丁采用精确匹配：上游结构变化导致补丁不再适用时，构建会直接失败，而不是产出未验证的文件。

## 已知限制

- **没有沙箱隔离。** Android 没有可用的内核沙箱机制，`codex sandbox` 不可用。`workspace-write`、`network_access = false` 等沙箱设置对 shell 命令**不会被强制执行**，命令以当前 Termux 用户的权限运行；只有 `apply_patch` 会在进程内检查目标路径是否在可写范围内。审批提示属于应用层逻辑，未做改动，请据此评估风险，需要把关时使用 `approval_policy = "untrusted"`。
- **Code Mode 不可用。** 它依赖 V8，而 rusty_v8 没有 Android 预编译包，因此不构建 `codex-code-mode-host`。会话开头会有一条警告，随后回退到直连工具（补丁 0005）。但 `code_mode_only` 的模型是针对 Code Mode 调优的，在直连工具下的表现我没有评估过；`gpt-5.5` 这类原本就是直连工具的模型不受影响。
- **共享后台服务不可用。** `codex app-server daemon`、`codex agents` 要求官方的完整 package 目录结构，暂不支持；交互界面默认以嵌入式运行。
- **剪贴板图片粘贴不可用。** 这是上游在 Android 上的既有行为。
- **凭据存放在 `$CODEX_HOME/auth.json`**（默认 `file` 模式），Android 上没有系统钥匙串。

## CI

所有构建都在 GitHub Actions 上完成，不在手机上编译：

```text
ubuntu-24.04-arm GitHub runner
└── pinned termux/termux-docker image
    ├── pkg install rust clang cmake protobuf openssl ...
    ├── git clone openai/codex@rust-v<version>, apply patches/
    ├── cargo build --release -p codex-cli --bin codex
    ├── 在 Bionic 中真实执行：版本、登录往返、codex exec 启动路径、TUI 启动、
    │   模型实际拿到的工具列表、apply_patch 真的写出文件（均用本地假 API 脚本化驱动）、依赖白名单
    └── 通过后发布 tarball + SHA-256 + build-manifest.json
```

- PR：只做脚本和补丁的静态检查；
- 推送至 `main`：完整构建并上传 artifact；
- 每天：检查上游最新稳定版，有新版本且通过验收后自动发布；
- 手动运行：构建指定版本，勾选 `recut` 可在补丁变化后重新发布同一版本（`vX.Y.Z-rN`）。

验收中的 `codex exec` 使用假 key，只断言本地副作用（启动锁、状态库、rollout 写锁），不依赖网络可达。DNS、TLS 的连通性检查输出到日志，但不作为失败条件。

## 从源码构建

不推荐在手机上构建：完整 release 构建约一小时，峰值内存接近 13 GB。如确有需要：

```bash
pkg install rust clang cmake make git jq openssl liblzma pkg-config protobuf python
VERSION=0.160.0 scripts/build.sh      # 产物在 dist/
```

第三方组件及许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。本项目与 OpenAI 无关联。
