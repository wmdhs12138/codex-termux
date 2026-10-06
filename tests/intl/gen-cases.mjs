// Writes overlay/.../runtime/intl_cases.json: expressions with the result a full-ICU engine gives
// for them. The Rust tests (runtime/intl.rs) evaluate the same expressions inside QuickJS.
// Usage: node gen-cases.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, "../../overlay/codex-rs/code-mode-runtime/src/runtime/intl_cases.json");

const prelude = `globalThis.__show = (fn) => {
  try {
    return JSON.stringify(fn(), (k, v) => (typeof v === "bigint" ? v + "n" : v === undefined ? "__undefined__" : typeof v === "number" && !Number.isFinite(v) ? String(v) : v));
  } catch (e) { return "ERR:" + e.constructor.name; }
};`;

const cases = [];
const add = (expr) => cases.push(expr);
const j = JSON.stringify;

// ---- numbers
const numbers = [0, -0, 1, -1, 0.5, 1.5, 2.5, 1.005, 0.1 + 0.2, 1234.5678, 999999, 999.9996, 12345678, 1e15, 1e21, 1.5e-7, -0.001, 99.995, NaN, Infinity, -Infinity, 1000, 42];
const numberOptions = [
  {}, { maximumFractionDigits: 0 }, { minimumFractionDigits: 2 }, { maximumSignificantDigits: 3 }, { minimumIntegerDigits: 3 },
  { style: "percent" }, { style: "currency", currency: "USD" }, { style: "currency", currency: "EUR", currencyDisplay: "code" },
  { style: "currency", currency: "JPY" }, { style: "currency", currency: "CNY", currencyDisplay: "name" }, { style: "currency", currency: "USD", currencySign: "accounting" },
  { style: "currency", currency: "CHF" }, { style: "unit", unit: "kilometer" }, { style: "unit", unit: "megabyte", unitDisplay: "long" },
  { style: "unit", unit: "celsius", unitDisplay: "narrow" }, { style: "unit", unit: "kilometer-per-hour", unitDisplay: "long" },
  { notation: "compact" }, { notation: "compact", compactDisplay: "long" }, { notation: "scientific" }, { notation: "engineering" },
  { useGrouping: false }, { useGrouping: "min2" }, { signDisplay: "always" }, { signDisplay: "exceptZero" }, { signDisplay: "never" },
];
for (const n of numbers) for (const o of numberOptions) add(`new Intl.NumberFormat("en-US", ${j(o)}).format(${Object.is(n, -0) ? "-0" : n})`);
for (const n of [1234567.891, -42.5, 0, 12345678901234567890n]) {
  add(`(${typeof n === "bigint" ? n + "n" : n}).toLocaleString()`);
  add(`(${typeof n === "bigint" ? n + "n" : n}).toLocaleString("en-US", { maximumFractionDigits: 1 })`);
}
add(`new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).formatToParts(-1234.5)`);
add(`new Intl.NumberFormat("en-US", { notation: "compact" }).formatToParts(1234567)`);
add(`new Intl.NumberFormat("en-US", { style: "unit", unit: "kilometer" }).formatToParts(12.5)`);
add(`new Intl.NumberFormat("en-US", { notation: "scientific" }).formatToParts(12345)`);
add(`new Intl.NumberFormat("en-US", { style: "currency", currency: "EUR" }).resolvedOptions()`);
add(`new Intl.NumberFormat().resolvedOptions()`);
for (const mode of ["ceil", "floor", "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven"])
  for (const n of [2.5, -2.5, 1.234, 0.5]) add(`new Intl.NumberFormat("en-US", { maximumFractionDigits: 0, roundingMode: "${mode}" }).format(${n})`);
add(`new Intl.NumberFormat("en-US", { style: "currency" })`);
add(`new Intl.NumberFormat("en-US", { style: "unit", unit: "parsec" })`);
add(`new Intl.NumberFormat("en-US", { minimumFractionDigits: 5, maximumFractionDigits: 2 })`);

