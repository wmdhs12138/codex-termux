//! The UI plugin process, without V8.
//!
//! Upstream runs UI plugin scripts in V8 isolates (`engine.rs` drives `v8::Isolate` directly)
//! and refuses to start unless V8's sandbox is enabled. QuickJS has neither, so this build keeps
//! only the entry point behind `codex-code-mode-host --codex-ui-plugin-process` and reports the
//! sandbox as unavailable; the other files in this directory are not compiled. In rust-v0.166.0
//! nothing outside upstream's tests starts this process.

use std::io;

pub fn run() -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "the UI plugin sandbox needs V8, which this build replaces with QuickJS",
    ))
}
