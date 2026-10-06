# CI

所有构建都在 GitHub Actions 上完成，不在手机上编译（完整 release 构建约一小时，峰值内存接近 13 GB）。工作流是 [`.github/workflows/build.yml`](../.github/workflows/build.yml)，Bionic 里的步骤在 [`.github/ci/bionic-build.sh`](../.github/ci/bionic-build.sh)。

## 任务

```text
resolve ── 决定上游版本和发布 tag，判断有没有新东西要发
tests ──── 静态检查和安装器的离线测试（ubuntu-latest，很快）
bionic ─── ubuntu-24.04-arm + 固定的 termux-docker 镜像：
   │       安装依赖 → 拉取上游 tag → 打补丁和 overlay → cargo build --release
   │       → 上游 code-mode 运行时测试对 QuickJS 运行 → 在 Bionic 里真实执行（见下）
release ── 唯一有写权限的任务：发布 tarball、SHA-256 和 build-manifest.json
```

| 触发 | 做什么 |
| --- | --- |
| 推送到 `main` | 完整构建和测试；版本已发布过就不再发布 |
| 每天 03:00 UTC | 检查上游最新稳定版；只有新版本才构建，通过验收后自动发布 |
| 手动运行 | 构建指定版本；勾选 `recut` 在补丁变化后重新发布同一版本（`vX.Y.Z-rN`） |
| PR | 只跑 `resolve` 和 `tests`（静态检查和安装器测试） |

提交信息里带 `[skip ci]` 可以避免推送触发完整构建；之后用 `gh workflow run build.yml -f version=latest -f recut=true` 手动发布。

## Bionic 里真实执行了什么

| 阶段 | 内容 |
| --- | --- |
| 冒烟 | `--version`、`--help`；全新 `CODEX_HOME` 下 `codex login status` 报"未登录"；API key 登录往返；`codex exec` 能走过启动路径（状态库、rollout 写锁，用假 key，不依赖网络）；TUI 在伪终端里默认设置下起来，进入第一屏 |
| 假 Responses API（`tests/mock_responses.py`） | 模型实际拿到的工具列表；`apply_patch` 在工作区内真的写出文件、在工作区外被拒；网络搜索默认是实时；`codex update` 执行的命令是本项目的 `install.sh` |
| Code Mode 端到端 | 假模型发出多次 `exec`，检查文本输出、嵌套工具调用、`store`/`load`、`exit()`、定时器、运行时错误；超过让出时间的脚本与 `wait` |
| 共享后台服务 | `tests/test_daemon.sh`、`tests/test_daemon_session.sh`、`tests/test_daemon_tui.sh`（见 [../tests/README.md](../tests/README.md)） |
| 依赖 | 二进制的动态库依赖必须在 Termux 默认就有的范围内 |

`codex doctor` 和对真实端点的连通性检查只输出到日志，不作为失败条件（数据中心 IP 可能被限流）。

## 失败了怎么看

- 任务日志要等整个 run 结束才能看；失败时 `codex-termux-debug` artifact 里有构建输出，可以下载到手机上排查。
- 脚本失败会打印 `FAILED: <脚本> line N: <命令> (exit rc)`。
- 补丁不再适用或 overlay 里记录的上游文件哈希变了，构建会直接失败：这是有意的，说明上游改了被我们替换或修改的文件，需要重新审阅。

## 固定的东西

`termux/termux-docker` 镜像和各个 action 都按 SHA 固定。镜像默认的软件源更新滞后（曾经给出 rust 1.97.1），脚本改用官方的 `packages.termux.dev`，并要求 rust ≥ `versions.json` 里的 `rust_min`（Android 上 `File::lock` 要 1.98 起）。
