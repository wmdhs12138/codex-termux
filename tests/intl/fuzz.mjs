// Differential test: native ICU vs intl.js over generated inputs. Prints mismatches by group.
import { loadPolyfill, nativeHost } from "./oracle.mjs";
import vm from "node:vm";
const ctx = loadPolyfill();
const P = (src) => vm.runInContext(src, ctx);
const N = (src) => vm.runInThisContext(src);
let total = 0, bad = 0;
const groups = {};
const MAX_SHOW = Number(process.env.SHOW || 6);
function check(group, label, fn) {
  total++;
  const wrap = (side) => { try { return JSON.stringify(fn(side)); } catch (e) { return `ERR:${e.constructor.name}`; } };
  const a = wrap(N), b = wrap(P);
  if (a !== b) { bad++; (groups[group] ||= []).push(`${label}\n     native: ${a}\n     mine:   ${b}`); }
}
const only = process.env.ONLY;
const run = (name, fn) => { if (!only || only === name) fn(); };

const numbers = [0, -0, 1, -1, 0.5, 1.5, 2.5, 1.005, 1.045, 0.1 + 0.2, 123.456, 1234.5678, 999999, 999.9996, 1e6, 12345678, 123456789012, 1e15, 1e21, 1.5e-7, 0.000123, -0.001, 99.995, 0.045, 5e-324, Number.MAX_SAFE_INTEGER, NaN, Infinity, -Infinity, 12, 1000, 10000, 1234, 99999.5, 0.9999, 42, 7, 100, 1e100, 123456.789e3];
const bigs = [0n, 1n, -5n, 12345678901234567890n, 999999999999999999n];
const strs = ["1.005", "-12.50", "0.000", "1e3", "abc", "  7 "];
const digitOpts = [{}, { maximumFractionDigits: 0 }, { minimumFractionDigits: 2 }, { minimumFractionDigits: 1, maximumFractionDigits: 4 }, { maximumSignificantDigits: 3 }, { minimumSignificantDigits: 4 }, { minimumSignificantDigits: 2, maximumSignificantDigits: 5 }, { minimumIntegerDigits: 3 }, { maximumFractionDigits: 2, trailingZeroDisplay: "stripIfInteger", minimumFractionDigits: 2 }];
const styles = [{}, { style: "percent" }, { style: "currency", currency: "USD" }, { style: "currency", currency: "EUR", currencyDisplay: "code" }, { style: "currency", currency: "JPY" }, { style: "currency", currency: "CNY", currencyDisplay: "name" }, { style: "currency", currency: "USD", currencySign: "accounting" }, { style: "currency", currency: "CHF" }, { style: "currency", currency: "BHD", currencyDisplay: "narrowSymbol" }, { style: "unit", unit: "kilometer" }, { style: "unit", unit: "megabyte", unitDisplay: "long" }, { style: "unit", unit: "celsius", unitDisplay: "narrow" }, { style: "unit", unit: "kilometer-per-hour", unitDisplay: "long" }, { style: "unit", unit: "percent" }, { style: "unit", unit: "second", unitDisplay: "long" }, { notation: "compact" }, { notation: "compact", compactDisplay: "long" }, { notation: "scientific" }, { notation: "engineering" }, { useGrouping: false }, { useGrouping: "min2" }, { signDisplay: "always" }, { signDisplay: "exceptZero" }, { signDisplay: "never" }, { signDisplay: "negative" }];
run("number", () => {
  for (const n of numbers) for (const s of styles) for (const d of [{}, ...digitOpts.slice(1)]) {
    const o = { ...s, ...d };
    check("number", `${String(n)} ${JSON.stringify(o)}`, (E) => new (E("Intl.NumberFormat"))("en-US", o).format(n));
  }
  for (const n of bigs) for (const s of styles.slice(0, 6)) check("number-bigint", `${n}n ${JSON.stringify(s)}`, (E) => new (E("Intl.NumberFormat"))("en-US", s).format(n));
  for (const n of strs) check("number-string", n, (E) => new (E("Intl.NumberFormat"))("en-US", { maximumFractionDigits: 2 }).format(n));
  for (const mode of ["ceil", "floor", "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven"])
    for (const n of [2.5, 3.5, -2.5, -3.5, 1.234, -1.234, 1.2351, 0.0004, -0.0004, 9.995, 0.5, 1.5])
      check("rounding", `${n} ${mode}`, (E) => new (E("Intl.NumberFormat"))("en-US", { maximumFractionDigits: n === 0.0004 || n === -0.0004 ? 2 : 0, roundingMode: mode }).format(n));
  for (const n of [1, 1.5, 12, -3]) for (const s of styles.slice(0, 12)) check("number-parts", `${n} ${JSON.stringify(s)}`, (E) => new (E("Intl.NumberFormat"))("en-US", s).formatToParts(n));
  check("number-resolved", "default", (E) => new (E("Intl.NumberFormat"))().resolvedOptions());
  for (const s of styles) check("number-resolved", JSON.stringify(s), (E) => new (E("Intl.NumberFormat"))("en-US", s).resolvedOptions());
});

