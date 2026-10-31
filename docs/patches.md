# 补丁与 Code Mode 的 V8

本项目不拷贝 Codex 源码：构建时按 tag 拉取上游 `openai/codex`，依次打上 [`patches/`](../patches) 里的补丁，再链接本项目为 Android 编译的 V8（见[下文](#code-mode-的-v8)）。补丁是对上游文件的普通 `git diff`，针对上游 `rust-v0.166.0`。

补丁采用精确匹配：上游结构变化导致补丁不再适用时，构建会直接失败，而不是产出未验证的文件。

换回 V8：Code Mode 以前跑在 QuickJS 上（`overlay/` 里重写的运行时和自写的 `Intl`），因为 rusty_v8 没有 Android 版本。现在本项目自己编译 V8，上游的 `code-mode-runtime` 原样使用：overlay 和只为它服务的 0010（依赖接线）、0016（时区数据）一起撤掉，0005、0021 只改了注释。

`rust-v0.166.0` 的适配：上游的独立安装命令改成先下载完整再 `eval`，0009 随之更新上下文；0018 只是因此连带打不上，内容未变。工作区的 `[patch.crates-io]` 新增了 `v8` 的 git fork，由新增的 0021 去掉。

`rust-v0.164.0` 的适配审阅了 `arg0` 测试上下文和控制 socket 的 `DaemonSocketFileGuard` 重命名。

编号说明：`0004`（Android 上默认关闭共享后台服务）已在补丁 0013 解决了它的前提之后撤掉；`0002`（给 `codex-chatgpt` 加 `recursion_limit = "256"`）在上游 `rust-v0.161.0` 自己加上了同样的一行之后撤掉；`0010`、`0016` 在换回 V8 时撤掉。编号不再复用。

## 补丁

| 补丁 | 作用 |
| --- | --- |
| `0001-code-mode-protocol-honor-PROTOC.patch` | `protoc-bin-vendored` 没有 Android 版 protoc，改为优先读取 `PROTOC` 环境变量（Termux：`pkg install protobuf`）。 |
| `0003-keyring-store-android-unavailable.patch` | Android 上 `keyring` 没有后端，会退化成"保存成功但不落盘"的内存 mock，导致 `auto` 凭据模式丢失登录。改为明确报告不可用，让 `auto` 回落到 `auth.json`。 |
| `0005-code-mode-only-falls-back-to-direct-tools.patch` | 目录里大多数模型是 `code_mode_only`，shell 只存在于 Code Mode 的 JS `exec` 中。缺少 `codex-code-mode-host` 时（例如更早的版本没有带它），上游给这类模型的工具列表是空的，模型一个命令也跑不了。补丁让它们回退到直连工具（`exec_command`、`apply_patch` 等），上游只给 `code_mode` 留了这个回退。 |
| `0006-apply-patch-auto-approve-without-platform-sandbox.patch` | 上游只在存在平台沙箱时才自动批准"路径在可写范围内"的补丁（防止硬链接绕过）。Android 没有任何平台沙箱，审批策略为 `never` 或 `granular` 时每个补丁都会被拒绝，错误信息还写成"writing outside of the project"，连工作目录里的相对路径也不例外，`apply_patch` 因此完全不可用。补丁让 Android 上仍按可写路径检查放行。 |
| `0007-web-search-defaults-to-live-on-android.patch` | 上游默认使用缓存搜索，行情、天气、体育等实时查询拿不到数据，只有开启 full access 时才会自动升级为实时。Android 上没有沙箱需要保护，默认改为实时；显式写 `web_search = "cached"` 仍然有效。实时搜索会读取实时网页，网页内容可能夹带提示词注入，介意的话改回 `cached`。 |
| `0008-fs-ops-skip-sandbox-helper-on-android.patch` | 权限配置为 `workspace-write` 时，`apply_patch` 的文件读写要经过一个沙箱化的文件系统助手进程；Android 没有平台沙箱，这条路径只会报 "filesystem sandbox cannot be enforced on this executor"，表现为 `Failed to write file`。补丁让 Android 上直接读写，目标路径是否在可写范围内由 0006 的检查在更早一步把关。 |
| `0009-update-from-codex-termux-releases.patch` | `codex update` 对这种安装方式直接报 "Could not detect the Codex installation method"，而上游的独立安装命令会下载官方 musl 版本。补丁让更新动作改为运行本项目的 `install.sh`，启动时的版本检查、`codex doctor` 和发布说明链接也都指向本项目的 Release（tag 为 `vX.Y.Z` 或 `vX.Y.Z-rN`）。 |
| `0011-daemon-socket-directory-on-android.patch` | 共享后台服务（以及 `codex remote-control`）的控制 socket 放在写死的 `/tmp/codex-daemon-<uid>/` 下，而 Android 上 `/tmp` 对应用不可写，`codex app-server --listen unix://` 一启动就报 `Permission denied (os error 13)`。补丁改用 Termux 前缀下的 `tmp`；这个前缀很长，64 位十六进制的物理 socket 路径会达到 119 字节，超过 `sun_path` 的 107 字节，所以同时把摘要截成 32 位（87 字节）。 |
| `0012-daemon-process-identity-on-android.patch` | 守护进程用 `/proc/<pid>/stat` 加 `boot_id` 校验进程身份，上游只对 linux、macos 启用，其他平台退回去解析 `ps -o lstart` 的输出（在这类设备上 `/proc/stat` 不可读，该输出的日期不可信）。补丁让 android 走与 Linux 相同的 `/proc` 路径。 |
| `0013-daemon-link-package-to-running-exe-on-android.patch` | 启动守护进程前，上游要先准备一份「package」：把调用它的官方完整 package（`codex-package.json`、`bin/codex`、`codex-path/rg` 等）整份拷到 `~/.codex/packages/app-server-daemon/`，单文件构建会报 `no complete local package`（早期版本因此在 Android 上关掉了自动启动）。Android 上改为建两个符号链接：`packages/app-server-daemon/current` → `releases/android`，`releases/android/bin/codex` → 正在运行的 `codex`。守护进程运行的就是已安装的那个二进制，不多占 300 MB；安装器原位替换二进制后，`daemon restart` 即可换上新的。 |
| `0014-daemon-start-time-from-proc-on-android.patch` | 记录守护进程的启动时间时上游调用 `ps -o lstart`，而 Termux 默认没有 procps（系统自带 toybox 的 `ps` 没有 `lstart`）。Android 上改读 `/proc/<pid>/stat`。 |
| `0015-remote-control-server-name-on-android.patch` | 远程控制向 ChatGPT 上报、并显示在设备列表里的名字来自 `gethostname()`，Android 上永远是 `localhost`，分不清是哪台设备。补丁改成 `<品牌> · Termux`（读系统属性 `ro.product.brand`，没有则用 `ro.product.manufacturer`），例如 `vivo · Termux`；读不到属性时仍用主机名。已存在的登记会在下次连接时改名。 |
| `0017-termux-exec-se-process-context-on-android.patch` | Termux 给每个进程预加载 termux-exec，它在每次 `execve` 时要知道进程的 SELinux 上下文：先读 `TERMUX__SE_PROCESS_CONTEXT`，没有就用 `fopen()` 读 `/proc/self/attr/current`。Rust 在 Android 上用 fork + exec 启动子进程，这个钩子运行在 fork 出来、还没 exec 的子进程里；fork 那一刻如果别的线程正持有 libc 的 stdio 锁，子进程就永远卡住，同时攥着父进程打开的所有 fd。守护进程曾因此留下一个卡死的子进程占着控制 socket，`daemon restart` 起不来新服务。补丁让 codex 在启动时（还是单线程的时候）把上下文写进这个变量（只写 termux-exec 认可的格式，否则它每次 exec 都会警告），并让它穿过 `shell_environment_policy` 的过滤和 MCP 服务器的环境白名单，保证每个子进程都拿得到。 |
| `0018-update-prompt-offers-recuts-on-android.patch` | 同一上游版本因补丁变化重新发布为 `vX.Y.Z-rN` 时版本号不变，0009 之后的启动更新检查只比较版本，所以从不提示，只有手动 `codex update`（安装器按二进制哈希判断）才会装上。补丁新增 `tui/src/termux_build.rs`：后台检查（每 20 小时一次）在最新 Release 正是当前版本时，把它的 `binary_sha256`、`host_sha256` 和正在运行的 `codex`、`codex-code-mode-host` 的大小、修改时间、SHA-256 记到 `~/.codex/termux-build.json`；启动时只 `stat` 这两个文件，构建不同就提示 `X.Y.Z → X.Y.Z (new build <哈希前 12 位>)`。提示带上构建哈希，「不再提醒」只忽略这一次构建；二进制在检查之后被替换（例如刚运行过 `codex update`）时不拿旧哈希比较，而是立刻重新检查。测试：`tests/test_update_prompt.sh`。 |
| `0019-daemon-restore-deleted-socket-on-android.patch` | Termux 在 App 退出（关掉所有会话、被系统回收）时会清空 `$PREFIX/tmp`，0011 放在那里的控制 socket 和它的启动锁随之被删，而守护进程常常活下来：进程还在、还占着守护进程锁，socket 却没了。之后每次启动 `codex` 都连不上（`app-server-control.sock: No such file or directory`），`daemon start` 也起不了新的，最后报 `app server did not become ready`，只能手动 `daemon restart`。补丁让 Android 上的 accept 循环每 2 秒 `stat` 一次物理 socket：不在了就按启动时的顺序重建目录（0700）、重新拿启动锁、在同一路径上重新 `bind`（0600）；`~/.codex/app-server-control/` 下的软链被删了也补回来。客户端会给正在启动的服务最多 10 秒，所以 Termux 重启后第一次运行 `codex` 最多多等约 2 秒。连续失败只记一次日志。测试：`tests/test_daemon.sh`。 |
| `0020-mxc-sandbox-without-mxc-sdk-on-android.patch` | 上游 `rust-v0.164.0` 新增的 `codex-mxc-sandbox`（Windows 的 MXC 沙箱）无条件依赖 `microsoft/mxc` 的 `mxc-sdk`。`mxc-sdk` 只为 Windows、Linux、macOS 编译 `mxc_engine::run`，`dispatch.rs` 却在所有平台上调用 `run::log_policy_hash`，Android 上编译失败（`cannot find run in mxc_engine`）。`codex-mxc-sandbox` 只在 Windows 和测试里用到 `mxc-sdk`，其他平台上的 `is_available`、`run_main` 等是不依赖它的空实现，所以补丁把这项依赖改成 `cfg(not(target_os = "android"))`：`Cargo.lock` 不变，其他平台和上游一致。 |
| `0021-v8-from-crates-io-without-the-git-fork.patch` | 上游 `rust-v0.166.0` 在工作区的 `[patch.crates-io]` 里把 `v8` 换成 `seanh-oai/rusty_v8` 的 git 版本。这个 fork 只比 crates.io 上的 152.2.0 多两个提交，都只改 `cppgc::Member` 在 Rust 一侧的内存布局，用到它的只有 `codex-v8-poc` 里标了 `#[ignore]` 的测试，Code Mode 不用 cppgc。但 Cargo 解析依赖时会克隆这个 fork 及其全部子模块（V8、ICU、libc++ 等，数 GB）。补丁删掉这一行，`v8` 像 `rust-v0.165.0` 及以前一样来自 crates.io：版本和依赖列表相同，链接的是同一个归档，`Cargo.lock` 里只是 `v8` 的来源变了。 |

## Code Mode 的 V8

Code Mode 让模型写一段 JavaScript 来编排工具调用，上游用 V8 执行（`code-mode-runtime`，开启 V8 的沙箱），本项目原样使用这部分代码。要自己做的只有 V8 本身：rusty_v8（`v8` crate）发布的预编译归档里没有 Android 版本。

- **归档从哪来**：[`.github/workflows/rusty-v8.yml`](../.github/workflows/rusty-v8.yml) 在 x86_64 runner 上运行 [`scripts/build-rusty-v8.sh`](../scripts/build-rusty-v8.sh)，按上游 `codex-rs/Cargo.toml` 锁定的 `v8` 版本从源码交叉编译 `aarch64-linux-android`：最低 API 24，开启沙箱和指针压缩，C++ 标准库用 Chromium 自带的 libc++ 并打包进归档。冒烟测试通过后发布成本项目的 Release `rusty-v8-v<版本>-b<N>`，从不设为 Latest；`N` 是 `versions.json` 里的 `rusty_v8_build`，编译方法改变归档时加一（Release 的 tag 名用过就不能再用）。`build.yml` 发现上游换了 `v8` 版本、归档还没发布时，会先调用它（见 [ci.md](ci.md)）。上游大约两个月升级一次 `v8`，冷编译约两小时。
- **怎么链接**：`scripts/build.sh` 下载归档并按 `SHA256SUMS` 校验，`scripts/cargo-env.sh` 设置 `RUSTY_V8_ARCHIVE`、`RUSTY_V8_ARCHIVE_SHA256`、`RUSTY_V8_SRC_BINDING_PATH`，`v8` crate 的构建脚本就用它，不再去下载上游的归档。另外要链接 compiler-rt（`__clear_cache`）和 `liblog`。所用的版本和归档哈希记在 `build-manifest.json` 里。
- **为 Android 做的改动**：都在编译 V8 这一步，参照 termux-packages 的 deno 包（它为 Termux 编译同一个 crate）和 rusty_v8 的 [#2086](https://github.com/denoland/rusty_v8/pull/2086)：把 NDK 放到 Chromium 构建认的 `third_party/android_toolchain/ndk`（rusty_v8 的 `build.rs` 放在别处）；补上 `android_ndk_version` 的声明（[denoland/chromium_build#208](https://github.com/denoland/chromium_build/pull/208)）；只给 rusty_v8 自己的 bindgen 传 Android 的目标和 sysroot；以及 Termux 的一个 libc++ 补丁（[`patches/rusty_v8/`](../patches/rusty_v8)）。
- **沙箱**：V8 沙箱的大小是编译期常量，按 Android 编译时缩到 128 GB，以适应 Android 内核常见的 39 位用户地址空间（512 GB）。在 39 位内核的手机上实测能完整预留，连保护区共占约 288 GB 虚拟地址空间。这是每个进程各自的地址空间，不占物理内存。
- **验收**：归档发布前，[`tests/v8-smoke`](../tests/v8-smoke) 在 termux-docker 里开 JIT 和 `--jitless` 各跑一次（沙箱、完整 ICU、`Temporal`、WebAssembly、256 MB 的 `ArrayBuffer`）。Codex 构建里，上游 `code-mode-runtime` 的全部测试对这个归档运行，一个都不跳过；另有 Code Mode 的端到端测试（见 [ci.md](ci.md)）。
- **UI 插件进程**：上游 `rust-v0.166.0` 新增的 `codex-code-mode-host --codex-ui-plugin-process` 要求 V8 开启沙箱，这里和上游一样可用。
