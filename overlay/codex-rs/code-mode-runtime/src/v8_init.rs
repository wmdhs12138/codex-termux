//! QuickJS needs no process-wide initialization. The V8 entry points survive as no-ops so the
//! crate keeps the same public API (`V8JitMode`, `initialize_v8`); there is no JIT to configure.

/// Controls whether V8 may generate executable code at runtime. Ignored: QuickJS is an
/// interpreter.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum V8JitMode {
    #[default]
    Enabled,
    Disabled,
}

/// Kept for API compatibility; always succeeds.
pub fn initialize_v8(_jit_mode: V8JitMode) -> Result<(), String> {
    Ok(())
}
