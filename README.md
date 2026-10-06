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

`codex update` 已被改为从本项目的 Release 更新（上游版本会去下载官方的 musl 版本）：它会运行本项目的 `install.sh`，下载最新 Release、校验 SHA-256 并原子替换。已经是最新时（按二进制哈希判断，`vX.Y.Z-rN` 重发布也能识别）会直接提示并退出；需要强制重装时用 `CODEX_TERMUX_FORCE=1 codex update`。

启动时的"有新版本"提示和 `codex doctor` 的更新检查也改为查询本项目的 Release。重复运行安装命令同样可以更新。

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
| `0009-update-from-codex-termux-releases.patch` | `codex update` 对这种安装方式直接报 "Could not detect the Codex installation method"，而上游的独立安装命令会下载官方 musl 版本。补丁让更新动作改为运行本项目的 `install.sh`，启动时的版本检查、`codex doctor` 和发布说明链接也都指向本项目的 Release（tag 为 `vX.Y.Z` 或 `vX.Y.Z-rN`）。 |
| `0010-code-mode-runtime-quickjs-wiring.patch` | 接线：把 `code-mode-runtime` 的依赖从 V8 换成 QuickJS（rquickjs），并把终止句柄的类型换成自己的 `TerminateHandle`。运行时本体见下面的 overlay。 |
| `0011-daemon-socket-directory-on-android.patch` | 共享后台服务（以及 `codex remote-control`）的控制 socket 放在写死的 `/tmp/codex-daemon-<uid>/` 下，而 Android 上 `/tmp` 对应用不可写，`codex app-server --listen unix://` 一启动就报 `Permission denied (os error 13)`。补丁改用 Termux 前缀下的 `tmp`；这个前缀很长，64 位十六进制的物理 socket 路径会达到 119 字节，超过 `sun_path` 的 107 字节，所以同时把摘要截成 32 位（87 字节）。 |
| `0012-daemon-process-identity-on-android.patch` | 守护进程用 `/proc/<pid>/stat` 加 `boot_id` 校验进程身份，上游只对 linux、macos 启用，其他平台退回去解析 `ps -o lstart` 的输出（在这类设备上 `/proc/stat` 不可读，该输出的日期不可信）。补丁让 android 走与 Linux 相同的 `/proc` 路径。 |
| `0013-daemon-link-package-to-running-exe-on-android.patch` | 启动守护进程前，上游要先准备一份「package」：把调用它的官方完整 package（`codex-package.json`、`bin/codex`、`codex-path/rg` 等）整份拷到 `~/.codex/packages/app-server-daemon/`，单文件构建会报 `no complete local package`（补丁 0004 当初关掉自动启动的原因）。Android 上改为建两个符号链接：`packages/app-server-daemon/current` → `releases/android`，`releases/android/bin/codex` → 正在运行的 `codex`。守护进程运行的就是已安装的那个二进制，不多占 300 MB；安装器原位替换二进制后，`daemon restart` 即可换上新的。 |
| `0014-daemon-start-time-from-proc-on-android.patch` | 记录守护进程的启动时间时上游调用 `ps -o lstart`，而 Termux 默认没有 procps（系统自带 toybox 的 `ps` 没有 `lstart`）。Android 上改读 `/proc/<pid>/stat`。 |

补丁采用精确匹配：上游结构变化导致补丁不再适用时，构建会直接失败，而不是产出未验证的文件。


### Code Mode 的 JS 引擎：overlay

