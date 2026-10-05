# Third-party software

This repository contains build scripts and patches only. It does not vendor
Codex source.

| Component | License | Notes |
| --- | --- | --- |
| [openai/codex](https://github.com/openai/codex) | Apache-2.0 | Fetched at build time by tag. `patches/` are modifications of its files and remain under Apache-2.0. The release tarball includes upstream `LICENSE` and `NOTICE`. |
| Rust, Termux packages | various | Installed in the build container; not redistributed. |

Release binaries are statically linked against Rust crates pulled in by the
upstream `Cargo.lock`; their licenses are those of the respective crates. The
binary dynamically links Termux's OpenSSL runtime (`pkg install openssl`).

"Codex" and "OpenAI" are trademarks of their owners. This project is not
affiliated with or endorsed by OpenAI.
