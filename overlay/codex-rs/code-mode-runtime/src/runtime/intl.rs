//! `Intl` for QuickJS, which is built without ICU.
//!
//! The implementation is `intl.js` (ECMA-402 for the en-US locale, see its header for the exact
//! scope) plus `intl_data.json` (currency, unit and time zone name tables generated from a
//! full-ICU engine by `tests/intl/gen-data.mjs`). The one thing JavaScript cannot do for itself is
//! the IANA time zone database, so this module provides it through three helpers backed by
//! `jiff` and the copy of the database built into the binary.

use std::collections::HashMap;
use std::sync::OnceLock;

use jiff::Timestamp;
use jiff::tz::TimeZone;
use jiff::tz::TimeZoneDatabase;
use rquickjs::Ctx;
use rquickjs::Function;
use rquickjs::Object;

use super::value::error_text;
use super::value::throw_string;

const SOURCE: &str = include_str!("intl.js");
const LAZY_SOURCE: &str = include_str!("intl_lazy.js");
const DATA: &str = include_str!("intl_data.json");

/// The IANA database named zones are answered from: the copy built into the binary (jiff-tzdb),
/// as V8 answers from the copy in its own ICU data. Android's copy can be years older: the AOSP 9
/// tzdata in termux-docker still has Brazil's daylight saving time, abolished in 2019, and so do
/// phones that stopped getting updates. The local zone does not come from here (see `intl.js`),
/// so it always agrees with `Date`.
fn database() -> &'static TimeZoneDatabase {
    static DATABASE: OnceLock<TimeZoneDatabase> = OnceLock::new();
    DATABASE.get_or_init(TimeZoneDatabase::bundled)
}

/// The database's spelling of `name` (`america/new_york` -> `America/New_York`), if it is a zone.
fn canonical_zone(name: &str) -> Option<String> {
    static NAMES: OnceLock<HashMap<String, String>> = OnceLock::new();
    let names = NAMES.get_or_init(|| {
        database()
            .available()
            .map(|zone| {
                let name = zone.as_str();
                (name.to_ascii_lowercase(), name.to_string())
            })
            .collect()
    });
    names.get(&name.to_ascii_lowercase()).cloned()
}

/// UTC offset of the zone at `epoch_ms`, in seconds; 0 for anything that is not a known zone or
/// instant (the JavaScript side only passes names it got from `canonical_zone`).
fn zone_offset_seconds(name: &str, epoch_ms: f64) -> i32 {
    if !epoch_ms.is_finite() {
        return 0;
    }
    let Ok(zone) = database().get(name) else {
        return 0;
    };
    let Ok(timestamp) = Timestamp::from_millisecond(epoch_ms as i64) else {
        return 0;
    };
    zone.to_offset(timestamp).seconds()
}

/// The device's IANA zone name (Android: the `persist.sys.timezone` property), when known.
fn system_zone() -> Option<String> {
    TimeZone::system().iana_name().map(str::to_owned)
}

/// Evaluates `intl.js`, which replaces `Intl` and the locale-sensitive methods of `Number`,
/// `BigInt`, `Date`, `String` and `Array` with the real implementation.
fn load_implementation<'js>(ctx: &Ctx<'js>) -> Result<(), String> {
    let fail = |what: &str, error: rquickjs::Error| format!("failed to {what}: {}", error_text(ctx, error));

    let host = Object::new(ctx.clone()).map_err(|error| fail("allocate the Intl host", error))?;
    let zone = Function::new(ctx.clone(), |name: String| canonical_zone(&name))
        .and_then(|function| function.with_name("zone"))
        .map_err(|error| fail("create Intl host.zone", error))?;
    let offset = Function::new(ctx.clone(), |name: String, epoch_ms: f64| {
        zone_offset_seconds(&name, epoch_ms)
    })
    .and_then(|function| function.with_name("offset"))
    .map_err(|error| fail("create Intl host.offset", error))?;
    let local = Function::new(ctx.clone(), system_zone)
        .and_then(|function| function.with_name("local"))
        .map_err(|error| fail("create Intl host.local", error))?;
    for (name, function) in [("zone", zone), ("offset", offset), ("local", local)] {
        host.set(name, function)
            .map_err(|error| fail("populate the Intl host", error))?;
    }

    let factory: Function = ctx
        .eval(SOURCE)
        .map_err(|error| fail("compile the Intl implementation", error))?;
    factory
        .call::<_, ()>((ctx.globals(), host, DATA))
        .map_err(|error| fail("initialize the Intl implementation", error))
}

