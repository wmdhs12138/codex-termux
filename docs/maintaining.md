# 维护手册

给维护者（包括以后的自己）。构建都在 CI 里做，手机上只改补丁、做小的 `cargo check`。

## 上游发新版本

每天 03:00 UTC 的构建会自动发现新的稳定版并发布，不需要人工操作。但补丁是精确匹配的，所以新版本可能让构建失败。先手动核对最稳妥（几秒钟，不用编译）：

```bash
git clone --depth 1 --branch rust-v<新版本> https://github.com/openai/codex.git /tmp/x   # 手机上用 $TMPDIR
cd x && for p in /path/to/codex-termux/patches/*.patch; do git apply --check "$p" && git apply "$p"; done
grep '^v8 = ' codex-rs/Cargo.toml
```

补丁打不上，就说明上游改了我们改过的文件：对着新版本重做那个补丁。`versions.json` 里的 `version` 是 `scripts/build.sh` 的默认版本，一般不用手改。

上游换了 `v8` 版本（上面 `grep` 的结果变了）也不用手动处理：`build.yml` 会先调用 `rusty-v8.yml` 编出新版本的归档（多花约两小时），再构建 Codex。新版本的 V8 编译失败时，对照 rusty_v8 两个 tag 之间 `build.rs` 和 `build` 子模块的变化修 `scripts/build-rusty-v8.sh`；`tests/v8-smoke` 编译失败，通常是 ICU 数据的初始化接口改了名（`set_common_data_78` 之类），照上游 `code-mode-runtime/src/v8_init.rs` 的改动同步。

## 改或加补丁

1. 在上游 tag 的干净检出上，依次打上现有补丁，把结果提交成一个本地基线。
2. 改文件，用 `git diff -- <路径>` 导出成新补丁，放进 `patches/`，文件名 `NNNN-说明.patch`（编号只增不复用）。
3. 在一个干净检出上，把整套补丁按顺序 `git apply --check` 一遍，对当前上游版本和下一个版本都做。
4. 在手机上 `pkg install rust cmake protobuf`，只对改到的 crate 做 `cargo check -p <crate>`（约 10 分钟，比 CI 一轮便宜得多）。用完卸掉工具链。依赖 V8 的 crate（`codex-code-mode-runtime`、`codex-code-mode-host`）要先有归档：把 Release `rusty-v8-v<版本>-b<N>` 的文件放进 `$WORK/rusty_v8/` 下同名的目录，再 `source scripts/cargo-env.sh`（`scripts/build.sh` 就是这样做的）。
5. 要有测试：在 `tests/` 加用例，并先在手机上对现有的 Release 二进制跑一遍；最好再对改动前的二进制跑一次，确认它会失败。
6. 提交带 `[skip ci]`，然后手动 `gh workflow run build.yml -f version=<版本> -f recut=true`，避免一次推送触发两轮构建。

## 发版

- tag 是 `vX.Y.Z`；同一个上游版本因为补丁变化重新发布，tag 是 `vX.Y.Z-rN`。release 任务只创建、从不修改已有的 Release；仓库开启不可变发布后由 GitHub 强制，被撤回的版本名也永远被占用，release 任务遇到这种情况会自动改用下一个 `-rN`。
- tag 用 `--target` 钉在 CI 构建它的那个提交上；发布说明列出相对上一个 Release 的补丁和工具链变更（不含 `docs/`、`tests/` 和 Markdown）。
- `-rN` 不改版本号，所以安装器和启动时的更新提示都按二进制哈希判断（提示见补丁 0018；没有 0018 的旧版本只能靠手动 `codex update` 装上）。
- 只有 `bionic` 全绿，`release` 才会发布；只有最高的 Codex 版本会成为 Latest，所以重新发布旧版本不会让安装器回退。**所以在有发布中的构建时，别往 `main` 推会触发完整构建的提交**；已经在跑的构建要先 `gh run cancel`，等它真的变成 cancelled 再重发。
- `codex update` 运行的是 `main` 上的 `install.sh`，所以只改安装器不需要发版，推上去就生效。
- `rusty-v8-v*` 是构建用的 V8 归档，不是 Codex 版本：发布时从不成为 Latest，release 任务找上一个版本和最高版本时也只看 `v*` tag。改了 `scripts/build-rusty-v8.sh` 或 `patches/rusty_v8/`、会改变归档时，把 `versions.json` 的 `rusty_v8_build` 加一：tag 名用过就不能再用，新编号让下一次构建自动编出新归档。