Code Mode 让模型写一段 JavaScript 来编排工具调用，上游用 V8 执行，而 V8 没有 Android 构建。[`overlay/`](overlay) 用 [QuickJS-ng](https://github.com/quickjs-ng/quickjs)（通过 [rquickjs](https://github.com/DelSkayn/rquickjs)）重写了 `code-mode-runtime` 里直接依赖 V8 的那一层（`runtime/` 目录，约 1000 行），上游其余部分（调度、会话、gRPC 宿主）原样复用，构建时拷贝覆盖，并同时构建 `codex-code-mode-host`，与 `codex` 并排安装。

- **行为对齐**：模型看到的 JS 环境保持不变：13 个全局函数、没有 `import`、没有 `console`，报错文本也是 `ReferenceError: x is not defined\n    at …` 的形式。
- **验收**：上游自带的约 70 个运行时行为测试在 CI 里对 QuickJS 版本运行（跳过 3 个已知差异），另有端到端测试：由假模型发出 5 次 `exec` 调用，检查文本输出、嵌套工具调用、`store`/`load`、`exit()`、定时器和运行时错误。
- **漂移检测**：`overlay/UPSTREAM.sha256` 记录了被替换的上游文件的哈希，上游一旦改动这些文件，构建会失败并要求重新审阅，而不是悄悄忽略上游的改动。

## 已知限制

- **没有沙箱隔离。** Android 没有可用的内核沙箱机制，`codex sandbox` 不可用。`workspace-write`、`network_access = false` 等沙箱设置对 shell 命令**不会被强制执行**，命令以当前 Termux 用户的权限运行；只有 `apply_patch` 会在进程内检查目标路径是否在可写范围内。审批提示属于应用层逻辑，未做改动，请据此评估风险，需要把关时使用 `approval_policy = "untrusted"`。
- **Code Mode 用 QuickJS 而不是 V8。** 脚本能正常运行，但没有 `Intl`、`Temporal` 和 ICU 区域数据（例如 `Intl.DateTimeFormat` 未定义，`toLocaleString` 不按区域格式化）；报错文本里 QuickJS 的措辞与 V8 不同；纯 CPU 密集的脚本会更慢。典型的"编排几次工具调用"不受影响。如果宿主程序 `codex-code-mode-host` 缺失（例如装的是不含它的旧版本），补丁 0005 会让模型回退到直连工具。
- **共享后台服务仍是实验性的，默认关闭。** `codex app-server daemon start/restart/stop/version/bootstrap` 可用：守护进程直接运行已安装的二进制，CI 覆盖了启动、复用、重启、停止，以及一个客户端经控制 socket 连上去（与交互界面的附着方式相同）跑完整的 Code Mode 会话；`codex update` 之后安装器会把正在运行的守护进程重启到新版本（`CODEX_TERMUX_SKIP_DAEMON_RESTART=1` 可关闭）。不支持：`daemon update`（安装官方 package）、守护进程的自动更新器、`codex agents`。交互界面默认仍以嵌入式运行，可用 `features.daemon_auto_start = true` 打开；常驻进程可能被 Android 的幽灵进程限制杀掉：已附着的交互界面会以 `transport failed: Connection reset without closing handshake` 报错退出，之后自动启动会报错并提示加 `--no-daemon`。内存方面（实测，空闲）：嵌入式单个界面约 300 MB；守护进程模式下界面约 90 MB，另有一个常驻的守护进程约 270 MB（匿名内存约 195 MB，3 分钟内不增长），界面退出后它仍留着，直到被杀或 `codex app-server daemon stop`；同时开多个界面时才比嵌入式省内存。前台的 `codex remote-control` 在真机上用 ChatGPT 账号手动验证过一次（v0.160.0-r4）：向后端登记并连上，约 2 秒；登记时上报的服务器名是主机名，Android 上是 `localhost`；它在 ChatGPT 应用里是否出现、出现在哪里，尚未确认。只验证了设备一侧的连接，没有从 ChatGPT 客户端实际下发任务；`codex remote-control start`（经常驻守护进程）没有测；CI 不测（它需要账号并会向后端登记设备）。
- **剪贴板图片粘贴不可用。** 这是上游在 Android 上的既有行为。
- **凭据存放在 `$CODEX_HOME/auth.json`**（默认 `file` 模式），Android 上没有系统钥匙串。

## CI

所有构建都在 GitHub Actions 上完成，不在手机上编译：

```text
ubuntu-24.04-arm GitHub runner
└── pinned termux/termux-docker image
    ├── pkg install rust clang cmake protobuf openssl ...
    ├── git clone openai/codex@rust-v<version>, apply patches/ and overlay/
    ├── cargo build --release: codex 和 codex-code-mode-host
    ├── cargo test：上游的 code-mode 运行时测试对 QuickJS 运行
    ├── 在 Bionic 中真实执行：版本、登录往返、codex exec 启动路径、TUI 启动、
    │   模型实际拿到的工具列表、apply_patch 真的写出文件、codex update 执行的命令
    │   （均用本地假 API / 假 bash 驱动）、依赖白名单
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
