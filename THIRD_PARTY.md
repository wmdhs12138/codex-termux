# Third-party software

This repository contains build scripts and patches. It does not vendor Codex or V8 source.

| Component | License | Notes |
| --- | --- | --- |
| [openai/codex](https://github.com/openai/codex) | Apache-2.0 | Fetched at build time by tag. `patches/` are modifications of its files and remain under Apache-2.0. The release tarball includes upstream `LICENSE` and `NOTICE`. |
| [V8](https://v8.dev) 15.2 | BSD-3-Clause | Code Mode's JavaScript engine, linked statically into `codex-code-mode-host` from the archive that `scripts/build-rusty-v8.sh` builds (released as `rusty-v8-v*`). |
| [rusty_v8](https://github.com/denoland/rusty_v8) (crate `v8`) | MIT | Rust bindings to V8, at the version upstream pins; its C++ half is in the same archive. |
| [ICU](https://icu.unicode.org) and its data | Unicode License v3 | Compiled into the V8 archive; Code Mode loads the data from the `deno_core_icudata` crate. See <https://www.unicode.org/license.txt>. |
| Libraries V8 bundles | Apache-2.0, MIT, BSD, Unicode-3.0 | Also in the archive: Chromium's libc++, libc++abi, libunwind and llvm-libc (Apache-2.0 WITH LLVM-exception), Abseil, simdutf, Highway, fast_float, dragonbox, FP16, and temporal_rs with its ICU4X crates. Their license files are under `third_party/` in the rusty_v8 checkout at the tag; Apache-2.0's text is the `LICENSE` in the tarball. |
| Rust, Termux packages | various | Installed in the build container; not redistributed. |

Release binaries are statically linked against Rust crates pulled in by the upstream
`Cargo.lock`; their licenses are those of the respective crates. The binaries dynamically link
Termux's OpenSSL and liblzma runtimes (`pkg install openssl liblzma`).

"Codex" and "OpenAI" are trademarks of their owners. This project is not affiliated with or
endorsed by OpenAI.

## License texts

### V8

```text
This license applies to all parts of V8 that are not externally
maintained libraries.  The externally maintained libraries used by V8
are:

  - PCRE test suite, located in
    test/mjsunit/third_party/regexp-pcre/regexp-pcre.js.  This is based on the
    test suite from PCRE-7.3, which is copyrighted by the University
    of Cambridge and Google, Inc.  The copyright notice and license
    are embedded in regexp-pcre.js.

  - Layout tests, located in test/mjsunit/third_party/object-keys.  These are
    based on layout tests from webkit.org which are copyrighted by
    Apple Computer, Inc. and released under a 3-clause BSD license.

  - Strongtalk assembler, the basis of the files assembler-arm-inl.h,
    assembler-arm.cc, assembler-arm.h, assembler-ia32-inl.h,
    assembler-ia32.cc, assembler-ia32.h, assembler-x64-inl.h,
    assembler-x64.cc, assembler-x64.h, assembler.cc and assembler.h.
    This code is copyrighted by Sun Microsystems Inc. and released
    under a 3-clause BSD license.

  - Valgrind client API header, located at third_party/valgrind/valgrind.h
    This is released under the BSD license.

  - The Wasm C/C++ API headers, located at third_party/wasm-api/wasm.{h,hh}
    This is released under the Apache license. The API's upstream prototype
    implementation also formed the basis of V8's implementation in
    src/wasm/c-api.cc.

These libraries have their own licenses; we recommend you read them,
as their terms may differ from the terms below.

Further license information can be found in LICENSE files located in
sub-directories.

Copyright 2014, the V8 project authors. All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### rusty_v8

```text
MIT License

Copyright (c) 2018-2019 the Deno authors

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
