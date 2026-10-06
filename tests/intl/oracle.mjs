// Loads overlay/.../runtime/intl.js into a fresh Node realm (with its own Intl removed) and
// exposes it next to the engine's native Intl, so every expression can be compared against ICU.
import vm from "node:vm";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const sourcePath = path.join(root, "overlay/codex-rs/code-mode-runtime/src/runtime/intl.js");
const dataPath = path.join(root, "overlay/codex-rs/code-mode-runtime/src/runtime/intl_data.json");

// Time zone host backed by the native Intl; in the real runtime this is Rust (jiff).
export const nativeHost = {
  local: () => Intl.DateTimeFormat().resolvedOptions().timeZone,
  zone(name) {
    try { return new Intl.DateTimeFormat("en", { timeZone: name }).resolvedOptions().timeZone; } catch { return undefined; }
  },
  offset(id, ms) {
    const f = new Intl.DateTimeFormat("en-US", { timeZone: id, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" });
    const p = Object.fromEntries(f.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
    const asUtc = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour), Number(p.minute), Number(p.second));
    return Math.round((asUtc - Math.floor(ms / 1000) * 1000) / 1000);
  },
};

export function loadPolyfill(host = nativeHost) {
  const context = vm.createContext({});
  vm.runInContext("delete globalThis.Intl", context);
  const factory = vm.runInContext(fs.readFileSync(sourcePath, "utf8"), context);
  factory(vm.runInContext("globalThis", context), host, fs.readFileSync(dataPath, "utf8"));
  return context;
}
export const evalPolyfill = (context, expression) => vm.runInContext(expression, context);
export const evalNative = (expression) => vm.runInThisContext(expression);
export const show = (value) => {
  try { return JSON.stringify(value, (k, v) => (typeof v === "bigint" ? `${v}n` : v === undefined ? "__undefined__" : typeof v === "number" && !Number.isFinite(v) ? String(v) : v)); }
  catch (error) { return `<${error.message}>`; }
};
export function run(expression, context) {
  const wrap = (fn) => { try { return { ok: show(fn()) }; } catch (error) { return { error: error.constructor.name }; } };
  return [wrap(() => evalNative(expression)), wrap(() => evalPolyfill(context, expression))];
}
