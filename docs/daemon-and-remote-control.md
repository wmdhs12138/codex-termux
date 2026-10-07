# 共享后台服务与远程控制

## 共享后台服务

### 是什么
`codex app-server daemon` 是上游自带的后台服务端：一个常驻进程，只监听本机的 unix socket（目录权限 0700，只有你的 Termux 用户能连），不开网络端口，也不连 ChatGPT 后端。交互界面启动时自动拉起它并连上去，而不是各自嵌入一个服务端。和官方在 PC 上一样，**默认开启**。

### 开关
| 想要 | 做法 |
| --- | --- |
| 只这一次不用 | `codex --no-daemon` |
| 一直不用 | `config.toml` 里设 `[features]` 下 `daemon_auto_start = false` |
| 查看、手动控制 | `codex app-server daemon start / restart / stop / version / bootstrap`，`codex doctor` 的 Background Server 一节也会显示状态 |
| 浏览全部会话 | `codex agents` |

### 在 Android 上做了什么调整
上游假设它运行在官方安装包的目录布局里，并把 socket 放在 `/tmp`。这里的对应处理（细节见 [patches.md](patches.md)）：

- 0011：socket 目录改到 Termux 前缀下的 `tmp`，并把路径里的摘要截短，保证不超过 `sun_path` 的 107 字节；
- 0012、0014：进程身份和启动时间改读 `/proc/<pid>/stat`，不依赖 `ps`；
- 0013：守护进程的「package」是两个符号链接 `~/.codex/packages/app-server-daemon/current → releases/android` 和 `releases/android/bin/codex → 正在运行的 codex`，因此守护进程运行的就是你装的这个二进制，不需要另外安装，也不多占 300 MB；
- 0017：启动时导出 `TERMUX__SE_PROCESS_CONTEXT`。没有它，守护进程派生的子进程偶尔会在 exec 之前卡死在 termux-exec 里，并一直占着控制 socket。

`codex update` 会运行 `install.sh`；装入了不同的二进制后，如果守护进程在运行，安装器会执行 `codex app-server daemon restart` 让它换上新版本（`CODEX_TERMUX_SKIP_DAEMON_RESTART=1` 可关闭）。上游的 `daemon update`（用官方安装器更新）和后台自动更新器不支持：官方安装器装的是官方的 Linux 二进制，不能在 Android 上运行。

### 代价（在一台 Android 16 手机上实测，空闲）
| | 内存 |
| --- | --- |
| 嵌入式，一个界面 | 约 300 MB |
| 守护进程模式，一个界面 | 界面约 90 MB，另有常驻的守护进程约 270 MB（匿名内存约 195 MB，3 分钟内不增长） |

只开一个界面时守护进程模式更占内存，同时开两个以上才更省。守护进程在界面退出后仍然留着，直到被系统杀掉或 `codex app-server daemon stop`。

启动耗时（到状态栏显示出模型名，每种 7 次取中位数，脚本：`scripts/bench-startup.py`）：

| | 耗时 |
| --- | --- |
| 真实 home（约 100 MB 状态），嵌入式 | 约 1.1 秒 |
| 真实 home，连已在运行的守护进程 | 约 0.7 秒 |
| 全新的空 home，嵌入式 | 约 0.17 秒 |
| 全新的空 home，连已在运行的守护进程 | 约 0.64 秒（连接有固定开销） |
| 全新的空 home，守护进程没在运行的第一次启动 | 约 1.0 秒 |

嵌入式每次都要重新加载状态，状态越多越慢；守护进程只加载一次。

### 要注意的事
- **守护进程被杀（Android 后台限制、`codex update` 的重启）时，已连上的界面会报 `transport failed: Connection reset without closing handshake` 并退出**，嵌入式没有这个问题。按设计，下一次运行 `codex` 会重新拉起它。
- 守护进程沿用**它启动那一刻的环境变量**（上游文档也这么写）：之后在新终端里改的 `PATH`、代理等，不会影响模型在界面里执行的命令，除非重启守护进程。
- 配置（比如目录信任）会被实时读取，不需要重启。
- 排障：`packages/app-server-daemon/current` 如果是手工建的真实目录而不是符号链接，链接这一步会报 `Is a directory`，删掉它让 Codex 重建即可。
- 排障（0017 之前的版本）：`daemon restart` 报 `timed out probing app-server control socket`，同时 `~/.codex/app-server-daemon/daemon.stderr.log` 里是 `control socket is already in use`，说明旧守护进程留下的子进程卡在 exec 之前，占着 socket。它的命令行和守护进程一样，但只有一个线程：用 `for p in $(pgrep -f 'app-server --listen unix://'); do echo "$p $(grep Threads /proc/$p/status)"; done` 找到 `Threads: 1` 的那个，`kill -9` 掉（它继承了守护进程的 SIGTERM 处理函数，普通 `kill` 杀不掉），再 `codex app-server daemon restart`。

## 远程控制

### 是什么
把这台手机登记到你的 ChatGPT 账号，配对过的 ChatGPT 客户端（手机或桌面应用）就能在这台机器上开会话、跑任务。和官方一致，**需要主动开启**：上游的守护进程设置 `remoteControlEnabled` 默认是 `false`，PC 上也是。

### 步骤
1. `codex remote-control start`：持久化开启，并起带远程控制的守护进程；
2. `codex remote-control pair`：打印一个短时配对码；
3. 在 ChatGPT 应用里输入配对码添加这台设备。**没有配对时设备在应用里是看不到的。**

配对后设备出现在应用里，设备名是 `<品牌> · Termux`（例如 `vivo · Termux`，补丁 0015；之前是 Android 的主机名 `localhost`）。

### 让应用能开会话：目录信任
应用开会话时会检查目录的信任状态，并且只认 `~/.codex/config.toml` 里与该目录**完全匹配**的记录，父目录不会继承，否则报"无法验证项目信任状态"。需要给用到的每个目录加上：

```toml
[projects."/data/data/com.termux/files/home/projects/my-repo"]
trust_level = "trusted"
```

（也可以在应用里用"只读"模式启动。）上游的本地界面能自己判断"无项目目录"，远程客户端不能。

### 关闭
`codex app-server daemon disable-remote-control`（持久化关闭并重启守护进程，不带远程控制）；`codex remote-control stop` 只停守护进程，不清除保存的开关。设备在账号里的登记不会因此被删除；如需移除，请在 ChatGPT 应用的设备列表里操作（这一步没有验证过）。

### 验证情况
在真机上验证过：开启、配对、设备出现、应用里能开会话。**没有验证**：前台的 `codex remote-control`（不带子命令）是否同样需要配对；长时间运行的稳定性。这部分不在 CI 里测（需要账号，并会向后端登记设备）。