## 踩过的坑

- **`set -o pipefail` 下，管道不要以会提前退出的读取端结尾**（`grep -q`、`head -1`）：写入端会因 SIGPIPE 退出，整条管道就算失败。曾经 `tar -t | grep -q` 在读 300 MB 的成员时返回 141，导致安装器把宿主程序删掉了。测试要用能模拟慢速 `tar` 的 shim，小的替身 tarball 看不出这个问题。
- 任务日志要等整个 run 结束才可读。
- termux-docker：默认软件源滞后，固定 `packages.termux.dev`；`docker run -e` 的变量传不进命令，版本通过文件传。
- Rust 标准库 `File::lock` 在 Android 上要 1.98 起（Termux 现在是 1.99）。
- rusty_v8 交叉编译 Android：`build.rs` 把 NDK 放在 `third_party/android_ndk`，Chromium 的构建却只认 `third_party/android_toolchain/ndk`，还要求声明 `android_ndk_version`，否则 GN 直接报错；bindgen 要单独给 Android 的 `--target` 和 `--sysroot`。归档链接时还缺 compiler-rt（`__clear_cache`）和 `liblog`。这些都在 `scripts/build-rusty-v8.sh` 和 `scripts/cargo-env.sh` 里处理了。
- V8 沙箱的大小是编译期常量（`kSandboxSizeLog2`），只有按 `target_os="android"` 编译才会缩到 128 GB。非 Android 版要预留 1 TB，在 39 位地址空间的手机上启动就会断言失败，所以拿 linux 版的归档凑不出能用的沙箱。
- gpt-6.x 是"responses lite"：工具在输入里的 `additional_tools` 项，不在顶层 `tools`（`tests/tool_names.py` 两处都读）。`codex exec` 会强制审批策略为 never，并且需要 `</dev/null`。`codex debug prompt-input` 不显示工具。
- Android 没有内核沙箱：doctor 里"restricted fs + network"只是配置，不是强制。`web_search` 在非 full access 时默认是缓存的，补丁 0007 在这里默认改成实时。
- `CODEX_HOME` 不能放在 `$PREFIX/tmp` 下：Codex 拒绝在临时目录里创建它的辅助二进制。
- 守护进程的 socket 路径受 `sun_path`（107 字节）限制；Termux 前缀很长，物理路径要留意长度，客户端经 `app-server-control.sock` 这个软链连接。
- termux-exec 的 `execve` 钩子在 fork 之后、exec 之前用 stdio 读 `/proc/self/attr/current`，多线程进程里会偶发死锁（补丁 0017 用 `TERMUX__SE_PROCESS_CONTEXT` 绕开）。卡死的子进程的特征：线程数 1、`utime` 为 0、`/proc/<pid>/syscall` 第一个数是 98（futex），栈上（`/proc/<pid>/mem`）能找到 `libtermux-exec-ld-preload.so` 的返回地址（libc 自己的帧在栈上找不到，只有一个指向 "Contending for pthread mutex" 的字符串指针）。
- 在手机上 `cargo check` 偶尔会遇到 `Text file busy`（并行构建时 fork 与写文件的竞争），重跑即可。
- 手机上没有 `/tmp`（不可写）：临时文件放 `$TMPDIR` 或任务目录。
