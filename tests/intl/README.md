# tests/intl/

维护 `overlay/.../runtime/intl.js`（QuickJS 里的 `Intl`）用的工具。它们需要一个带完整 ICU 的 JS 引擎作参照物，所以在手机上用 `pkg install nodejs`，**不进 CI**；CI 里跑的是 Rust 测试（`runtime/intl.rs`），它读这里生成的期望值。

| 文件 | 作用 |
| --- | --- |
| `gen-data.mjs` | 从参照引擎导出 en-US 的数据表（货币符号和名称、单位模板、相对时间、列表连接词、时区名称），`node gen-data.mjs > ../../overlay/codex-rs/code-mode-runtime/src/runtime/intl_data.json`。参照引擎的 ICU/CLDR 版本变了就重新生成。 |
| `oracle.mjs` | 把 `intl.js` 装进一个删掉了原生 `Intl` 的新 Node 领域里，和原生并排调用；时区用原生 `Intl` 模拟（真实运行时是 Rust 的 jiff）。 |
| `fuzz.mjs` | 对拍：几万个“数字/日期/排序/复数/相对时间/列表/分词”的组合，打印不一致的项（`ONLY=date SHOW=10 node fuzz.mjs` 只跑一组、多看几条）。唯一预期的差异是 `supportedLocalesOf(["zh-CN"])`：只有英语有数据。 |
| `gen-cases.mjs` | 生成 `runtime/intl_cases.json`：约 1500 个表达式和参照引擎给出的结果，Rust 测试在 QuickJS 里逐条核对。有意的差异（非英语区域回落到 en-US、`DisplayNames` 不存在）写在这个文件的 `deviations` 里。 |

改了 `intl.js` 之后：`node fuzz.mjs`（应只剩上面那一个差异）→ `node gen-cases.mjs` → 拷数据 → `cargo test -p codex-code-mode-runtime intl`（见 [../../docs/maintaining.md](../../docs/maintaining.md)）。

`tznames.txt` 是 jiff 内置时区库（`jiff-tzdb`）里的全部时区名，含别名（`Asia/Kolkata` 这类 ICU 用旧名 `Asia/Calcutta` 的）；`gen-data.mjs` 用它给每个名字都建上时区名称，jiff 升级后重新导出。
