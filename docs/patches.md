# 补丁与 overlay

本项目不拷贝 Codex 源码：构建时按 tag 拉取上游 `openai/codex`，依次打上 [`patches/`](../patches) 里的补丁，再用 [`overlay/`](../overlay) 覆盖 Code Mode 的 JS 引擎层。补丁是对上游文件的普通 `git diff`，针对上游 `rust-v0.161.0`。

补丁采用精确匹配：上游结构变化导致补丁不再适用时，构建会直接失败，而不是产出未验证的文件。

编号说明：`0004`（Android 上默认关闭共享后台服务）已在补丁 0013 解决了它的前提之后撤掉；`0002`（给 `codex-chatgpt` 加 `recursion_limit = "256"`）在上游 `rust-v0.161.0` 自己加上了同样的一行之后撤掉。编号不再复用。

## 补丁

| 补丁 | 作用 |
| --- | --- |
| `0001-code-mode-protocol-honor-PROTOC.patch` | `protoc-bin-vendored` 没有 Android 版 protoc，改为优先读取 `PROTOC` 环境变量（Termux：`pkg install protobuf`）。 |
| `0003-keyring-store-android-unavailable.patch` | Android 上 `keyring` 没有后端，会退化成"保存成功但不落盘"的内存 mock，导致 `auto` 凭据模式丢失登录。改为明确报告不可用，让 `auto` 回落到 `auth.json`。 |
| `0005-code-mode-only-falls-back-to-direct-tools.patch` | 目录里大多数模型是 `code_mode_only`，shell 只存在于 Code Mode 的 JS `exec` 中。Android 没有 V8、不构建 `codex-code-mode-host`，上游此时给这类模型的工具列表是空的，模型一个命令也跑不了。补丁让它们回退到直连工具（`exec_command`、`apply_patch` 等），上游只给 `code_mode` 留了这个回退。 |
| `0006-apply-patch-auto-approve-without-platform-sandbox.patch` | 上游只在存在平台沙箱时才自动批准"路径在可写范围内"的补丁（防止硬链接绕过）。Android 没有任何平台沙箱，审批策略为 `never` 或 `granular` 时每个补丁都会被拒绝，错误信息还写成"writing outside of the project"，连工作目录里的相对路径也不例外，`apply_patch` 因此完全不可用。补丁让 Android 上仍按可写路径检查放行。 |
| `0007-web-search-defaults-to-live-on-android.patch` | 上游默认使用缓存搜索，行情、天气、体育等实时查询拿不到数据，只有开启 full access 时才会自动升级为实时。Android 上没有沙箱需要保护，默认改为实时；显式写 `web_search = "cached"` 仍然有效。实时搜索会读取实时网页，网页内容可能夹带提示词注入，介意的话改回 `cached`。 |
| `0008-fs-ops-skip-sandbox-helper-on-android.patch` | 权限配置为 `workspace-write` 时，`apply_patch` 的文件读写要经过一个沙箱化的文件系统助手进程；Android 没有平台沙箱，这条路径只会报 "filesystem sandbox cannot be enforced on this executor"，表现为 `Failed to write file`。补丁让 Android 上直接读写，目标路径是否在可写范围内由 0006 的检查在更早一步把关。 |
| `0009-update-from-codex-termux-releases.patch` | `codex update` 对这种安装方式直接报 "Could not detect the Codex installation method"，而上游的独立安装命令会下载官方 musl 版本。补丁让更新动作改为运行本项目的 `install.sh`，启动时的版本检查、`codex doctor` 和发布说明链接也都指向本项目的 Release（tag 为 `vX.Y.Z` 或 `vX.Y.Z-rN`）。 |
| `0010-code-mode-runtime-quickjs-wiring.patch` | 接线：把 `code-mode-runtime` 的依赖从 V8 换成 QuickJS（rquickjs），并把终止句柄的类型换成自己的 `TerminateHandle`。运行时本体见下面的 overlay。 |
| `0011-daemon-socket-directory-on-android.patch` | 共享后台服务（以及 `codex remote-control`）的控制 socket 放在写死的 `/tmp/codex-daemon-<uid>/` 下，而 Android 上 `/tmp` 对应用不可写，`codex app-server --listen unix://` 一启动就报 `Permission denied (os error 13)`。补丁改用 Termux 前缀下的 `tmp`；这个前缀很长，64 位十六进制的物理 socket 路径会达到 119 字节，超过 `sun_path` 的 107 字节，所以同时把摘要截成 32 位（87 字节）。 |
| `0012-daemon-process-identity-on-android.patch` | 守护进程用 `/proc/<pid>/stat` 加 `boot_id` 校验进程身份，上游只对 linux、macos 启用，其他平台退回去解析 `ps -o lstart` 的输出（在这类设备上 `/proc/stat` 不可读，该输出的日期不可信）。补丁让 android 走与 Linux 相同的 `/proc` 路径。 |
| `0013-daemon-link-package-to-running-exe-on-android.patch` | 启动守护进程前，上游要先准备一份「package」：把调用它的官方完整 package（`codex-package.json`、`bin/codex`、`codex-path/rg` 等）整份拷到 `~/.codex/packages/app-server-daemon/`，单文件构建会报 `no complete local package`（早期版本因此在 Android 上关掉了自动启动）。Android 上改为建两个符号链接：`packages/app-server-daemon/current` → `releases/android`，`releases/android/bin/codex` → 正在运行的 `codex`。守护进程运行的就是已安装的那个二进制，不多占 300 MB；安装器原位替换二进制后，`daemon restart` 即可换上新的。 |
| `0014-daemon-start-time-from-proc-on-android.patch` | 记录守护进程的启动时间时上游调用 `ps -o lstart`，而 Termux 默认没有 procps（系统自带 toybox 的 `ps` 没有 `lstart`）。Android 上改读 `/proc/<pid>/stat`。 |
| `0015-remote-control-server-name-on-android.patch` | 远程控制向 ChatGPT 上报、并显示在设备列表里的名字来自 `gethostname()`，Android 上永远是 `localhost`，分不清是哪台设备。补丁改成 `<品牌> · Termux`（读系统属性 `ro.product.brand`，没有则用 `ro.product.manufacturer`），例如 `vivo · Termux`；读不到属性时仍用主机名。已存在的登记会在下次连接时改名。 |
| `0016-code-mode-runtime-tz-database.patch` | 给 `code-mode-runtime` 加 `jiff` 依赖（版本固定在上游锁文件里已有的 0.2.23，并打开 `tzdb-bundle-always` 把 tzdb 编进二进制），为 overlay 里的 `Intl.DateTimeFormat` 提供 IANA 时区数据：系统时区读 Android 的 `persist.sys.timezone`，其他时区读编进二进制的 tzdb 副本（同 V8 用自带 ICU 的数据；Android 系统的 tzdata 可能很旧，例如 AOSP 9 的还有 2019 年已废止的巴西夏令时）。 |