/// Makes `Intl` and the locale-sensitive built-ins available. The implementation is loaded the
/// first time a script uses one of them (see `intl_lazy.js`), because compiling it for every cell
/// would be wasted on the many scripts that never format a number or a date.
pub(super) fn install_intl<'js>(ctx: &Ctx<'js>) -> Result<(), String> {
    let fail = |what: &str, error: rquickjs::Error| format!("failed to {what}: {}", error_text(ctx, error));
    let load = Function::new(ctx.clone(), |ctx: Ctx<'js>| -> rquickjs::Result<()> {
        load_implementation(&ctx).map_err(|message| throw_string(&ctx, &message))
    })
    .and_then(|function| function.with_name("loadIntl"))
    .map_err(|error| fail("create the Intl loader", error))?;
    let bootstrap: Function = ctx
        .eval(LAZY_SOURCE)
        .map_err(|error| fail("compile the Intl bootstrap", error))?;
    bootstrap
        .call::<_, ()>((ctx.globals(), load))
        .map_err(|error| fail("install the Intl bootstrap", error))
}

#[cfg(test)]
mod tests {
    use rquickjs::Context;
    use rquickjs::Runtime;
    use serde_json::Value;

    use super::*;

    const CASES: &str = include_str!("intl_cases.json");

    /// Runs `body` in a QuickJS context that has `Intl` installed, the way an exec cell has it.
    fn with_intl<R>(body: impl FnOnce(&Ctx<'_>) -> R) -> R {
        let runtime = Runtime::new().expect("runtime");
        let context = Context::full(&runtime).expect("context");
        context.with(|ctx| {
            ctx.globals().remove("Intl").ok();
            install_intl(&ctx).expect("install Intl");
            body(&ctx)
        })
    }

    fn eval_string(ctx: &Ctx<'_>, source: &str) -> String {
        match ctx.eval::<String, _>(source) {
            Ok(text) => text,
            Err(error) => format!("EXCEPTION: {}", error_text(ctx, error)),
        }
    }

    /// Every expression in intl_cases.json (results recorded from a full-ICU engine by
    /// tests/intl/gen-cases.mjs) must evaluate to the same JSON here.
    #[test]
    fn matches_the_reference_engine() {
        let document: Value = serde_json::from_str(CASES).expect("intl_cases.json");
        let prelude = document["prelude"].as_str().expect("prelude");
        let cases = document["cases"].as_array().expect("cases");
        let failures = with_intl(|ctx| {
            ctx.eval::<(), _>(prelude).expect("prelude");
            let mut failures = Vec::new();
            for case in cases {
                let expression = case[0].as_str().expect("expression");
                let expected = case[1].as_str().expect("expected");
                let actual = eval_string(ctx, &format!("__show(() => ({expression}))"));
                if actual != expected {
                    failures.push(format!("{expression}\n    expected {expected}\n    actual   {actual}"));
                }
            }
            failures
        });
        assert!(
            failures.is_empty(),
            "{} of {} Intl cases differ:\n{}",
            failures.len(),
            cases.len(),
            failures.iter().take(25).cloned().collect::<Vec<_>>().join("\n")
        );
    }

    #[test]
    fn named_zones_come_from_the_host() {
        with_intl(|ctx| {
            // America/New_York is UTC-5 in winter and UTC-4 in summer; Asia/Kolkata is +5:30.
            assert_eq!(zone_offset_seconds("America/New_York", 1_735_787_045_000.0), -5 * 3600);
            assert_eq!(zone_offset_seconds("America/New_York", 1_751_643_000_000.0), -4 * 3600);
            assert_eq!(zone_offset_seconds("Asia/Kolkata", 1_735_787_045_000.0), 5 * 3600 + 1800);
            // Brazil has had no daylight saving time since 2019, whatever the system tzdata says.
            assert_eq!(zone_offset_seconds("America/Sao_Paulo", 1_735_787_045_000.0), -3 * 3600);
            assert_eq!(canonical_zone("america/new_york").as_deref(), Some("America/New_York"));
            assert_eq!(canonical_zone("Not/AZone"), None);
            let formatted = eval_string(
                ctx,
                r#"new Date(Date.UTC(2025, 0, 2, 3, 4, 5)).toLocaleString("en-US", { timeZone: "America/New_York", timeZoneName: "short" })"#,
            );
            assert_eq!(formatted, "1/1/2025, 10:04:05 PM EST");
        });
    }

    #[test]
    fn local_time_zone_is_consistent_with_date() {
        with_intl(|ctx| {
            // The system zone is whatever the machine has; formatting must agree with Date.
            let agrees = eval_string(
                ctx,
                r#"(() => {
                  const d = new Date(2025, 5, 15, 13, 45, 30);
                  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", { hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" }).formatToParts(d).map((p) => [p.type, p.value]));
                  return [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second].join(",");
                })()"#,
            );
            assert_eq!(agrees, "2025,6,15,13,45,30");
            let zone = eval_string(ctx, "Intl.DateTimeFormat().resolvedOptions().timeZone");
            eprintln!("system time zone as seen by Intl: {zone}");
            assert!(!zone.is_empty());
        });
    }

    #[test]
    fn installing_is_cheap_and_loading_waits_for_first_use() {
        // Every exec cell pays the install; only scripts that use Intl pay for the load.
        let started = std::time::Instant::now();
        for _ in 0..20 {
            with_intl(|_| ());
        }
        let install = started.elapsed() / 20;
        let started = std::time::Instant::now();
        for _ in 0..10 {
            with_intl(|ctx| eval_string(ctx, "String(typeof Intl.NumberFormat)"));
        }
        let with_use = started.elapsed() / 10;
        eprintln!("Intl per cell: install {install:?}, install + first use {with_use:?}");
        // Laziness itself is asserted by stand_ins_work_before_and_after_loading; this only guards
        // against the install becoming expensive, with room for a loaded CI machine.
        assert!(install < std::time::Duration::from_millis(100), "{install:?}");
    }

    #[test]
    fn stand_ins_work_before_and_after_loading() {
        with_intl(|ctx| {
            // Nothing is loaded until the first use; a method kept from before keeps working.
            let result = eval_string(
                ctx,
                r#"(() => {
                  const kept = Number.prototype.toLocaleString;
                  const before = Object.getOwnPropertyDescriptor(globalThis, "Intl").get !== undefined;
                  const first = (1234.5).toLocaleString();
                  const after = typeof Object.getOwnPropertyDescriptor(globalThis, "Intl").value;
                  return JSON.stringify([before, first, after, kept.call(9876.5), kept.name, kept.length,
                    "b".localeCompare("A"), typeof Intl.DateTimeFormat]);
                })()"#,
            );
            assert_eq!(result, r#"[true,"1,234.5","object","9,876.5","toLocaleString",0,1,"function"]"#);
        });
    }

    #[test]
    fn a_failed_load_reports_an_error_and_can_be_retried() {
        with_intl(|ctx| {
            // Make the implementation fail while it initializes (it needs WeakMap), observe a
            // clean error instead of a recursion, then restore WeakMap and succeed.
            let result = eval_string(
                ctx,
                r#"(() => {
                  const original = WeakMap;
                  globalThis.WeakMap = undefined;
                  let first;
                  try { (1).toLocaleString(); first = "no error"; } catch (e) { first = String(e).includes("Intl") ? "error" : String(e); }
                  globalThis.WeakMap = original;
                  return JSON.stringify([first, (1234.5).toLocaleString(), typeof Intl]);
                })()"#,
            );
            assert_eq!(result, r#"["error","1,234.5","object"]"#);
        });
    }

    /// The script tests/code_mode_script.py sends as the ninth `exec`, and what
    /// tests/check_code_mode.py expects back from it.
    #[test]
    fn model_style_script_gives_the_documented_output() {
        with_intl(|ctx| {
            let result = eval_string(
                ctx,
                r#"(() => {
                  const when = new Date("2025-01-02T03:04:05Z");
                  return JSON.stringify([
                    when.toLocaleString("en-US", {timeZone: "America/New_York", dateStyle: "medium", timeStyle: "short"}),
                    new Intl.NumberFormat("en-US", {style: "currency", currency: "USD"}).format(1234.5),
                    ["b", "a", "C"].sort((x, y) => x.localeCompare(y)).join(","),
                    new Intl.ListFormat("en").format(["a", "b", "c"]),
                    (1234567.891).toLocaleString(),
                    new Intl.DateTimeFormat("en-US", {timeZone: "Asia/Shanghai", hour: "numeric", minute: "2-digit", timeZoneName: "short"}).format(when),
                  ]);
                })()"#,
            );
            assert_eq!(
                result,
                r#"["Jan 1, 2025, 10:04 PM","$1,234.50","a,b,C","a, b, and c","1,234,567.891","11:04 AM GMT+8"]"#
            );
        });
    }
}
