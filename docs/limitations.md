# 已知限制与未实现的功能

对照上游 `rust-v0.160.0` 的源码，并在一台 Android 16、内核 5.15 的手机上实测。

## 做不了（Android 内核或平台限制）

- **没有操作系统沙箱。** 在测试手机上：Landlock 系统调用返回 `ENOSYS`（内核没有实现），`unshare(CLONE_NEWUSER)` 返回 `EINVAL`（所以上游用的 bubblewrap 不可能运行），进程本身已被 zygote 的 seccomp 过滤器约束。`codex sandbox` 会报"当前系统不支持"。`workspace-write`、`network_access = false` 等设置对 shell 命令**不会被强制执行**，命令以当前 Termux 用户的权限运行；只有 `apply_patch` 会在进程内检查目标路径是否在可写范围内。审批提示属于应用层逻辑，没有改动：需要把关时用 `approval_policy = "untrusted"`。
- **语音和实时对话。** 音频相关的 crate 只为 macOS、linux-gnu、Windows 构建；TUI 里 `/voice` 会提示无法识别。
- **剪贴板图片粘贴。** 上游自己在 Android 上就关掉了。
- **Code Mode 用 QuickJS 而不是 V8。** V8 没有 Android 构建。脚本能正常运行，但没有 `Intl`、`Temporal` 和 ICU 区域数据（例如 `Intl.DateTimeFormat` 未定义，`toLocaleString` 不按区域格式化），报错措辞与 V8 不同，纯 CPU 密集的脚本更慢。典型的"编排几次工具调用"不受影响。宿主程序 `codex-code-mode-host` 缺失时（例如装的是不含它的旧版本），补丁 0005 让模型回退到直连工具。
- **凭据存在 `$CODEX_HOME/auth.json`。** Android 上没有系统钥匙串，上游的 `keyring` 在这里没有后端。

## 缺失，但有办法补

| 功能 | 现状 | 办法 |
| --- | --- | --- |
| 剪贴板文字复制 | 上游在 Android 上隐藏了 `/copy`、"导出对话到剪贴板"和右键粘贴，复制只剩 OSC 52 | 用 Termux:API 的 `termux-clipboard-set` / `termux-clipboard-get` 补上；需要用户装 Termux:API |
| 对 shell 命令强制禁网 | `network_access = false` 只是配置 | 用 seccomp-bpf 过滤网络相关系统调用；只覆盖网络，覆盖不了文件系统 |

文件系统隔离只能靠 ptrace 或 seccomp 通知这类折中办法，实现复杂，也不严格，目前不打算做。

## 不支持，但不影响使用

- `codex app-server daemon update` 和守护进程的自动更新器：官方安装器装的是官方的 Linux 二进制，不能在 Android 上运行。更新走 `codex update`，见 [daemon-and-remote-control.md](daemon-and-remote-control.md)。
- 桌面应用独有的功能（电脑控制、浏览器控制、应用内听写，以及 macOS、Windows 的启动器）不是命令行功能。

## 子命令的验证情况

下面这些在隔离的 `CODEX_HOME` 里、用本地假模型（或只读调用）真实跑过，**都可用**；其中不需要网络和账号的部分已进 CI（`tests/test_subcommands.sh`）：

- `mcp add / list / get / remove`，以及一个 stdio MCP 服务器被模型经 Code Mode 调用（服务器启动、`initialize`、`tools/list`、`tools/call` 全部正常）。注意：`codex exec` 把审批策略强制为 never，没有标成只读的 MCP 工具会返回"需要审批"，这是上游行为。
- `plugin marketplace add / list / remove`、`plugin add / list / remove`（本地市场，安装到 `$CODEX_HOME/plugins/cache`）。
- `review`、`exec resume --last`、`resume --last` 和 `fork --last`（交互式会话；`exec` 建的会话不在恢复列表里）、`archive` / `unarchive` / `delete`、`queue`（需要共享后台服务）、`migrate-rollouts`。
- `cloud list`（在真实账号上只读调用成功，当时账号里没有云任务）。
- `features list / enable / disable`、`completion`、`debug models` / `prompt-input`、`exec-server`（监听并完成 WebSocket 握手）、`app-server generate-json-schema`。

**没验证**：`mcp login` / `logout`（需要 OAuth 服务器）、`cloud exec` / `status` / `diff` / `apply` 和 `apply`（账号里没有云任务）、从 Git 或远程市场安装插件（需要网络源）、`exec-server forward`、IDE 上下文通信、桌面通知。