const dates = ["2025-01-02T03:04:05.678Z", "2025-07-04T15:30:00Z", "2024-02-29T00:00:00Z", "2025-12-31T23:59:59.999Z", "2025-03-09T12:00:00Z", "2025-11-02T06:30:00Z", "1999-12-31T12:00:00Z", "1970-01-01T00:00:00Z", "2100-06-15T08:09:10Z", "0099-05-05T12:00:00Z", "-000100-01-01T00:00:00Z"];
const dateOpts = [{}, { dateStyle: "full" }, { dateStyle: "long" }, { dateStyle: "medium" }, { dateStyle: "short" }, { timeStyle: "full" }, { timeStyle: "long" }, { timeStyle: "medium" }, { timeStyle: "short" }];
for (const ds of ["full", "long", "medium", "short"]) for (const ts of ["full", "long", "medium", "short"]) dateOpts.push({ dateStyle: ds, timeStyle: ts });
const fieldSets = [
  { year: "numeric" }, { year: "2-digit" }, { month: "numeric" }, { month: "2-digit" }, { month: "long" }, { month: "short" }, { month: "narrow" }, { day: "numeric" }, { day: "2-digit" }, { weekday: "long" }, { weekday: "short" }, { weekday: "narrow" },
  { year: "numeric", month: "numeric", day: "numeric" }, { year: "numeric", month: "2-digit", day: "2-digit" }, { year: "2-digit", month: "2-digit", day: "2-digit" },
  { year: "numeric", month: "long", day: "numeric" }, { year: "numeric", month: "short", day: "numeric" }, { year: "numeric", month: "long" }, { year: "numeric", month: "short" }, { year: "numeric", month: "numeric" },
  { month: "long", day: "numeric" }, { month: "short", day: "numeric" }, { month: "numeric", day: "numeric" },
  { weekday: "long", year: "numeric", month: "long", day: "numeric" }, { weekday: "short", year: "numeric", month: "short", day: "numeric" }, { weekday: "short", month: "numeric", day: "numeric" }, { weekday: "long", month: "long", day: "numeric" }, { weekday: "short", year: "numeric", month: "numeric", day: "numeric" },
  { weekday: "long", day: "numeric" },
  { era: "short", year: "numeric" }, { era: "long", year: "numeric", month: "long", day: "numeric" }, { era: "narrow", year: "numeric" }, { era: "short", year: "numeric", month: "numeric", day: "numeric" },
  { hour: "numeric" }, { hour: "2-digit" }, { hour: "numeric", minute: "numeric" }, { hour: "2-digit", minute: "2-digit" }, { hour: "numeric", minute: "2-digit", second: "2-digit" }, { hour: "numeric", minute: "numeric", second: "numeric" },
  { minute: "numeric" }, { minute: "2-digit" }, { second: "numeric" }, { minute: "numeric", second: "numeric" }, { minute: "2-digit", second: "2-digit" },
  { hour: "numeric", minute: "numeric", second: "numeric", fractionalSecondDigits: 3 }, { hour: "numeric", minute: "numeric", second: "numeric", fractionalSecondDigits: 1 }, { second: "numeric", fractionalSecondDigits: 2 }, { fractionalSecondDigits: 2 },
  { hour: "numeric", minute: "numeric", hour12: false }, { hour: "numeric", hour12: false }, { hour: "numeric", minute: "numeric", second: "numeric", hourCycle: "h23" }, { hour: "numeric", minute: "numeric", hourCycle: "h24" }, { hour: "numeric", minute: "numeric", hourCycle: "h11" }, { hour: "numeric", minute: "numeric", hourCycle: "h12" }, { hour: "2-digit", minute: "2-digit", hour12: true },
  { year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric" }, { year: "numeric", month: "long", day: "numeric", hour: "numeric", minute: "2-digit" }, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }, { weekday: "long", year: "numeric", month: "long", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" }, { year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric", hour12: false },
  { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false }, { weekday: "short", hour: "numeric", minute: "numeric" },
  { hour: "numeric", timeZoneName: "short" }, { hour: "numeric", timeZoneName: "long" }, { hour: "numeric", timeZoneName: "shortOffset" }, { hour: "numeric", timeZoneName: "longOffset" }, { hour: "numeric", timeZoneName: "shortGeneric" }, { hour: "numeric", timeZoneName: "longGeneric" }, { timeZoneName: "short" }, { year: "numeric", month: "numeric", day: "numeric", timeZoneName: "short" }, { year: "numeric", month: "long", day: "numeric", hour: "numeric", minute: "numeric", timeZoneName: "short" },
];
const zones = ["UTC", "America/New_York", "Asia/Shanghai", "Europe/London", "Asia/Kolkata", "Australia/Sydney", "America/Los_Angeles", "+05:30", "-08:00", "Pacific/Honolulu", "America/Phoenix", "Etc/GMT+5", "Asia/Tokyo", "America/Sao_Paulo"];
run("date", () => {
  for (const d of dates) for (const o of dateOpts) check("date-style", `${d} ${JSON.stringify(o)}`, (E) => new (E("Intl.DateTimeFormat"))("en-US", { ...o, timeZone: "UTC" }).format(new (E("Date"))(d)));
  for (const d of dates.slice(0, 5)) for (const o of fieldSets) check("date-fields", `${d} ${JSON.stringify(o)}`, (E) => new (E("Intl.DateTimeFormat"))("en-US", { ...o, timeZone: "UTC" }).format(new (E("Date"))(d)));
  for (const z of zones) for (const d of dates.slice(0, 6)) for (const o of [{ dateStyle: "full", timeStyle: "full" }, { dateStyle: "short", timeStyle: "long" }, { hour: "numeric", minute: "numeric", timeZoneName: "short" }, { hour: "numeric", timeZoneName: "long" }, { hour: "numeric", timeZoneName: "shortOffset" }, { hour: "numeric", timeZoneName: "longGeneric" }, { year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric", hour12: false }])
    check("date-zones", `${z} ${d} ${JSON.stringify(o)}`, (E) => new (E("Intl.DateTimeFormat"))("en-US", { ...o, timeZone: z }).format(new (E("Date"))(d)));
  for (const d of dates.slice(0, 4)) for (const o of fieldSets.slice(0, 40)) check("date-parts", `${d} ${JSON.stringify(o)}`, (E) => new (E("Intl.DateTimeFormat"))("en-US", { ...o, timeZone: "UTC" }).formatToParts(new (E("Date"))(d)));
  for (const o of [...fieldSets.slice(0, 60), ...dateOpts]) check("date-resolved", JSON.stringify(o), (E) => new (E("Intl.DateTimeFormat"))("en-US", { ...o, timeZone: "UTC" }).resolvedOptions());
  for (const z of zones) check("date-resolved-zone", z, (E) => new (E("Intl.DateTimeFormat"))("en-US", { timeZone: z }).resolvedOptions().timeZone);
  for (const d of dates.slice(0, 5)) {
    check("toLocale", d + " string", (E) => new (E("Date"))(d).toLocaleString("en-US", { timeZone: "UTC" }));
    check("toLocale", d + " date", (E) => new (E("Date"))(d).toLocaleDateString("en-US", { timeZone: "UTC" }));
    check("toLocale", d + " time", (E) => new (E("Date"))(d).toLocaleTimeString("en-US", { timeZone: "UTC" }));
    check("toLocale", d + " date+hour", (E) => new (E("Date"))(d).toLocaleDateString("en-US", { timeZone: "UTC", hour: "numeric" }));
    check("toLocale", d + " time+month", (E) => new (E("Date"))(d).toLocaleTimeString("en-US", { timeZone: "UTC", month: "long" }));
    check("toLocale", d + " string long", (E) => new (E("Date"))(d).toLocaleString("en-US", { timeZone: "UTC", dateStyle: "medium", timeStyle: "short" }));
    check("toLocale", d + " no locale", (E) => new (E("Date"))(d).toLocaleString(undefined, { timeZone: "UTC" }));
  }
  check("toLocale", "invalid", (E) => new (E("Date"))(NaN).toLocaleString());
  check("date-errors", "NaN format", (E) => new (E("Intl.DateTimeFormat"))("en-US").format(NaN));
  check("date-errors", "dateStyle+field", (E) => new (E("Intl.DateTimeFormat"))("en-US", { dateStyle: "short", year: "numeric" }));
  check("date-errors", "bad zone", (E) => new (E("Intl.DateTimeFormat"))("en-US", { timeZone: "Not/AZone" }));
  check("date-errors", "bad option", (E) => new (E("Intl.DateTimeFormat"))("en-US", { month: "huge" }));
  check("date-errors", "toLocaleDateString timeStyle", (E) => new (E("Date"))(0).toLocaleDateString("en-US", { timeStyle: "short" }));
});

const words = ["a", "A", "b", "B", "ab", "aB", "Ab", "AB", "á", "Á", "ä", "e", "é", "E", "z", "Z", "10", "9", "2", "a1", "a10", "a2", "A3", "_x", "-x", " x", "x", "ß", "ss", "æ", "ae", "ø", "o", "ñ", "n", "ç", "c", "", "a b", "ab ", "a-b", "a_b", "a.b", "résumé", "resume", "Résumé", "naïve", "naive", "I", "i", "İ", "ı", "中", "文", "あ", "한", "я", "α", "$", "~", "#", "1", "01", "001", "x10", "X2", "ǅ", "ﬁ", "fi"];
run("collator", () => {
  const optSets = [{}, { numeric: true }, { sensitivity: "base" }, { sensitivity: "accent" }, { sensitivity: "case" }, { caseFirst: "upper" }, { ignorePunctuation: true }, { numeric: true, sensitivity: "base" }];
  for (const o of optSets) {
    check("collator-sort", JSON.stringify(o), (E) => [...words].sort(new (E("Intl.Collator"))("en", o).compare));
    let pairs = 0;
    for (const x of words) for (const y of words) { if ((pairs++ % 3) !== 0) continue; check("collator-pair", `${JSON.stringify(x)} vs ${JSON.stringify(y)} ${JSON.stringify(o)}`, (E) => Math.sign(new (E("Intl.Collator"))("en", o).compare(x, y))); }
  }
  check("localeCompare", "sort default", (E) => [...words].sort((a, b) => a.localeCompare(b)));
  check("localeCompare", "mixed case", (E) => ["banana", "Apple", "cherry", "apple", "Banana"].sort((a, b) => a.localeCompare(b)));
  check("localeCompare", "numeric opt", (E) => ["file10", "file2", "File1"].sort((a, b) => a.localeCompare(b, undefined, { numeric: true })));
  check("localeCompare", "base", (E) => "a".localeCompare("A", undefined, { sensitivity: "base" }));
  check("collator-resolved", "x", (E) => new (E("Intl.Collator"))("en", { numeric: true }).resolvedOptions());
});

run("plural", () => {
  const nums = [0, 1, 2, 3, 4, 5, 11, 12, 13, 21, 22, 23, 101, 111, 1.5, 0.5, 1.0, -1, 1e6, NaN];
  for (const type of ["cardinal", "ordinal"]) for (const n of nums) {
    check("plural", `${type} ${n}`, (E) => new (E("Intl.PluralRules"))("en", { type }).select(n));
    check("plural", `${type} ${n} minFrac1`, (E) => new (E("Intl.PluralRules"))("en", { type, minimumFractionDigits: 1 }).select(n));
  }
  check("plural-resolved", "c", (E) => new (E("Intl.PluralRules"))("en").resolvedOptions());
  check("plural-resolved", "o", (E) => new (E("Intl.PluralRules"))("en", { type: "ordinal" }).resolvedOptions());
});
run("rtf", () => {
  for (const style of ["long", "short", "narrow"]) for (const numeric of ["always", "auto"]) for (const unit of ["second", "minute", "hour", "day", "week", "month", "quarter", "year", "days", "years"]) for (const v of [-1, 0, 1, 2, -2, 5, -5, 1.5, -1.5, 1000, -0, 100000]) {
    check("rtf", `${style} ${numeric} ${v} ${unit}`, (E) => new (E("Intl.RelativeTimeFormat"))("en", { style, numeric }).format(v, unit));
  }
  for (const v of [-2, 1, 1234.5]) check("rtf-parts", String(v), (E) => new (E("Intl.RelativeTimeFormat"))("en").formatToParts(v, "day"));
});
run("list", () => {
  for (const type of ["conjunction", "disjunction", "unit"]) for (const style of ["long", "short", "narrow"]) for (const items of [[], ["a"], ["a", "b"], ["a", "b", "c"], ["a", "b", "c", "d"]]) {
    check("list", `${type} ${style} ${items.length}`, (E) => new (E("Intl.ListFormat"))("en", { type, style }).format(items));
    check("list-parts", `${type} ${style} ${items.length}`, (E) => new (E("Intl.ListFormat"))("en", { type, style }).formatToParts(items));
  }
});
run("segmenter", () => {
  const texts = ["Hello, world!", "áb", "👨‍👩‍👧‍👦 family", "🇨🇳🇺🇸", "👍🏽 ok", "é̂x", "line\r\nbreak", "你好，世界", "I don't know. It's 3.14 or 2,000, e.g. this? Yes!", "x  y", "", "한국어", "🏴󠁧󠁢󠁥󠁮󠁧󠁿 flag", "mixed 中文 text 123"];
  for (const g of ["grapheme", "word", "sentence"]) for (const t of texts) check("segmenter-" + g, JSON.stringify(t), (E) => [...new (E("Intl.Segmenter"))("en", { granularity: g }).segment(t)].map((s) => [s.segment, s.index, s.isWordLike]));
});
run("misc", () => {
  for (const l of ["en", "en-US", "EN-us", "zh-CN", "de", "en-GB", "und", "x", "en_US", "", "en-u-ca-gregory", "zh-Hans-CN", "sr-Latn"]) {
    check("locales", `canonical ${l}`, (E) => E("Intl").getCanonicalLocales(l));
  }
  check("locales", "supportedLocalesOf", (E) => E("Intl").NumberFormat.supportedLocalesOf(["en-US", "zh-CN", "en"]));
  check("locale-obj", "Locale", (E) => { const l = new (E("Intl.Locale"))("en-Latn-US-u-hc-h23"); return [l.language, l.script, l.region, l.baseName, String(l)]; });
  check("array", "toLocaleString", (E) => [1234.5, new (E("Date"))(0), null, "x"].toLocaleString("en-US", { timeZone: "UTC" }));
  check("bigint", "toLocaleString", (E) => 12345678901234567890n.toLocaleString());
  check("tag", "toStringTag", (E) => [Object.prototype.toString.call(E("Intl")), Object.prototype.toString.call(new (E("Intl.NumberFormat"))())]);
  check("keys", "Intl keys", (E) => Object.getOwnPropertyNames(E("Intl")).filter((k) => !["DisplayNames", "DurationFormat", "supportedValuesOf"].includes(k)).sort());
  check("fmt", "format bound", (E) => { const { format } = new (E("Intl.NumberFormat"))("en-US"); return format(1234.5); });
  check("fmt", "NumberFormat without new", (E) => E("Intl.NumberFormat")("en-US").format(1));
  check("fmt", "PluralRules without new", (E) => E("Intl.PluralRules")("en"));
});
console.log(`\n${total - bad}/${total} match`);
for (const [group, items] of Object.entries(groups)) {
  console.log(`\n== ${group}: ${items.length} mismatch(es)`);
  for (const item of items.slice(0, MAX_SHOW)) console.log("   " + item);
}
process.exit(bad ? 1 : 0);