// ---- dates
const dates = ["2025-01-02T03:04:05.678Z", "2025-07-04T15:30:00Z", "2024-02-29T00:00:00Z", "2025-12-31T23:59:59.999Z", "1970-01-01T00:00:00Z", "0099-05-05T12:00:00Z"];
const dateOptions = [{}, { dateStyle: "full" }, { dateStyle: "long" }, { dateStyle: "medium" }, { dateStyle: "short" }, { timeStyle: "full" }, { timeStyle: "short" },
  { dateStyle: "full", timeStyle: "full" }, { dateStyle: "long", timeStyle: "short" }, { dateStyle: "medium", timeStyle: "medium" }, { dateStyle: "short", timeStyle: "short" },
  { year: "numeric", month: "long", day: "numeric" }, { year: "numeric", month: "short", day: "numeric" }, { year: "2-digit", month: "2-digit", day: "2-digit" },
  { month: "long" }, { weekday: "long" }, { weekday: "short", month: "short", day: "numeric" }, { weekday: "long", year: "numeric", month: "long", day: "numeric" },
  { hour: "numeric" }, { hour: "numeric", minute: "numeric" }, { hour: "2-digit", minute: "2-digit", second: "2-digit" }, { hour: "numeric", minute: "numeric", hour12: false },
  { hour: "numeric", minute: "numeric", hourCycle: "h23" }, { hour: "numeric", minute: "numeric", hourCycle: "h11" }, { hour: "numeric", minute: "numeric", second: "numeric", fractionalSecondDigits: 3 },
  { year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric" }, { year: "numeric", month: "long", day: "numeric", hour: "numeric", minute: "2-digit" },
  { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }, { era: "short", year: "numeric" }, { minute: "numeric", second: "numeric" },
  { hour: "numeric", timeZoneName: "short" }, { hour: "numeric", timeZoneName: "long" }, { hour: "numeric", timeZoneName: "shortOffset" }, { timeZoneName: "short" }];
for (const d of dates) for (const o of dateOptions) add(`new Intl.DateTimeFormat("en-US", ${j({ ...o, timeZone: "UTC" })}).format(new Date("${d}"))`);
const zones = ["America/New_York", "Asia/Shanghai", "Europe/London", "Asia/Kolkata", "Australia/Sydney", "America/Los_Angeles", "+05:30", "-08:00", "Pacific/Honolulu", "Etc/GMT+5", "Asia/Tokyo", "Europe/Berlin", "America/Sao_Paulo", "america/chicago"];
for (const z of zones) for (const d of dates.slice(0, 4)) for (const o of [{ dateStyle: "full", timeStyle: "full" }, { dateStyle: "short", timeStyle: "long" }, { hour: "numeric", minute: "numeric", timeZoneName: "short" }, { year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric", hour12: false }])
  add(`new Intl.DateTimeFormat("en-US", ${j({ ...o, timeZone: z })}).format(new Date("${d}"))`);
for (const d of dates.slice(0, 3)) {
  add(`new Date("${d}").toLocaleString("en-US", { timeZone: "UTC" })`);
  add(`new Date("${d}").toLocaleDateString("en-US", { timeZone: "UTC" })`);
  add(`new Date("${d}").toLocaleTimeString("en-US", { timeZone: "UTC" })`);
  add(`new Date("${d}").toLocaleString("en-US", { timeZone: "Asia/Shanghai", dateStyle: "medium", timeStyle: "short" })`);
  add(`new Intl.DateTimeFormat("en-US", { timeZone: "UTC", year: "numeric", month: "long", day: "numeric", hour: "numeric" }).formatToParts(new Date("${d}"))`);
}
add(`new Intl.DateTimeFormat("en-US", { timeZone: "UTC", hour: "numeric", minute: "numeric" }).resolvedOptions()`);
add(`new Intl.DateTimeFormat("en-US", { timeZone: "america/new_york" }).resolvedOptions().timeZone`);
add(`new Intl.DateTimeFormat("en-US", { timeZone: "Etc/UTC" }).resolvedOptions().timeZone`);
add(`new Intl.DateTimeFormat("en-US", { timeZone: "+05:30" }).resolvedOptions().timeZone`);
add(`new Date(NaN).toLocaleString()`);
add(`new Intl.DateTimeFormat("en-US").format(NaN)`);
add(`new Intl.DateTimeFormat("en-US", { timeZone: "Not/AZone" })`);
add(`new Intl.DateTimeFormat("en-US", { dateStyle: "short", year: "numeric" })`);
add(`new Date(0).toLocaleDateString("en-US", { timeStyle: "short" })`);
// Local time zone: build the instant from local components so the result does not depend on it.
add(`new Date(2025, 0, 2, 3, 4, 5).toLocaleString("en-US")`);
add(`new Date(2025, 6, 4, 15, 30, 0).toLocaleDateString("en-US", { dateStyle: "long" })`);
add(`new Date(2025, 6, 4, 15, 30, 0).toLocaleTimeString("en-US", { timeStyle: "short" })`);
add(`new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "numeric" }).format(new Date(2025, 0, 2, 23, 5))`);

// ---- collation
add(`["b", "a", "C", "A", "B", "c", "ä", "z", "Z", "10", "9", "_x", "-x", " x"].sort((a, b) => a.localeCompare(b))`);
add(`["banana", "Apple", "cherry", "apple", "Banana"].sort((a, b) => a.localeCompare(b))`);
add(`["file10", "file2", "File1"].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))`);
add(`["résumé", "resume", "Resume", "résume"].sort(new Intl.Collator("en").compare)`);
add(`["ß", "ss", "æ", "ae", "ø", "o", "ñ", "n", "ç", "c"].sort(new Intl.Collator("en").compare)`);
add(`["z", "a", "中", "あ", "я", "α", "한"].sort(new Intl.Collator("en").compare)`);
add(`"a".localeCompare("A", undefined, { sensitivity: "base" })`);
add(`"a".localeCompare("á", undefined, { sensitivity: "base" })`);
add(`"a".localeCompare("á", undefined, { sensitivity: "accent" })`);
add(`"a".localeCompare("b")`);
add(`"b".localeCompare("a")`);
add(`"a".localeCompare("a")`);
add(`["a", "A"].sort(new Intl.Collator("en", { caseFirst: "upper" }).compare)`);
add(`new Intl.Collator("en", { ignorePunctuation: true }).compare("a-b", "ab")`);
add(`new Intl.Collator("en", { numeric: true }).resolvedOptions()`);

// ---- plural, relative time, lists, segmentation, locales
for (const type of ["cardinal", "ordinal"]) for (const n of [0, 1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 1.5]) add(`new Intl.PluralRules("en", { type: "${type}" }).select(${n})`);
for (const style of ["long", "short", "narrow"]) for (const numeric of ["always", "auto"]) for (const unit of ["second", "minute", "hour", "day", "week", "month", "quarter", "year"]) for (const v of [-1, 0, 1, 2, -3, 1.5, 1000])
  add(`new Intl.RelativeTimeFormat("en", { style: "${style}", numeric: "${numeric}" }).format(${v}, "${unit}")`);
add(`new Intl.RelativeTimeFormat("en").formatToParts(-2, "day")`);
for (const type of ["conjunction", "disjunction", "unit"]) for (const style of ["long", "short", "narrow"]) for (const items of [[], ["a"], ["a", "b"], ["a", "b", "c"], ["a", "b", "c", "d"]])
  add(`new Intl.ListFormat("en", { type: "${type}", style: "${style}" }).format(${j(items)})`);
add(`new Intl.ListFormat("en").formatToParts(["x", "y", "z"])`);
for (const g of ["grapheme", "word", "sentence"]) for (const t of ["Hello, world!", "áb", "👨‍👩‍👧‍👦 family", "🇨🇳🇺🇸", "👍🏽 ok", "line\r\nbreak", "I don't know. It's 3.14 or 2,000, e.g. this? Yes!", "x  y", "mixed text 123"])
  add(`[...new Intl.Segmenter("en", { granularity: "${g}" }).segment(${j(t)})].map((s) => [s.segment, s.index, s.isWordLike])`);
add(`[...new Intl.Segmenter().segment("👨‍👩‍👧‍👦!")].length`);
add(`new Intl.Segmenter("en", { granularity: "word" }).segment("hello world").containing(7)`);
for (const l of ["en", "en-US", "EN-us"]) add(`new Intl.NumberFormat(${j(l)}).resolvedOptions().locale`);
for (const l of ["en", "en-US", "EN-us", "zh-Hans-cn", "x", "en_US", "", "en-u-ca-gregory"]) add(`Intl.getCanonicalLocales(${j(l)})`);
add(`Intl.NumberFormat.supportedLocalesOf(["en-US", "en"])`);
add(`(() => { const l = new Intl.Locale("en-Latn-US-u-hc-h23"); return [l.language, l.script, l.region, l.baseName, String(l)]; })()`);
add(`[1234.5, new Date(0), null, "x"].toLocaleString("en-US", { timeZone: "UTC" })`);
add(`[Object.prototype.toString.call(Intl), Object.prototype.toString.call(new Intl.NumberFormat())]`);
add(`(() => { const { format } = new Intl.NumberFormat("en-US"); return format(1234.5); })()`);
add(`Intl.NumberFormat("en-US").format(1)`);
add(`Object.keys(Intl)`);
// Deliberate differences from V8 + ICU: only English has data, so every other locale resolves to
// en-US (the spec's fallback), and the APIs that need real locale data are left undefined.
const deviations = [
  [`new Intl.NumberFormat("de").resolvedOptions().locale`, '"en-US"'],
  [`new Intl.DateTimeFormat("zh-CN").resolvedOptions().locale`, '"en-US"'],
  [`new Intl.NumberFormat("de-DE").format(1234.5)`, '"1,234.5"'],
  [`Intl.NumberFormat.supportedLocalesOf(["en-US", "de", "zh-CN", "en"])`, '["en-US","en"]'],
  [`typeof Intl.DisplayNames`, '"undefined"'],
  [`typeof Intl.supportedValuesOf`, '"undefined"'],
];

const wrap = (expr) => `__show(() => (${expr}))`;
// eslint-disable-next-line no-eval
(0, eval)(prelude);
const rows = [...cases.map((expr) => [expr, (0, eval)(wrap(expr))]), ...deviations];
fs.writeFileSync(out, JSON.stringify({ prelude, cases: rows }) + "\n");
console.log(`${rows.length} cases -> ${path.relative(process.cwd(), out)} (${fs.statSync(out).size} bytes)`);
