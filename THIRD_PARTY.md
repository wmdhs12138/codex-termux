# Third-party software

This repository contains build scripts, patches and a JavaScript runtime layer. It does not
vendor Codex source.

| Component | License | Notes |
| --- | --- | --- |
| [openai/codex](https://github.com/openai/codex) | Apache-2.0 | Fetched at build time by tag. `patches/` are modifications of its files and remain under Apache-2.0. The release tarball includes upstream `LICENSE` and `NOTICE`. |
| [rquickjs](https://github.com/DelSkayn/rquickjs) 0.14 | MIT | Rust bindings used by `overlay/`, which replaces the V8 layer of Codex's Code Mode. |
| [QuickJS-ng](https://github.com/quickjs-ng/quickjs) | MIT | The JavaScript engine, compiled into `codex-code-mode-host` through `rquickjs-sys`. |
| [jiff](https://github.com/BurntSushi/jiff) 0.2 | MIT OR Unlicense | IANA time zone database access for `Intl.DateTimeFormat` in Code Mode (patch 0016); reads Android's tzdata and bundles a copy as the fallback. |
| Unicode CLDR / ICU data | Unicode License v3 | The en-US tables in `overlay/.../runtime/intl_data.json` (currency symbols and names, unit patterns, relative time, list patterns, time zone names) were generated from ICU's data by `tests/intl/gen-data.mjs`. See <https://www.unicode.org/license.txt>. |
| Rust, Termux packages | various | Installed in the build container; not redistributed. |

Release binaries are statically linked against Rust crates pulled in by the upstream
`Cargo.lock`; their licenses are those of the respective crates. The binaries dynamically link
Termux's OpenSSL and liblzma runtimes (`pkg install openssl liblzma`).

"Codex" and "OpenAI" are trademarks of their owners. This project is not affiliated with or
endorsed by OpenAI.

## License texts

### QuickJS-ng

```text
The MIT License (MIT)
 
Copyright (c) 2017-2026 Fabrice Bellard
Copyright (c) 2017-2024 Charlie Gordon
Copyright (c) 2023-2026 Ben Noordhuis
Copyright (c) 2023-2026 Saúl Ibarra Corretgé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### rquickjs

```text
MIT License

Copyright (c) 2020 Mees Delzenne
Copyright (c) 2025 Rquickjs Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
