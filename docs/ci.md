# CI

所有构建都在 GitHub Actions 上完成，不在手机上编译（完整 release 构建约一小时，峰值内存接近 13 GB）。工作流是 [`.github/workflows/build.yml`](../.github/workflows/build.yml)，Bionic 里的步骤在 [`.github/ci/bionic-build.sh`](../.github/ci/bionic-build.sh)；Code Mode 链接的 V8 由 [`.github/workflows/rusty-v8.yml`](../.github/workflows/rusty-v8.yml) 编译（见[下文](#v8-归档rusty-v8yml)）。

## 任务

```text
resolve ── 决定上游版本和发布 tag，判断有没有新东西要发；读出上游锁定的 v8 版本，
   │       看对应的 rusty-v8-v<版本>-b<N> 是否已经发布
rusty_v8 ─ 只在还没发布时运行：调用 rusty-v8.yml 编译并发布（约两小时）
tests ──── 静态检查、安装器和发布逻辑的离线测试（ubuntu-latest，很快）
bionic ─── ubuntu-24.04-arm + 固定的 termux-docker 镜像：
   │       安装依赖 → 拉取上游 tag → 打补丁 → 下载并校验 V8 归档 → cargo build --release
   │       → 上游 code-mode 运行时的全部测试 → 在 Bionic 里真实执行（见下）
release ── 唯一有写权限的任务：发布 tarball、SHA-256 和 build-manifest.json；
           tag 钉在构建的提交上，只有最高版本成为 Latest，说明里列出变更
```

| 触发 | 做什么 |
| --- | --- |
| 推送到 `main` | 完整构建和测试；版本已发布过就不再发布 |
| 每天 03:00 UTC | 检查上游最新稳定版；只有新版本才构建，通过验收后自动发布 |
| 手动运行 | 构建指定版本；勾选 `recut` 在补丁变化后重新发布同一版本（`vX.Y.Z-rN`） |
| PR | 只跑 `resolve` 和 `tests`（静态检查、安装器和发布逻辑的测试） |

提交信息里带 `[skip ci]` 可以避免推送触发完整构建；之后用 `gh workflow run build.yml -f version=latest -f recut=true` 手动发布。

仅运行构建和 Bionic 验收、不创建 Release 或 tag：`gh workflow run build.yml -f version=0.164.0 -f publish=false`。`publish` 默认开启，定时构建和推送的发布行为不变；关闭它仍会上传构建产物供下载检查。

## Bionic 里真实执行了什么

| 阶段 | 内容 |
| --- | --- |
| 冒烟 | `--version`、`--help`；全新 `CODEX_HOME` 下 `codex login status` 报"未登录"；API key 登录往返；`codex exec` 能走过启动路径（状态库、rollout 写锁，用假 key，不依赖网络）；TUI 在伪终端里默认设置下起来，进入第一屏 |
| 假 Responses API（`tests/mock_responses.py`） | 模型实际拿到的工具列表；`apply_patch` 在工作区内真的写出文件、在工作区外被拒；网络搜索默认是实时；`codex update` 执行的命令是本项目的 `install.sh` |
| Code Mode 端到端 | 假模型发出多次 `exec`，检查文本输出、嵌套工具调用、`store`/`load`、`exit()`、定时器、运行时错误；超过让出时间的脚本与 `wait` |
| 共享后台服务 | `tests/test_daemon.sh`、`tests/test_daemon_session.sh`、`tests/test_daemon_tui.sh`（见 [../tests/README.md](../tests/README.md)） |
| 子命令 | `tests/test_subcommands.sh`：MCP、plugin、会话管理、features、completion |
| 依赖 | 二进制的动态库依赖必须在 Termux 默认就有的范围内 |

`codex doctor` 和对真实端点的连通性检查只输出到日志，不作为失败条件（数据中心 IP 可能被限流）。

## 失败了怎么看

- 任务日志要等整个 run 结束才能看；失败时 `codex-termux-debug` artifact 里有构建输出，可以下载到手机上排查。
- 脚本失败会打印 `FAILED: <脚本> line N: <命令> (exit rc)`。
- 补丁不再适用，构建会直接失败：这是有意的，说明上游改了被我们修改的文件，需要重新审阅。
- `build: cannot download …/rusty-v8-v<版本>-b<N>/…`：这个版本的 V8 归档没有发布。正常情况下 `rusty_v8` 任务会先把它编出来；它失败了就看它的日志，修好后可以单独运行 `gh workflow run rusty-v8.yml -f version=<版本>`。

## V8 归档（rusty-v8.yml）

rusty_v8 没有 Android 的预编译归档，所以本项目自己编（原因和做法见 [patches.md](patches.md#code-mode-的-v8)）。`build.yml` 在上游换了 `v8` 版本时自动调用它，也可以手动运行：`gh workflow run rusty-v8.yml -f version=152.2.0`。

```text
build ──── ubuntu-24.04（x86_64，rusty_v8 只支持从 x86_64 Linux 交叉编译 Android）：
   │       scripts/build-rusty-v8.sh，冷编译约两小时
smoke ──── ubuntu-24.04-arm + termux-docker：用 Termux 的 Rust 和 clang 把归档链接进
   │       tests/v8-smoke，开 JIT 和 --jitless 各跑一次
publish ── 唯一有写权限的任务：发布 Release rusty-v8-v<版本>-b<N>，从不设为 Latest；
           已经发布过的保留不动。N 是 versions.json 的 rusty_v8_build
```

编译缓存（sccache）存在 Actions 缓存里，失败的运行也会保存，修好后重跑只需编译没缓存的部分。缓存按分支隔离：在别的分支上第一次编译仍是冷编译。

## 固定的东西

`termux/termux-docker` 镜像和各个 action 都按 SHA 固定。镜像默认的软件源更新滞后（曾经给出 rust 1.97.1），脚本改用官方的 `packages.termux.dev`，并要求 rust ≥ `versions.json` 里的 `rust_min`（Android 上 `File::lock` 要 1.98 起）。
