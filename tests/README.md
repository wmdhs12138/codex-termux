# tests/

测试在 CI 的 Bionic 环境里运行（见 [../docs/ci.md](../docs/ci.md)），也都可以在手机上直接对任意一个 `codex` 二进制运行，比如从 Release 下载解压出来的那个。需要：`bash`、`python3`、`jq`；TUI 相关的还需要 `script` 和 `strings`。

| 文件 | 作用 |
| --- | --- |
| `test_install.sh` | `install.sh` 的离线场景（12 个）：全新安装、无变化不重复下载、缺宿主程序、哈希被改、降级、慢 `tar -t` 的回归，以及更新后重启运行中的守护进程的几种情形。只需 bash、tar、sha256sum、python3。 |
| `test_daemon.sh <codex>` | 守护进程生命周期：自动链接、socket 路径长度、`/proc` 身份记录、不带远程控制、start / 复用 / version / restart / stop / bootstrap。 |
| `test_daemon_session.sh <codex>` | 一个客户端经守护进程的控制 socket 跑完整的 Code Mode 会话，结果交给 `check_code_mode.py` 检查。 |
| `test_daemon_tui.sh <codex>` | 真 TUI 在伪终端里用默认设置自动启动并连上守护进程；再测 `--no-daemon` 和 `features.daemon_auto_start=false` 两种关闭方式。 |
| `test_subcommands.sh <codex>` | 不需要网络和账号的子命令：一个 stdio MCP 服务器（`mcp_echo.py`）被模型经 Code Mode 调用，`plugin` 用本地市场走完添加、安装、列表、卸载，`exec resume`、`archive` / `unarchive` / `delete`、`migrate-rollouts`、`features`、`completion`。 |
| `daemon_session.py` | 上面会话测试用的最小客户端：标准库实现的 WebSocket over UDS + JSON-RPC（`initialize`、`thread/start`、`turn/start`，等到 `turn/completed`）。 |
| `mock_responses.py` | 假的 OpenAI Responses API：记录每个请求到 `request-N.json`，并按脚本回答，让 `codex exec` 和守护进程不用网络和账号就能被测试。 |
| `code_mode_script.py` / `check_code_mode.py` | Code Mode 的主测试：假模型发出多次 `exec`（文本、嵌套工具调用、`store`/`load`、`exit()`、定时器、运行时错误、工作区外 `apply_patch` 被拒），检查模型收到的结果。 |
| `code_mode_wait_script.py` / `check_code_mode_wait.py` | 超过让出时间的脚本：`exec` 先返回已有输出和 cell id，`wait` 取回剩下的部分。 |
| `tool_names.py` | 打印一个请求里提供给模型的所有工具名（兼容 `additional_tools` 与 `namespace`）。 |

`test_daemon*.sh` 的 `DAEMON_TEST_SEED=1` 用于补丁 0013 之前构建的 `codex`（没有自动链接，手动建好守护进程的 package）。

另见 `../scripts/bench-startup.py`：测 TUI 启动耗时（嵌入式对比连守护进程）。
