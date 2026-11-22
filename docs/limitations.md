# 已知限制与未实现的功能

对照上游 `rust-v0.171.0` 的源码，并在一台 Android 16、内核 5.15 的手机上实测。

## 做不了（Android 内核或平台限制）

- **没有文件系统沙箱（仅网络限制由 `seccomp-bpf` 强制执行）。** 在测试手机上：Landlock 系统调用返回 `ENOSYS`（内核没有实现），`unshare(CLONE_NEWUSER)` 返回 `EINVAL`（所以上游用的 bubblewrap 不可能运行），`codex sandbox` 会报"当前系统不支持"。`workspace-write`、`read-only` 等**文件系统**策略对 shell 命令不会被强制执行，命令以当前 Termux 用户的权限运行；只有 `apply_patch` 会在进程内检查目标路径是否在可写范围内。**网络限制**则已通过补丁 0025 在子进程 `pre_exec` 叠加 `seccomp-bpf` 过滤器强制执行（`network_access = false` 时内核拒绝非 `AF_UNIX`/`AF_NETLINK` 的 `socket()` 以及 `io_uring`/`ptrace`），`codex doctor` 也会如实标明 Android 为"部分沙箱"。审批提示属于应用层逻辑，没有改动：需要把关时用 `approval_policy = "untrusted"`。
- **语音和实时对话。** 音频相关的 crate 只为 macOS、linux-gnu、Windows 构建；TUI 里 `/voice` 会提示无法识别。
- **剪贴板图片粘贴。** 上游自己在 Android 上就关掉了。
- **凭据存在 `$CODEX_HOME/auth.json`。** Android 上没有系统钥匙串，上游的 `keyring` 在这里没有后端。

## 已用 Termux:API 补齐的可选能力

以下功能需要同时安装 Termux:API 应用和 Termux 包（`pkg install termux-api`）；未安装时不影响主流程，会自动降级：

- **剪贴板文字复制与粘贴（补丁 0022）**：`/copy`、导出对话到剪贴板、右键粘贴已重新启用，底层调用 `termux-clipboard-set` / `termux-clipboard-get`；未装 Termux:API 时复制自动回退到 OSC 52。
- **后台完成/审批通知（补丁 0024）**：通知方式为 `auto`（默认）且检测到 `termux-notification` 时，自动通过 Android 系统通知提醒任务完成或等待审批；未装时回退到终端 BEL。

## 仍未实现的部分

文件系统隔离在无 root 的 Android 内核上只能靠 ptrace 或 seccomp 通知这类折中办法，实现复杂、开销大且不严格，目前不打算做。

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

**没验证**：`mcp login` / `logout`（需要 OAuth 服务器）、`cloud exec` / `status` / `diff` / `apply` 和 `apply`（账号里没有云任务）、从 Git 或远程市场安装插件（需要网络源）、`exec-server forward`、IDE 上下文通信。
