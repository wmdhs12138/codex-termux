//! Smoke test for a rusty_v8 archive built for aarch64-linux-android by
//! scripts/build-rusty-v8.sh; .github/ci/rusty-v8-smoke.sh runs it before the archive is published.
//!
//! Initializes V8 the way codex-rs/code-mode-runtime/src/v8_init.rs does, then checks what scripts
//! rely on (full ICU, Temporal) and what Android could break: the sandbox's address space
//! reservation (Android kernels often give user space only 39 bits; the full one takes about
//! 288 GiB) and executable memory for the JIT. `--jitless` runs without the JIT, like Codex's
//! `V8JitMode::Disabled`. Exits 1 unless the sandbox is enabled and every check passes.

use std::fs;

unsafe extern "C" {
    // rusty_v8 exports this for checking that the linked V8 has the sandbox.
    fn v8__V8__IsSandboxEnabled() -> bool;
}

const CHECKS: &str = r#"
(() => {
  const out = { failures: [] };
  const check = (name, run, expected) => {
    try {
      const value = run();
      out[name] = value;
      if (expected !== undefined && value !== expected) {
        out.failures.push(`${name}: got ${JSON.stringify(value)}, want ${JSON.stringify(expected)}`);
      }
    } catch (error) {
      out[name] = `threw ${error}`;
      out.failures.push(`${name}: ${error}`);
    }
  };
  check("intl_zh", () => new Intl.DateTimeFormat("zh-CN", { dateStyle: "full", timeZone: "Asia/Shanghai" }).format(new Date(0)), "1970年1月1日星期四");
  check("intl_de", () => new Intl.NumberFormat("de-DE", { style: "currency", currency: "EUR" }).format(1234567.891), "1.234.567,89 €");
  check("segmenter_zh", () => [...new Intl.Segmenter("zh", { granularity: "word" }).segment("我们的手机很好用")].map((s) => s.segment).join("|"));
  check("temporal", () => Temporal.PlainDate.from("2026-10-31").add({ days: 1 }).toString(), "2026-11-01");
  check("sort_mixed", () => [3, 1.5, "b", 2, "a"].sort().join(","), "1.5,2,3,a,b");
  check("array_buffer_256m", () => {
    const bytes = new Uint8Array(new ArrayBuffer(256 * 1024 * 1024));
    bytes[bytes.length - 1] = 7;
    return bytes[bytes.length - 1];
  }, 7);
  // (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
  const wasmAdd = new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
  ]);
  check("wasm_add", () => {
    try {
      return new WebAssembly.Instance(new WebAssembly.Module(wasmAdd)).exports.add(3, 4);
    } catch (error) {
      if (JITLESS) return `unavailable: ${error}`;
      throw error;
    }
  }, JITLESS ? undefined : 7);
  check("hot_loop", () => {
    const start = Date.now();
    let sum = 0;
    for (let i = 0; i < 5e7; i++) sum = (sum + i * i) % 1000003;
    out.hot_loop_ms = Date.now() - start;
    return sum;
  });
  out.ok = out.failures.length === 0;
  return JSON.stringify(out, null, 2);
})()
"#;

fn main() {
    let jitless = std::env::args().any(|arg| arg == "--jitless");

    v8::icu::set_common_data_78(deno_core_icudata::ICU_DATA).expect("ICU data");
    // Same flags as codex-rs/code-mode-runtime/src/v8_init.rs.
    v8::V8::set_flags_from_string("--no-maglev --no-turbolev --no-turbo-inline-array-builtins");
    if jitless {
        v8::V8::set_flags_from_string("--jitless");
    }
    let platform = v8::new_default_platform(0, false).make_shared();
    v8::V8::initialize_platform(platform);
    v8::V8::initialize();

    let sandbox = unsafe { v8__V8__IsSandboxEnabled() };
    println!("V8 {} sandbox={sandbox} jitless={jitless}", v8::V8::get_version());

    let source = format!("const JITLESS = {jitless};\n{CHECKS}");
    let report = {
        let isolate = &mut v8::Isolate::new(v8::CreateParams::default());
        v8::scope!(let handle_scope, isolate);
        let context = v8::Context::new(handle_scope, Default::default());
        let scope = &v8::ContextScope::new(handle_scope, context);
        let code = v8::String::new(scope, &source).unwrap();
        let script = v8::Script::compile(scope, code, None).expect("checks compile");
        let result = script.run(scope).expect("checks run");
        result.to_string(scope).unwrap().to_rust_string_lossy(scope)
    };
    println!("{report}");
    print_largest_mappings();

    let ok = sandbox && report.contains("\"ok\": true");
    std::process::exit(if ok { 0 } else { 1 });
}

/// Shows how much address space the sandbox reserved.
fn print_largest_mappings() {
    let maps = fs::read_to_string("/proc/self/maps").unwrap_or_default();
    let mut regions: Vec<(u64, &str)> = maps
        .lines()
        .filter_map(|line| {
            let (start, end) = line.split_whitespace().next()?.split_once('-')?;
            let size = u64::from_str_radix(end, 16).ok()? - u64::from_str_radix(start, 16).ok()?;
            Some((size, line))
        })
        .collect();
    regions.sort_by(|a, b| b.0.cmp(&a.0));
    const GIB: f64 = (1u64 << 30) as f64;
    let total: u64 = regions.iter().map(|(size, _)| size).sum();
    println!(
        "mapped: {:.1} GiB in {} regions, largest:",
        total as f64 / GIB,
        regions.len()
    );
    for (size, line) in regions.iter().take(4) {
        println!("  {:8.2} GiB  {line}", *size as f64 / GIB);
    }
}
