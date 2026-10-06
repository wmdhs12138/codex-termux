// Dumps the locale data tables used by overlay/.../runtime/intl.js from a full-ICU engine
// (en-US only). Usage: node gen-data.mjs > data.json
import fs from "node:fs";
import { nativeHost } from "./oracle.mjs";
const L = "en-US";
const out = {};

// Currencies: symbol, narrow symbol, digits, display names (one/other) for the common ones.
const currencies = Intl.supportedValuesOf("currency");
const sym = {}, narrow = {}, digits = {}, names = {};
const nameFor = (c, n) => new Intl.NumberFormat(L, { style: "currency", currency: c, currencyDisplay: "name", minimumFractionDigits: 0, maximumFractionDigits: 0 })
  .formatToParts(n).find((p) => p.type === "currency").value;
for (const c of currencies) {
  const opt = (d) => new Intl.NumberFormat(L, { style: "currency", currency: c, currencyDisplay: d });
  const s = opt("symbol").formatToParts(1).find((p) => p.type === "currency").value;
  const n = opt("narrowSymbol").formatToParts(1).find((p) => p.type === "currency").value;
  if (s !== c) sym[c] = s;
  if (n !== c) narrow[c] = n;
  const d = opt("symbol").resolvedOptions().maximumFractionDigits;
  if (d !== 2) digits[c] = d;
  names[c] = [nameFor(c, 1), nameFor(c, 2)];
}
out.currencySymbol = sym; out.currencyNarrow = narrow; out.currencyDigits = digits;
out.currencyName = names;

// Units: "{0}" templates for [one, other] in short/narrow/long.
const units = Intl.supportedValuesOf("unit");
const tpl = (u, display) => [1, 2].map((n) => {
  const f = new Intl.NumberFormat(L, { style: "unit", unit: u, unitDisplay: display });
  return f.formatToParts(n).map((p) => (p.type === "integer" ? "{0}" : p.value)).join("");
});
out.units = {};
for (const u of units) out.units[u] = { short: tpl(u, "short"), narrow: tpl(u, "narrow"), long: tpl(u, "long") };
for (const u of ["kilometer-per-hour", "mile-per-hour", "meter-per-second", "mile-per-gallon",
  "liter-per-kilometer", "kilometer-per-liter", "byte-per-second", "kilobyte-per-second",
  "megabyte-per-second", "gigabyte-per-second", "kilobit-per-second", "megabit-per-second",
  "gigabit-per-second", "mile-per-gallon", "gram-per-liter", "meter-per-second-squared"]) {
  try { out.units[u] = { short: tpl(u, "short"), narrow: tpl(u, "narrow"), long: tpl(u, "long") }; } catch {}
}

// Relative time.
const rtfUnits = ["second", "minute", "hour", "day", "week", "month", "quarter", "year"];
out.rtf = {};
for (const style of ["long", "short", "narrow"]) {
  out.rtf[style] = {};
  for (const u of rtfUnits) {
    const always = new Intl.RelativeTimeFormat(L, { style, numeric: "always" });
    const auto = new Intl.RelativeTimeFormat(L, { style, numeric: "auto" });
    const t = (f, v) => f.formatToParts(v, u).map((p) => (p.type === "integer" ? "{0}" : p.value)).join("");
    out.rtf[style][u] = {
      future: [t(always, 1), t(always, 2)], past: [t(always, -1), t(always, -2)],
      auto: { "-1": auto.format(-1, u), 0: auto.format(0, u), 1: auto.format(1, u) },
    };
  }
}

// Lists.
out.list = {};
for (const type of ["conjunction", "disjunction", "unit"]) {
  out.list[type] = {};
  for (const style of ["long", "short", "narrow"]) {
    const f = new Intl.ListFormat(L, { type, style });
    const p = f.formatToParts(["X", "Y", "Z"]).filter((q) => q.type === "literal").map((q) => q.value);
    const two = f.formatToParts(["X", "Y"]).filter((q) => q.type === "literal").map((q) => q.value);
    out.list[type][style] = { two: two[0], mid: p[0], end: p[1] };
  }
}
// Time zone names. en-US shows real abbreviations only for a few zones (US & neighbours) and
// "GMT+8" for the rest, but spells out long names ("China Standard Time") for most zones.
// Each entry is [shortStd, shortDst, longStd, longDst, shortGeneric, longGeneric] with "" where
// the engine falls back to a GMT offset. Zones are mapped to an entry by index. "Std" and "Dst"
// are decided by offset, so southern-hemisphere zones (DST in January) come out right.
{
  const jan = new Date("2025-01-15T12:00:00Z"), jul = new Date("2025-07-15T12:00:00Z");
  const name = (z, d, style) => {
    const v = new Intl.DateTimeFormat(L, { timeZone: z, timeZoneName: style })
      .formatToParts(d).find((p) => p.type === "timeZoneName").value;
    return /^GMT[+-]/.test(v) ? "" : v;
  };
  const sets = [], ids = {};
  // tznames.txt: every name in the IANA database that the Rust side (jiff) can be asked for,
  // aliases included ("Asia/Kolkata", which ICU spells "Asia/Calcutta").
  const zoneIds = fs.readFileSync(new URL("./tznames.txt", import.meta.url), "utf8").split("\n").filter(Boolean);
  for (const z of new Set([...Intl.supportedValuesOf("timeZone"), ...zoneIds])) {
    try { new Intl.DateTimeFormat(L, { timeZone: z }); } catch { continue; }
    const [std, dst] = nativeHost.offset(z, jan.getTime()) <= nativeHost.offset(z, jul.getTime()) ? [jan, jul] : [jul, jan];
    const tuple = [name(z, std, "short"), name(z, dst, "short"), name(z, std, "long"), name(z, dst, "long"),
      name(z, std, "shortGeneric"), name(z, std, "longGeneric")];
    if (tuple.every((n) => n === "")) continue;
    const key = JSON.stringify(tuple);
    let i = sets.findIndex((t) => JSON.stringify(t) === key);
    if (i < 0) { sets.push(tuple); i = sets.length - 1; }
    ids[z] = i;
  }
  out.tzNames = { sets, ids };
}
console.log(JSON.stringify(out));