| `0017-termux-exec-se-process-context-on-android.patch` | Termux 给每个进程预加载 termux-exec，它在每次 `execve` 时要知道进程的 SELinux 上下文：先读 `TERMUX__SE_PROCESS_CONTEXT`，没有就用 `fopen()` 读 `/proc/self/attr/current`。Rust 在 Android 上用 fork + exec 启动子进程，这个钩子运行在 fork 出来、还没 exec 的子进程里；fork 那一刻如果别的线程正持有 libc 的 stdio 锁，子进程就永远卡住，同时攥着父进程打开的所有 fd。守护进程曾因此留下一个卡死的子进程占着控制 socket，`daemon restart` 起不来新服务。补丁让 codex 在启动时（还是单线程的时候）把上下文写进这个变量（只写 termux-exec 认可的格式，否则它每次 exec 都会警告），并让它穿过 `shell_environment_policy` 的过滤和 MCP 服务器的环境白名单，保证每个子进程都拿得到。 |

## Code Mode 的 JS 引擎：overlay

Code Mode 让模型写一段 JavaScript 来编排工具调用，上游用 V8 执行，而 V8 没有 Android 构建。[`overlay/`](../overlay) 用 [QuickJS-ng](https://github.com/quickjs-ng/quickjs)（通过 [rquickjs](https://github.com/DelSkayn/rquickjs)）重写了 `code-mode-runtime` 里直接依赖 V8 的那一层（`runtime/` 目录，约 1000 行，外加下面的 `Intl` 实现），上游其余部分（调度、会话、gRPC 宿主）原样复用，构建时拷贝覆盖，并同时构建 `codex-code-mode-host`，与 `codex` 并排安装。

- **行为对齐**：模型看到的 JS 环境保持不变：13 个全局函数、没有 `import`、没有 `console`，报错文本也是 `ReferenceError: x is not defined\n    at …` 的形式。
- **验收**：上游自带的约 70 个运行时行为测试在 CI 里对 QuickJS 版本运行（跳过 3 个已知差异），另有端到端测试：由假模型发出 9 次 `exec` 调用，检查文本输出、嵌套工具调用、`store`/`load`、`exit()`、定时器、运行时错误、嵌套的 `apply_patch`，以及 `Intl`、`toLocaleString`、`localeCompare`。
- **`Intl`**：QuickJS 不带 ICU，所以 `runtime/intl.js` 自己实现了英语区域的 ECMA-402（范围和差异见 [limitations.md](limitations.md)）。`runtime/intl_lazy.js` 在每个 cell 里只放几个替身，第一次用到 `Intl` 或 `toLocaleString`、`localeCompare` 时才加载真正的实现（编译约 60 KB 的源码，每个 cell 都付是浪费，也会拖慢上游里按真实线程计时的测试）。货币、单位、相对时间、列表和时区名称的数据表由 `tests/intl/gen-data.mjs` 从完整 ICU 导出（`runtime/intl_data.json`）；时区由 Rust 一侧的 `runtime/intl.rs` 通过 jiff 提供。测试：`intl.rs` 里把约 1500 条表达式和完整 ICU 的结果逐条对照，另有加载时机、失败重试、本地时区一致性的测试；维护工具在 [`tests/intl/`](../tests/intl)。
- **漂移检测**：`overlay/UPSTREAM.sha256` 记录了被替换的上游文件的哈希，上游一旦改动这些文件，构建会失败并要求重新审阅，而不是悄悄忽略上游的改动。
