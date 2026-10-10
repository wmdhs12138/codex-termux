# tests/

测试在 CI 的 Bionic 环境里运行（见 [../docs/ci.md](../docs/ci.md)），也都可以在手机上直接对任意一个 `codex` 二进制运行，比如从 Release 下载解压出来的那个。需要：`bash`、`python3`、`jq`；TUI 相关的还需要 `script` 和 `strings`。

| 文件 | 作用 |
| --- | --- |
| `test_ci.py` | 发布逻辑（`python3 -m unittest -v tests/test_ci.py`，CI 的 `tests` 任务运行）：在临时 git 仓库里用假的 `gh` 真实执行 workflow 的 resolve 和 release 步骤：新版本用 `vX.Y.Z`、`recut` 取下一个 `-rN`、tag 钉在构建的提交上、旧版本重发不抢 Latest、被占用的 tag 名自动顺延、说明里列出相对上一个 Release 的补丁变更。需要 bash、git、jq、python3。 |
| `test_install.sh` | `install.sh` 的离线场景（12 个）：全新安装、无变化不重复下载、缺宿主程序、哈希被改、降级、慢 `tar -t` 的回归，以及更新后重启运行中的守护进程的几种情形。只需 bash、tar、sha256sum、python3。 |
| `test_daemon.sh <codex>` | 守护进程生命周期：自动链接、socket 路径长度、`/proc` 身份记录、不带远程控制、start / 复用 / version / restart / stop / bootstrap。 |
| `test_daemon_session.sh <codex>` | 一个客户端经守护进程的控制 socket 跑完整的 Code Mode 会话，结果交给 `check_code_mode.py` 检查。 |
| `test_daemon_tui.sh <codex>` | 真 TUI 在伪终端里用默认设置自动启动并连上守护进程；再测 `--no-daemon` 和 `features.daemon_auto_start=false` 两种关闭方式。 |
| `test_subcommands.sh <codex>` | 不需要网络和账号的子命令：一个 stdio MCP 服务器（`mcp_echo.py`）被模型经 Code Mode 调用，`plugin` 用本地市场走完添加、安装、列表、卸载，`exec resume`、`archive` / `unarchive` / `delete`、`migrate-rollouts`、`features`、`completion`。 |
| `test_update_prompt.sh <codex>` | 补丁 0018：手写更新检查的缓存（`version.json` 和按真实二进制生成的 `termux-build.json`），在伪终端里启动 TUI：同版本的另一个构建会弹出提示并写明构建哈希；正在运行的构建不提示；检查之后二进制被替换时不拿旧哈希提示；「不再提醒」只忽略那一个构建。再对 github.com 做一次真实检查：最新 Release 就是当前版本时，必须记录下正在运行的二进制（没有网络时只报告）。 |
| `test_se_context.sh <codex>` | 补丁 0017：在 `shell_environment_policy.inherit = "core"` 下模型执行的命令、MCP 服务器（环境是白名单）和守护进程都拿到 `TERMUX__SE_PROCESS_CONTEXT`，值与 termux-exec 自己的校验规则一致；没有 SELinux 的环境（CI 的容器）里则什么都不导出。 |
| `daemon_session.py` | 上面会话测试用的最小客户端：标准库实现的 WebSocket over UDS + JSON-RPC（`initialize`、`thread/start`、`turn/start`，等到 `turn/completed`）。 |
| `mock_responses.py` | 假的 OpenAI Responses API：记录每个请求到 `request-N.json`，并按脚本回答，让 `codex exec` 和守护进程不用网络和账号就能被测试。 |
| `code_mode_script.py` / `check_code_mode.py` | Code Mode 的主测试：假模型发出多次 `exec`（文本、嵌套工具调用、`store`/`load`、`exit()`、定时器、运行时错误、工作区外 `apply_patch` 被拒、`Intl` 与 `toLocaleString`/`localeCompare`），检查模型收到的结果。 |
| `intl/` | 维护 QuickJS 里 `Intl` 实现的工具（对拍、生成数据和期望值），需要带完整 ICU 的 Node，不进 CI；说明见 [intl/README.md](intl/README.md)。Rust 侧的测试在 `overlay/.../runtime/intl.rs`。 |
| `code_mode_wait_script.py` / `check_code_mode_wait.py` | 超过让出时间的脚本：`exec` 先返回已有输出和 cell id，`wait` 取回剩下的部分。 |
| `tool_names.py` | 打印一个请求里提供给模型的所有工具名（兼容 `additional_tools` 与 `namespace`）。 |

`test_daemon*.sh` 的 `DAEMON_TEST_SEED=1` 用于补丁 0013 之前构建的 `codex`（没有自动链接，手动建好守护进程的 package）。

另见 `../scripts/bench-startup.py`：测 TUI 启动耗时（嵌入式对比连守护进程）。
