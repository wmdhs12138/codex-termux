# 维护手册

给维护者（包括以后的自己）。构建都在 CI 里做，手机上只改补丁、做小的 `cargo check`。

## 上游发新版本

每天 03:00 UTC 的构建会自动发现新的稳定版并发布，不需要人工操作。但补丁是精确匹配的，所以新版本可能让构建失败。先手动核对最稳妥（几秒钟，不用编译）：

```bash
git clone --depth 1 --branch rust-v<新版本> https://github.com/openai/codex.git /tmp/x   # 手机上用 $TMPDIR
cd x && for p in /path/to/codex-termux/patches/*.patch; do git apply --check "$p" && git apply "$p"; done
sha256sum --check --quiet /path/to/codex-termux/overlay/UPSTREAM.sha256
```

补丁打不上，或 overlay 的哈希对不上，就说明上游改了我们改过或替换过的文件：对着新版本重做那个补丁（或重新审阅 overlay 再更新 `UPSTREAM.sha256`）。`versions.json` 里的 `version` 是 `scripts/build.sh` 的默认版本，一般不用手改。

## 改或加补丁

1. 在上游 tag 的干净检出上，依次打上现有补丁，把结果提交成一个本地基线（再把 `overlay/` 拷进去提交一次）。
2. 改文件，用 `git diff -- <路径>` 导出成新补丁，放进 `patches/`，文件名 `NNNN-说明.patch`（编号只增不复用）。
3. 在一个干净检出上，把整套补丁按顺序 `git apply --check` 一遍，对当前上游版本和下一个版本都做。
4. 在手机上 `pkg install rust cmake protobuf`，只对改到的 crate 做 `cargo check -p <crate>`（约 10 分钟，比 CI 一轮便宜得多）。用完卸掉工具链。
5. 要有测试：在 `tests/` 加用例，并先在手机上对现有的 Release 二进制跑一遍；最好再对改动前的二进制跑一次，确认它会失败。
6. 提交带 `[skip ci]`，然后手动 `gh workflow run build.yml -f version=<版本> -f recut=true`，避免一次推送触发两轮构建。

## 改 `Intl` 的实现

`overlay/.../runtime/intl.js` 的修改流程（需要 `pkg install nodejs`，它自带完整 ICU，用作参照物）：

1. 改 `intl.js`，然后 `cd tests/intl && node fuzz.mjs`：几万个组合与原生 `Intl` 对拍，应只剩一条预期的差异（`supportedLocalesOf` 里的 `zh-CN`）。`ONLY=date SHOW=10 node fuzz.mjs` 只跑一组。
2. 数据表（货币、单位、时区名称……）来自 `node gen-data.mjs > ../../overlay/codex-rs/code-mode-runtime/src/runtime/intl_data.json`（在 `tests/intl/` 里运行）。参照引擎的 ICU/CLDR 或时区库版本变了才需要重新生成；`tznames.txt` 是 jiff 内置库里的全部时区名（含别名），jiff 升级后重新导出。
3. `node gen-cases.mjs` 重新生成 `runtime/intl_cases.json`（Rust 测试用的期望值）；有意的差异写在这个脚本的 `deviations` 里。
4. `cargo test -p codex-code-mode-runtime`（和上面第 4 步一样，只在手机上跑这个 crate；整套约 2 秒，冷编译约 10 分钟）。

## 发版

- tag 是 `vX.Y.Z`；同一个上游版本因为补丁变化重新发布，tag 是 `vX.Y.Z-rN`（不可变发布会永久占用 tag 名）。
- 只有 `bionic` 全绿，`release` 才会发布，并自动成为 Latest。**所以在有发布中的构建时，别往 `main` 推会触发完整构建的提交**；已经在跑的构建要先 `gh run cancel`，等它真的变成 cancelled 再重发。
- `codex update` 运行的是 `main` 上的 `install.sh`，所以只改安装器不需要发版，推上去就生效。

## 踩过的坑

- **`set -o pipefail` 下，管道不要以会提前退出的读取端结尾**（`grep -q`、`head -1`）：写入端会因 SIGPIPE 退出，整条管道就算失败。曾经 `tar -t | grep -q` 在读 300 MB 的成员时返回 141，导致安装器把宿主程序删掉了。测试要用能模拟慢速 `tar` 的 shim，小的替身 tarball 看不出这个问题。
- 任务日志要等整个 run 结束才可读。
- termux-docker：默认软件源滞后，固定 `packages.termux.dev`；`docker run -e` 的变量传不进命令，版本通过文件传。
- Rust 标准库 `File::lock` 在 Android 上要 1.98 起（Termux 现在是 1.99）。`rquickjs-sys` 没有 Android 的预生成绑定，要开 `bindgen` 特性并设 `LIBCLANG_PATH`。
- QuickJS：`error.stack` 没有 "Name: message" 那一行，要补上；引擎会多出一些全局（`DOMException`、`InternalError`、`atob`、`btoa`、`performance`、`queueMicrotask`），要删掉；rquickjs 的 `Persistent` 句柄必须在运行时之前释放，否则 QuickJS 会因泄漏对象而中止。
- gpt-6.x 是"responses lite"：工具在输入里的 `additional_tools` 项，不在顶层 `tools`（`tests/tool_names.py` 两处都读）。`codex exec` 会强制审批策略为 never，并且需要 `</dev/null`。`codex debug prompt-input` 不显示工具。
- Android 没有内核沙箱：doctor 里"restricted fs + network"只是配置，不是强制。`web_search` 在非 full access 时默认是缓存的，补丁 0007 在这里默认改成实时。
- `CODEX_HOME` 不能放在 `$PREFIX/tmp` 下：Codex 拒绝在临时目录里创建它的辅助二进制。
- 守护进程的 socket 路径受 `sun_path`（107 字节）限制；Termux 前缀很长，物理路径要留意长度，客户端经 `app-server-control.sock` 这个软链连接。
- termux-exec 的 `execve` 钩子在 fork 之后、exec 之前用 stdio 读 `/proc/self/attr/current`，多线程进程里会偶发死锁（补丁 0017 用 `TERMUX__SE_PROCESS_CONTEXT` 绕开）。卡死的子进程的特征：线程数 1、`utime` 为 0、`/proc/<pid>/syscall` 第一个数是 98（futex），栈上（`/proc/<pid>/mem`）能找到 `libtermux-exec-ld-preload.so` 的返回地址（libc 自己的帧在栈上找不到，只有一个指向 "Contending for pthread mutex" 的字符串指针）。
- 在手机上 `cargo check` 偶尔会遇到 `Text file busy`（并行构建时 fork 与写文件的竞争），重跑即可。
- 手机上没有 `/tmp`（不可写）：临时文件放 `$TMPDIR` 或任务目录。
