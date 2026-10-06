// A small ECMA-402 (Intl) implementation for QuickJS, which ships without ICU.
//
// Evaluated once per exec cell as `(function (global, host, dataJson) { ... })` and called with
// the global object, the Rust time zone helpers and the generated data tables
// (tests/intl/gen-data.mjs). Nothing here is visible to scripts except what it installs.
//
// Scope, compared with V8 + ICU:
//   * Only the en-US locale has data. Any requested locale resolves to "en-US", which is the
//     fallback the specification prescribes for unsupported locales; resolvedOptions().locale and
//     supportedLocalesOf() say so.
//   * Time zones come from the host (full IANA database); "UTC", fixed offsets and the system
//     zone work without it. Long/short zone names exist for the US zones, everything else prints
//     as GMT+8 / GMT+05:30 like en-US does.
//   * Not implemented (left undefined so scripts can feature-detect): Intl.DisplayNames,
//     Intl.DurationFormat, Intl.supportedValuesOf, DateTimeFormat.formatRange, dayPeriod.
//   * Collation orders Latin text like ICU's root/en collation and other scripts by code point.
(function (global, host, dataJson) {
  "use strict";

  const DEFAULT_LOCALE = "en-US";
  let dataCache;
  const data = () => dataCache || (dataCache = JSON.parse(dataJson));

  const defineHidden = (target, key, value) =>
    Object.defineProperty(target, key, { value, writable: true, configurable: true, enumerable: false });
  const defineGetter = (target, key, get) =>
    Object.defineProperty(target, key, { get, configurable: true, enumerable: false });
  const defineTag = (target, tag) =>
    Object.defineProperty(target, Symbol.toStringTag, { value: tag, configurable: true });
  const defineMethod = (target, name, length, fn) => {
    Object.defineProperty(fn, "name", { value: name, configurable: true });
    Object.defineProperty(fn, "length", { value: length, configurable: true });
    defineHidden(target, name, fn);
  };
  const hidden = (value) => ({ value, writable: true, configurable: true, enumerable: false });

  const slots = new WeakMap();
  function slotOf(receiver, kind, method) {
    const slot = receiver !== null && typeof receiver === "object" ? slots.get(receiver) : undefined;
    if (!slot || slot.kind !== kind) {
      throw new TypeError(`Method Intl.${kind}.prototype.${method} called on incompatible receiver ${String(receiver)}`);
    }
    return slot;
  }

  // ---------------------------------------------------------------- options helpers
  function coerceOptions(options) {
    if (options === undefined) return Object.create(null);
    if (options === null) throw new TypeError("Cannot convert undefined or null to object");
    return Object(options);
  }
  function stringOption(options, name, allowed, fallback) {
    let value = options[name];
    if (value === undefined) return fallback;
    value = String(value);
    if (allowed && !allowed.includes(value)) {
      throw new RangeError(`Value ${value} out of range for Intl options property ${name}`);
    }
    return value;
  }
  function boolOption(options, name, fallback) {
    const value = options[name];
    return value === undefined ? fallback : Boolean(value);
  }
  function numberOption(options, name, min, max, fallback) {
    let value = options[name];
    if (value === undefined) return fallback;
    value = Number(value);
    if (value !== value || value < min || value > max) throw new RangeError(`${name} value is out of range.`);
    return Math.floor(value);
  }

  // ---------------------------------------------------------------- locales
  const LANGUAGE_TAG = /^(?:[A-Za-z]{2,3}|[A-Za-z]{5,8})(?:-[A-Za-z]{4})?(?:-(?:[A-Za-z]{2}|[0-9]{3}))?(?:-(?:[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3}))*(?:-[A-WY-Za-wy-z0-9](?:-[A-Za-z0-9]{2,8})+)*(?:-[Xx](?:-[A-Za-z0-9]{1,8})+)?$/;
  function canonicalTag(tag) {
    if (!LANGUAGE_TAG.test(tag)) throw new RangeError(`Incorrect locale information provided`);
    const parts = tag.split("-");
    let seenSingleton = false;
    return parts.map((part, i) => {
      if (i === 0) return part.toLowerCase();
      if (part.length === 1) seenSingleton = true;
      if (seenSingleton) return part.toLowerCase();
      if (part.length === 4 && /^[A-Za-z]+$/.test(part)) return part[0].toUpperCase() + part.slice(1).toLowerCase();
      if (part.length === 2 && /^[A-Za-z]+$/.test(part)) return part.toUpperCase();
      return part.toLowerCase();
    }).join("-");
  }
  function canonicalizeLocaleList(locales) {
    if (locales === undefined) return [];
    if (typeof locales === "string" || (locales !== null && typeof locales === "object" && slots.get(locales)?.kind === "Locale")) {
      locales = [locales];
    } else if (locales === null) {
      throw new TypeError("Cannot convert undefined or null to object");
    }
    const list = Object(locales);
    const length = Math.min(Math.max(Math.floor(Number(list.length)) || 0, 0), 2 ** 32 - 1);
    const seen = [];
    for (let i = 0; i < length; i++) {
      if (!(i in list)) continue;
      const item = list[i];
      if (typeof item !== "string" && (item === null || typeof item !== "object")) {
        throw new TypeError("Language ID should be string or object.");
      }
      const slot = typeof item === "object" ? slots.get(item) : undefined;
      const tag = canonicalTag(slot && slot.kind === "Locale" ? slot.tag : String(item));
      if (!seen.includes(tag)) seen.push(tag);
    }
    return seen;
  }
  const isSupportedTag = (tag) => ["en", "en-US"].includes(tag.replace(/-[a-wy-z0-9](?:-[a-z0-9]+)+$/i, ""));
  function supportedLocalesOf(locales, options) {
    const list = canonicalizeLocaleList(locales);
    if (options !== undefined) stringOption(coerceOptions(options), "localeMatcher", ["lookup", "best fit"], "best fit");
    return list.filter(isSupportedTag);
  }
  // Validates the argument like the real constructors do. Only English has data, so the result
  // is the first requested English locale, or en-US (the spec's fallback) when there is none.
  const resolveLocale = (locales) => {
    const found = canonicalizeLocaleList(locales).find(isSupportedTag);
    return found ? found.replace(/-[a-wy-z0-9](?:-[a-z0-9]+)+$/i, "") : DEFAULT_LOCALE;
  };

  function installStatics(ctor, kind) {
    defineMethod(ctor, "supportedLocalesOf", 1, function supportedLocalesOfMethod(locales, options) {
      return supportedLocalesOf(locales, options);
    });
    defineTag(ctor.prototype, `Intl.${kind}`);
  }
  function makeConstructor(name, length, impl, callable) {
    const ctor = {
      [name]: function (...args) {
        if (new.target === undefined) {
          if (!callable) throw new TypeError(`Constructor Intl.${name} requires 'new'`);
          return Reflect.construct(ctor, args, ctor);
        }
        return impl.apply(this, args);
      },
    }[name];
    Object.defineProperty(ctor, "length", { value: length, configurable: true });
    Object.defineProperty(ctor, "prototype", { writable: false, enumerable: false, configurable: false, value: Object.create(Object.prototype, { constructor: hidden(ctor) }) });
    return ctor;
  }

  // ---------------------------------------------------------------- decimal arithmetic
  // A decimal is { kind: "num" | "nan" | "inf", neg, digits, point }: value = 0.digits * 10^point,
  // digits has no leading or trailing zeros ("" for zero).
  function decimalFromString(text, neg) {
    const match = /^(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(text);
    const intPart = match[1] || "";
    const fracPart = match[2] || "";
    const exp = match[3] ? parseInt(match[3], 10) : 0;
    let digits = intPart + fracPart;
    let point = intPart.length + exp;
    let lead = 0;
    while (lead < digits.length && digits[lead] === "0") lead++;
    digits = digits.slice(lead).replace(/0+$/, "");
    point -= lead;
    return { kind: "num", neg, digits, point: digits === "" ? 0 : point };
  }
  function toDecimal(value) {
    if (typeof value === "bigint") return decimalFromString(String(value < 0n ? -value : value), value < 0n);
    if (typeof value === "string") {
      const text = value.trim();
      if (/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)) {
        return decimalFromString(text.replace(/^[+-]/, ""), text[0] === "-");
      }
    }
    const number = typeof value === "object" && value !== null ? Number(value) : typeof value === "number" ? value : Number(value);
    if (number !== number) return { kind: "nan", neg: false };
    const neg = number < 0 || (number === 0 && 1 / number < 0);
    if (number === Infinity || number === -Infinity) return { kind: "inf", neg };
    return decimalFromString(String(Math.abs(number)), neg);
  }
  const isZero = (dec) => dec.kind === "num" && dec.digits === "";
  const withDigits = (dec, digits, point) => {
    digits = digits.replace(/0+$/, "");
    return { kind: dec.kind, neg: dec.neg, digits, point: digits === "" ? 0 : point };
  };
  const shiftPoint = (dec, by) => (dec.digits === "" ? dec : { kind: dec.kind, neg: dec.neg, digits: dec.digits, point: dec.point + by });

  // Rounds to `cut` leading digits (negative or past the end allowed).
  function roundAt(dec, cut, mode) {
    const digits = dec.digits;
    if (cut >= digits.length || digits === "") return dec;
    const rest = cut < 0 ? digits : digits.slice(cut);
    // 1 = below half, 2 = exactly half, 3 = above half
    let remainder;
    if (cut < 0) remainder = 1;
    else if (rest[0] < "5") remainder = 1;
    else if (rest[0] === "5") remainder = rest.length === 1 ? 2 : 3;
    else remainder = 3;
    const kept = cut < 0 ? "" : digits.slice(0, cut);
    const odd = kept.length > 0 && (kept.charCodeAt(kept.length - 1) & 1) === 1;
    const neg = dec.neg;
    let up;
    switch (mode) {
      case "ceil": up = !neg; break;
      case "floor": up = neg; break;
      case "expand": up = true; break;
      case "trunc": up = false; break;
      case "halfCeil": up = remainder === 3 || (remainder === 2 && !neg); break;
      case "halfFloor": up = remainder === 3 || (remainder === 2 && neg); break;
      case "halfTrunc": up = remainder === 3; break;
      case "halfEven": up = remainder === 3 || (remainder === 2 && odd); break;
      default: up = remainder >= 2; // halfExpand
    }
    if (!up) return withDigits(dec, kept, dec.point);
    if (kept === "") return unitAt(dec, cut);
    const chars = kept.split("");
    let i = chars.length - 1;
    while (i >= 0 && chars[i] === "9") { chars[i] = "0"; i--; }
    if (i < 0) return withDigits(dec, "1", dec.point + 1);
    chars[i] = String.fromCharCode(chars[i].charCodeAt(0) + 1);
    return withDigits(dec, chars.join(""), dec.point);
  }
  // 10^(point - cut): one unit in the last kept place.
  const unitAt = (dec, cut) => withDigits(dec, "1", dec.point - cut + 1);

  function integerDigits(dec) {
    if (dec.digits === "" || dec.point <= 0) return "0";
    return dec.digits.slice(0, dec.point).padEnd(dec.point, "0");
  }
  function fractionDigits(dec) {
    if (dec.digits === "" || dec.digits.length <= dec.point) return "";
    return dec.point >= 0 ? dec.digits.slice(dec.point) : "0".repeat(-dec.point) + dec.digits;
  }

  // ---------------------------------------------------------------- NumberFormat
  const currencyDigits = (code) => {
    const table = data().currencyDigits;
    return Object.prototype.hasOwnProperty.call(table, code) ? table[code] : 2;
  };
  const SANCTIONED_UNITS = () => data().units;
  const COMPACT_SHORT = ["", "K", "M", "B", "T"];
  const COMPACT_LONG = ["", " thousand", " million", " billion", " trillion"];

  function resolveDigitOptions(rec, options, defaultMin, defaultMax, compactDefault) {
    rec.minimumIntegerDigits = numberOption(options, "minimumIntegerDigits", 1, 21, 1);
    const mnfd = options.minimumFractionDigits, mxfd = options.maximumFractionDigits;
    const mnsd = options.minimumSignificantDigits, mxsd = options.maximumSignificantDigits;
    rec.roundingType = "fraction";
    if (mnsd !== undefined || mxsd !== undefined) {
      rec.roundingType = "significant";
      rec.minimumSignificantDigits = numberOption(options, "minimumSignificantDigits", 1, 21, 1);
      rec.maximumSignificantDigits = numberOption(options, "maximumSignificantDigits", rec.minimumSignificantDigits, 21, 21);
    } else if (mnfd !== undefined || mxfd !== undefined) {
      let min = numberOption(options, "minimumFractionDigits", 0, 100, undefined);
      let max = numberOption(options, "maximumFractionDigits", 0, 100, undefined);
      if (min === undefined) min = Math.min(defaultMin, max);
      else if (max === undefined) max = Math.max(defaultMax, min);
      else if (min > max) throw new RangeError("maximumFractionDigits value is out of range.");
      rec.minimumFractionDigits = min;
      rec.maximumFractionDigits = max;
    } else if (compactDefault) {
      rec.roundingType = "compact";
      rec.minimumFractionDigits = 0;
      rec.maximumFractionDigits = 0;
    } else {
      rec.minimumFractionDigits = defaultMin;
      rec.maximumFractionDigits = defaultMax;
    }
  }

  function initNumberFormat(self, locales, options) {
    const locale = resolveLocale(locales);
    options = coerceOptions(options);
    stringOption(options, "localeMatcher", ["lookup", "best fit"], "best fit");
    const nu = options.numberingSystem;
    if (nu !== undefined && !/^[A-Za-z0-9]{3,8}(?:-[A-Za-z0-9]{3,8})*$/.test(String(nu))) {
      throw new RangeError(`Invalid numberingSystem : ${nu}`);
    }
    const rec = { kind: "NumberFormat", locale, numberingSystem: "latn" };
    rec.style = stringOption(options, "style", ["decimal", "percent", "currency", "unit"], "decimal");
    let currency = options.currency;
    if (currency !== undefined) {
      currency = String(currency);
      if (!/^[A-Za-z]{3}$/.test(currency)) throw new RangeError(`Invalid currency code : ${currency}`);
      currency = currency.toUpperCase();
    }
    if (rec.style === "currency" && currency === undefined) throw new TypeError("Currency code is required with currency style.");
    const currencyDisplay = stringOption(options, "currencyDisplay", ["code", "symbol", "narrowSymbol", "name"], "symbol");
    const currencySign = stringOption(options, "currencySign", ["standard", "accounting"], "standard");
    let unit = options.unit;
    if (unit !== undefined) unit = String(unit);
    if (unit !== undefined && !Object.prototype.hasOwnProperty.call(SANCTIONED_UNITS(), unit)) {
      throw new RangeError(`Invalid unit argument for Intl.NumberFormat() '${unit}'`);
    }
    if (rec.style === "unit" && unit === undefined) throw new TypeError("Unit is required with unit style.");
    const unitDisplay = stringOption(options, "unitDisplay", ["short", "narrow", "long"], "short");
    if (rec.style === "currency") {
      rec.currency = currency; rec.currencyDisplay = currencyDisplay; rec.currencySign = currencySign;
    } else if (rec.style === "unit") {
      rec.unit = unit; rec.unitDisplay = unitDisplay;
    }
    const notation = stringOption(options, "notation", ["standard", "scientific", "engineering", "compact"], "standard");
    rec.notation = notation;
    const isCurrency = rec.style === "currency";
    const cd = isCurrency ? currencyDigits(currency) : 0;
    resolveDigitOptions(rec, options, isCurrency ? cd : 0, isCurrency ? cd : rec.style === "percent" ? 0 : 3, notation === "compact");
    rec.compactDisplay = stringOption(options, "compactDisplay", ["short", "long"], "short");
    let grouping = options.useGrouping;
    const groupingDefault = notation === "compact" ? "min2" : "auto";
    if (grouping === undefined) grouping = groupingDefault;
    else if (grouping === true) grouping = "always";
    else if (grouping === false) grouping = false;
    else if (grouping === "true" || grouping === "false") grouping = groupingDefault;
    else {
      grouping = String(grouping);
      if (!["min2", "auto", "always"].includes(grouping)) throw new RangeError(`Value ${grouping} out of range for Intl.NumberFormat options property useGrouping`);
    }
    rec.useGrouping = grouping;
    rec.signDisplay = stringOption(options, "signDisplay", ["auto", "never", "always", "exceptZero", "negative"], "auto");
    rec.roundingIncrement = 1;
    rec.roundingMode = stringOption(options, "roundingMode", ["ceil", "floor", "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven"], "halfExpand");
    rec.roundingPriority = "auto";
    rec.trailingZeroDisplay = stringOption(options, "trailingZeroDisplay", ["auto", "stripIfInteger"], "auto");
    slots.set(self, rec);
    return self;
  }

  // Rounds `dec` per the digit options and returns { dec, text: [integer, fraction] }.
  function roundForDisplay(rec, dec, forceType) {
    const type = forceType || rec.roundingType;
    let rounded = dec;
    if (type === "significant") {
      rounded = roundAt(dec, rec.maximumSignificantDigits, rec.roundingMode);
    } else if (type === "fraction") {
      rounded = roundAt(dec, dec.point + rec.maximumFractionDigits, rec.roundingMode);
    }
    return rounded;
  }
  function digitStrings(rec, dec, type) {
    const rawInteger = integerDigits(dec);
    let intText = rawInteger.padStart(rec.minimumIntegerDigits, "0");
    let fracText = fractionDigits(dec);
    if (type === "significant") {
      const shown = Math.max(dec.digits.length, dec.point, dec.digits === "" ? 1 : 0);
      fracText = fracText.padEnd(fracText.length + Math.max(0, rec.minimumSignificantDigits - shown), "0");
    } else {
      fracText = fracText.padEnd(rec.minimumFractionDigits, "0");
    }
    if (rec.trailingZeroDisplay === "stripIfInteger" && /^0*$/.test(fracText)) fracText = "";
    return [intText, fracText, rawInteger];
  }
  function groupInteger(rec, intText) {
    const mode = rec.useGrouping;
    if (mode === false || intText.length <= 3) return [intText];
    if (mode === "min2" && intText.length < 5) return [intText];
    const groups = [];
    for (let end = intText.length; end > 0; end -= 3) groups.unshift(intText.slice(Math.max(0, end - 3), end));
    return groups;
  }

  function numberParts(rec, input) {
    let dec = toDecimal(input);
    const parts = [];
    const push = (type, value) => parts.push({ type, value });
    let body = [];           // parts of the number itself (no sign / currency / unit)
    let compactSuffix = "";
    let plural = "other";    // plural category used for unit and currency names
    let negative = dec.neg;
    let zero = false;

    if (dec.kind === "nan") {
      body.push({ type: "nan", value: "NaN" });
      negative = false;
    } else if (dec.kind === "inf") {
      body.push({ type: "infinity", value: "\u221e" });
    } else {
      if (rec.style === "percent") dec = shiftPoint(dec, 2);
      let exponent = null;
      let type = rec.roundingType;
      let shown;
      if (rec.notation === "compact") {
        let index = dec.digits === "" ? 0 : Math.max(0, Math.min(4, Math.floor((dec.point - 1) / 3)));
        let scaled, rounded;
        for (;;) {
          scaled = shiftPoint(dec, -3 * index);
          if (type === "compact") {
            rounded = integerDigits(scaled).length >= 2 && scaled.point >= 2
              ? roundAt(scaled, scaled.point, rec.roundingMode)
              : roundAt(scaled, 2, rec.roundingMode);
          } else {
            rounded = roundForDisplay(rec, scaled, type);
          }
          if (index < 4 && rounded.digits !== "" && rounded.point > 3) { index++; continue; }
          break;
        }
        shown = rounded;
        compactSuffix = rec.compactDisplay === "long" ? COMPACT_LONG[index] : COMPACT_SHORT[index];
      } else if (rec.notation === "scientific" || rec.notation === "engineering") {
        let e = dec.digits === "" ? 0 : dec.point - 1;
        const step = rec.notation === "engineering" ? 3 : 1;
        let e0 = Math.floor(e / step) * step;
        let mantissa = shiftPoint(dec, -e0);
        mantissa = roundForDisplay(rec, mantissa, type);
        if (mantissa.digits !== "" && mantissa.point > step) {
          e0 += step;
          mantissa = roundForDisplay(rec, shiftPoint(dec, -e0), type);
        }
        exponent = mantissa.digits === "" ? 0 : e0;
        shown = mantissa;
      } else {
        shown = roundForDisplay(rec, dec, type);
      }
      zero = shown.digits === "";
      const [intText, fracText, rawInteger] = digitStrings(rec, shown, type === "compact" ? "fraction" : type);
      const groups = groupInteger(rec, intText);
      groups.forEach((group, i) => { if (i) push("group", ","); push("integer", group); });
      body = parts.splice(0);
      if (fracText !== "") { body.push({ type: "decimal", value: "." }); body.push({ type: "fraction", value: fracText }); }
      if (exponent !== null) {
        body.push({ type: "exponentSeparator", value: "E" });
        if (exponent < 0) body.push({ type: "exponentMinusSign", value: "-" });
        body.push({ type: "exponentInteger", value: String(Math.abs(exponent)) });
      }
      plural = fracText === "" && rawInteger === "1" && exponent === null && compactSuffix === "" ? "one" : "other";
    }

    // sign
    let sign = "";
    const isNaNValue = dec.kind === "nan";
    switch (rec.signDisplay) {
      case "never": break;
      case "always": sign = isNaNValue ? "+" : negative ? "-" : "+"; break;
      case "exceptZero": sign = isNaNValue || zero ? "" : negative ? "-" : "+"; break;
      case "negative": sign = negative && !zero ? "-" : ""; break;
      default: sign = negative ? "-" : "";
    }
    const accounting = rec.style === "currency" && rec.currencySign === "accounting" && sign === "-";
    const signPart = sign === "" ? [] : [{ type: sign === "-" ? "minusSign" : "plusSign", value: sign }];

    const out = [];
    const compactPart = compactSuffix === "" ? [] : compactSuffix.startsWith(" ")
      ? [{ type: "literal", value: " " }, { type: "compact", value: compactSuffix.slice(1) }]
      : [{ type: "compact", value: compactSuffix }];
    const numberPart = body.concat(compactPart);

    if (rec.style === "currency") {
      const code = rec.currency;
      const d = data();
      if (rec.currencyDisplay === "name") {
        const names = d.currencyName[code];
        const name = names ? names[plural === "one" ? 0 : 1] : code;
        out.push(...signPart, ...numberPart, { type: "literal", value: " " }, { type: "currency", value: name });
      } else {
        let symbol = code;
        if (rec.currencyDisplay === "symbol") symbol = d.currencySymbol[code] || code;
        else if (rec.currencyDisplay === "narrowSymbol") symbol = d.currencyNarrow[code] || d.currencySymbol[code] || code;
        const gap = /[\p{L}]$/u.test(symbol) && numberPart[0].type === "integer" ? [{ type: "literal", value: "\u00a0" }] : [];
        if (accounting) out.push({ type: "literal", value: "(" });
        else out.push(...signPart);
        out.push({ type: "currency", value: symbol }, ...gap, ...numberPart);
        if (accounting) out.push({ type: "literal", value: ")" });
      }
    } else if (rec.style === "percent") {
      out.push(...signPart, ...numberPart, { type: "percentSign", value: "%" });
    } else if (rec.style === "unit") {
      const set = data().units[rec.unit][rec.unitDisplay];
      const template = set[plural === "one" ? 0 : 1];
      const pieces = template.split("{0}");
      const before = pieces[0], after = pieces[1];
      if (before) out.push({ type: "unit", value: before.trim() }, ...(/\s$/.test(before) ? [{ type: "literal", value: " " }] : []));
      out.push(...signPart, ...numberPart);
      if (after) {
        if (/^\s/.test(after)) out.push({ type: "literal", value: " " });
        if (after.trim()) out.push({ type: "unit", value: after.trim() });
      }
    } else {
      out.push(...signPart, ...numberPart);
    }
    return { parts: out, plural };
  }
  const joinParts = (parts) => parts.map((p) => p.value).join("");

  const NumberFormat = makeConstructor("NumberFormat", 0, function (locales, options) {
    return initNumberFormat(this, locales, options);
  }, true);
  installStatics(NumberFormat, "NumberFormat");
  defineGetter(NumberFormat.prototype, "format", function () {
    const slot = slotOf(this, "NumberFormat", "format");
    if (!slot.bound) {
      const rec = slot;
      const bound = (value) => joinParts(numberParts(rec, value).parts);
      Object.defineProperty(bound, "name", { value: "", configurable: true });
      slot.bound = bound;
    }
    return slot.bound;
  });
  defineMethod(NumberFormat.prototype, "formatToParts", 1, function formatToParts(value) {
    return numberParts(slotOf(this, "NumberFormat", "formatToParts"), value).parts;
  });
  defineMethod(NumberFormat.prototype, "formatRange", 2, function formatRange(start, end) {
    const rec = slotOf(this, "NumberFormat", "formatRange");
    if (start === undefined || end === undefined) throw new TypeError("start or end is undefined");
    const a = joinParts(numberParts(rec, start).parts), b = joinParts(numberParts(rec, end).parts);
    return a === b ? `~${a}` : `${a}\u2013${b}`;
  });
  defineMethod(NumberFormat.prototype, "resolvedOptions", 0, function resolvedOptions() {
    const rec = slotOf(this, "NumberFormat", "resolvedOptions");
    const out = { locale: rec.locale, numberingSystem: rec.numberingSystem, style: rec.style };
    if (rec.style === "currency") { out.currency = rec.currency; out.currencyDisplay = rec.currencyDisplay; out.currencySign = rec.currencySign; }
    if (rec.style === "unit") { out.unit = rec.unit; out.unitDisplay = rec.unitDisplay; }
    out.minimumIntegerDigits = rec.minimumIntegerDigits;
    if (rec.roundingType === "significant") {
      out.minimumSignificantDigits = rec.minimumSignificantDigits;
      out.maximumSignificantDigits = rec.maximumSignificantDigits;
    } else {
      out.minimumFractionDigits = rec.minimumFractionDigits;
      out.maximumFractionDigits = rec.maximumFractionDigits;
      if (rec.roundingType === "compact") { out.minimumSignificantDigits = 1; out.maximumSignificantDigits = 2; }
    }
    out.useGrouping = rec.useGrouping;
    out.notation = rec.notation;
    if (rec.notation === "compact") out.compactDisplay = rec.compactDisplay;
    out.signDisplay = rec.signDisplay;
    out.roundingIncrement = rec.roundingIncrement;
    out.roundingMode = rec.roundingMode;
    out.roundingPriority = rec.roundingType === "compact" ? "morePrecision" : rec.roundingPriority;
    out.trailingZeroDisplay = rec.trailingZeroDisplay;
    return out;
  });

  // ---------------------------------------------------------------- time zones
  const UTC_NAMES = new Set(["UTC", "ETC/UTC", "ETC/GMT", "GMT", "ETC/UCT", "UCT", "ETC/UNIVERSAL", "UNIVERSAL", "ETC/ZULU", "ZULU"]);
  const pad2 = (n) => (n < 10 ? "0" + n : String(n));
  const pad = (n, width) => String(n).padStart(width, "0");
  function offsetText(seconds, long) {
    const sign = seconds < 0 ? "-" : "+";
    const total = Math.round(Math.abs(seconds) / 60);
    const h = Math.floor(total / 60), m = total % 60;
    if (long) return `GMT${sign}${pad2(h)}:${pad2(m)}`;
    return `GMT${sign}${h}${m ? ":" + pad2(m) : ""}`;
  }
  function parseOffsetZone(text) {
    const match = /^([+-])(\d{2})(?::?(\d{2}))?$/.exec(text);
    if (!match) return null;
    const hours = Number(match[2]), minutes = Number(match[3] || 0);
    if (hours > 23 || minutes > 59) return null;
    const seconds = (hours * 60 + minutes) * 60;
    return { kind: "fixed", seconds: match[1] === "-" ? -seconds : seconds, id: `${match[1]}${match[2]}:${match[3] || "00"}` };
  }
  function makeZone(spec) {
    if (spec === undefined) {
      let id;
      try { id = host.local(); } catch (e) { id = undefined; }
      return { kind: "local", id };
    }
    const text = String(spec);
    if (UTC_NAMES.has(text.toUpperCase())) return { kind: "utc", id: "UTC" };
    const offset = parseOffsetZone(text);
    if (offset) return offset;
    const etc = /^Etc\/GMT([+-])(\d{1,2})$/i.exec(text);
    if (etc && Number(etc[2]) <= 14) {
      const seconds = Number(etc[2]) * 3600 * (etc[1] === "+" ? -1 : 1);
      return { kind: "etc", seconds, id: `Etc/GMT${etc[1]}${Number(etc[2])}` };
    }
    let canonical;
    try { canonical = host.zone(text); } catch (e) { canonical = undefined; }
    if (!canonical) throw new RangeError(`Invalid time zone specified: ${text}`);
    return { kind: "iana", id: canonical };
  }
  function zoneOffset(zone, ms) {
    switch (zone.kind) {
      case "utc": return 0;
      case "fixed": case "etc": return zone.seconds;
      case "local": return -new Date(ms).getTimezoneOffset() * 60;
      default: return host.offset(zone.id, ms);
    }
  }
  function zoneId(zone) {
    if (zone.kind !== "local") return zone.id;
    if (zone.id) return zone.id;
    const seconds = zoneOffset(zone, Date.now());
    if (seconds === 0) return "UTC";
    return `${seconds < 0 ? "-" : "+"}${pad2(Math.floor(Math.abs(seconds) / 3600))}:${pad2(Math.floor(Math.abs(seconds) % 3600 / 60))}`;
  }
  function zoneName(zone, ms, style) {
    const seconds = zoneOffset(zone, ms);
    const id = zone.kind === "local" ? zone.id : zone.kind === "iana" || zone.kind === "etc" ? zone.id : undefined;
    if (zone.kind === "utc" || (zone.kind === "local" && !zone.id && seconds === 0)) {
      if (style === "short") return "UTC";
      if (style === "long") return "Coordinated Universal Time";
      return style.startsWith("long") ? "GMT+00:00" : "GMT+0";
    }
    const names = id !== undefined ? data().tzNames : null;
    const set = names && Object.prototype.hasOwnProperty.call(names.ids, id) ? names.sets[names.ids[id]] : null;
    if (set) {
      const year = new Date(ms).getUTCFullYear();
      const jan = zoneOffset(zone, Date.UTC(year, 0, 1)), jul = zoneOffset(zone, Date.UTC(year, 6, 1));
      const dst = jan !== jul && seconds > Math.min(jan, jul);
      let named = "";
      switch (style) {
        case "short": named = set[dst ? 1 : 0]; break;
        case "long": named = set[dst ? 3 : 2]; break;
        case "shortGeneric": named = set[4]; break;
        case "longGeneric": named = set[5]; break;
      }
      if (named) return named;
    }
    if (seconds === 0 && (style === "short" || style === "shortGeneric" || style === "long" || style === "longGeneric")) {
      return style.startsWith("short") ? "GMT" : "Greenwich Mean Time";
    }
    return offsetText(seconds, style === "long" || style === "longOffset" || style === "longGeneric");
  }

  // ---------------------------------------------------------------- DateTimeFormat
  const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const FIELD_OPTIONS = {
    weekday: ["narrow", "short", "long"], era: ["narrow", "short", "long"],
    year: ["2-digit", "numeric"], month: ["2-digit", "numeric", "narrow", "short", "long"],
    day: ["2-digit", "numeric"], hour: ["2-digit", "numeric"], minute: ["2-digit", "numeric"], second: ["2-digit", "numeric"],
  };
  const DATE_STYLES = {
    full: { weekday: "long", month: "long", day: "numeric", year: "numeric" },
    long: { month: "long", day: "numeric", year: "numeric" },
    medium: { month: "short", day: "numeric", year: "numeric" },
    short: { month: "numeric", day: "numeric", year: "2-digit" },
  };
  const TIME_STYLES = {
    full: { hour: "numeric", minute: "2-digit", second: "2-digit", timeZoneName: "long" },
    long: { hour: "numeric", minute: "2-digit", second: "2-digit", timeZoneName: "short" },
    medium: { hour: "numeric", minute: "2-digit", second: "2-digit" },
    short: { hour: "numeric", minute: "2-digit" },
  };

  function initDateTimeFormat(self, locales, options, required, defaults) {
    const locale = resolveLocale(locales);
    options = coerceOptions(options);
    stringOption(options, "localeMatcher", ["lookup", "best fit"], "best fit");
    stringOption(options, "calendar", undefined, undefined);
    const nu = options.numberingSystem;
    if (nu !== undefined && !/^[A-Za-z0-9]{3,8}(?:-[A-Za-z0-9]{3,8})*$/.test(String(nu))) throw new RangeError(`Invalid numberingSystem : ${nu}`);
    const hour12 = options.hour12 === undefined ? undefined : Boolean(options.hour12);
    let hourCycle = stringOption(options, "hourCycle", ["h11", "h12", "h23", "h24"], undefined);
    const zone = makeZone(options.timeZone);
    const rec = { kind: "DateTimeFormat", locale, zone };
    const fields = {};
    for (const name of ["weekday", "era", "year", "month", "day"]) fields[name] = stringOption(options, name, FIELD_OPTIONS[name], undefined);
    const dayPeriod = stringOption(options, "dayPeriod", ["narrow", "short", "long"], undefined);
    for (const name of ["hour", "minute", "second"]) fields[name] = stringOption(options, name, FIELD_OPTIONS[name], undefined);
    fields.fractionalSecondDigits = numberOption(options, "fractionalSecondDigits", 1, 3, undefined);
    fields.timeZoneName = stringOption(options, "timeZoneName", ["short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric"], undefined);
    stringOption(options, "formatMatcher", ["basic", "best fit"], "best fit");
    const dateStyle = stringOption(options, "dateStyle", ["full", "long", "medium", "short"], undefined);
    const timeStyle = stringOption(options, "timeStyle", ["full", "long", "medium", "short"], undefined);
    void dayPeriod;

    const anyField = Object.keys(fields).some((k) => fields[k] !== undefined);
    if (dateStyle !== undefined || timeStyle !== undefined) {
      if (anyField) {
        const name = Object.keys(fields).find((k) => fields[k] !== undefined);
        throw new TypeError(`Can't set option ${name} when ${dateStyle !== undefined ? "dateStyle" : "timeStyle"} is used`);
      }
      if (required === "date" && timeStyle !== undefined) throw new TypeError("Invalid option : timeStyle");
      if (required === "time" && dateStyle !== undefined) throw new TypeError("Invalid option : dateStyle");
      rec.dateStyle = dateStyle;
      rec.timeStyle = timeStyle;
      Object.assign(fields, dateStyle ? DATE_STYLES[dateStyle] : {}, timeStyle ? TIME_STYLES[timeStyle] : {});
    } else {
      const hasDate = ["weekday", "year", "month", "day"].some((k) => fields[k] !== undefined);
      const hasTime = ["hour", "minute", "second", "fractionalSecondDigits"].some((k) => fields[k] !== undefined);
      let needDefaults = true;
      if ((required === "date" || required === "any") && hasDate) needDefaults = false;
      if ((required === "time" || required === "any") && hasTime) needDefaults = false;
      if (needDefaults && (defaults === "date" || defaults === "all")) { fields.year = fields.month = fields.day = "numeric"; }
      if (needDefaults && (defaults === "time" || defaults === "all")) { fields.hour = fields.minute = fields.second = "numeric"; }
    }

    const hasHour = fields.hour !== undefined;
    if (hasHour) {
      if (hour12 !== undefined) hourCycle = hour12 ? "h12" : "h23";
      else if (hourCycle === undefined) hourCycle = "h12";
      rec.hourCycle = hourCycle;
      rec.hour12 = hourCycle === "h11" || hourCycle === "h12";
    }
    rec.fields = fields;
    rec.pattern = null;
    slots.set(self, rec);
    return self;
  }

  function buildPattern(rec) {
    const f = rec.fields;
    const items = [];
    const lit = (text) => items.push(text);
    const field = (name) => items.push({ f: name });
    const textMonth = f.month === "long" || f.month === "short" || f.month === "narrow";
    const hasDate = f.weekday || f.year || f.month || f.day;
    if (textMonth) {
      if (f.weekday) { field("weekday"); lit(", "); }
      field("month");
      if (f.day) { lit(" "); field("day"); }
      if (f.year) { lit(f.day ? ", " : " "); field("year"); }
    } else if (f.month) {
      if (f.weekday) { field("weekday"); lit(", "); }
      field("month");
      if (f.day) { lit("/"); field("day"); }
      if (f.year) { lit("/"); field("year"); }
    } else {
      if (f.day && f.weekday) { field("day"); lit(" "); field("weekday"); }
      else if (f.weekday) field("weekday");
      else if (f.day) field("day");
      if (f.year) { if (items.length) lit(" "); field("year"); }
    }
    if (f.era) { if (items.length) lit(" "); field("era"); }

    const time = [];
    const hasTime = f.hour || f.minute || f.second || f.fractionalSecondDigits;
    if (f.hour) {
      time.push({ f: "hour" });
      if (f.minute) { time.push(":", { f: "minute" }); }
      if (f.second) { time.push(":", { f: "second" }); }
    } else if (f.minute) {
      time.push({ f: "minute" });
      if (f.second) time.push(":", { f: "second" });
    } else if (f.second) {
      time.push({ f: "second" });
    }
    if (f.fractionalSecondDigits) { if (f.second) time.push("."); time.push({ f: "fractionalSecond" }); }
    if (f.hour && rec.hour12) time.push(" ", { f: "dayPeriod" });
    if (hasTime) {
      if (hasDate) {
        const long = rec.dateStyle ? rec.dateStyle === "full" || rec.dateStyle === "long" : f.month === "long";
        lit(long ? " at " : f.weekday && !f.month && !f.day && !f.year ? " " : ", ");
      }
      items.push(...time);
    }
    if (f.timeZoneName) {
      if (items.length) lit(hasTime ? " " : ", ");
      field("timeZoneName");
    }
    return items;
  }

  function dateParts(rec, ms) {
    const f = rec.fields;
    const zone = rec.zone;
    const offset = zoneOffset(zone, ms);
    const d = new Date(ms + offset * 1000);
    const year = d.getUTCFullYear(), month = d.getUTCMonth(), day = d.getUTCDate(), weekday = d.getUTCDay();
    const hours = d.getUTCHours();
    if (!rec.pattern) rec.pattern = buildPattern(rec);
    const value = (name) => {
      switch (name) {
        case "weekday": return f.weekday === "long" ? WEEKDAYS[weekday] : f.weekday === "short" ? WEEKDAYS[weekday].slice(0, 3) : WEEKDAYS[weekday][0];
        case "era": return year > 0 ? (f.era === "long" ? "Anno Domini" : f.era === "narrow" ? "A" : "AD") : (f.era === "long" ? "Before Christ" : f.era === "narrow" ? "B" : "BC");
        case "year": {
          const y = year > 0 ? year : 1 - year;
          return f.year === "2-digit" ? pad2(y % 100) : String(y);
        }
        case "month":
          if (f.month === "long") return MONTHS[month];
          if (f.month === "short") return MONTHS[month].slice(0, 3);
          if (f.month === "narrow") return MONTHS[month][0];
          return f.month === "2-digit" ? pad2(month + 1) : String(month + 1);
        case "day": return f.day === "2-digit" ? pad2(day) : String(day);
        case "hour": {
          let h = hours;
          switch (rec.hourCycle) {
            case "h11": h = h % 12; break;
            case "h12": h = h % 12 || 12; break;
            case "h24": h = h || 24; break;
          }
          return rec.hour12 && f.hour !== "2-digit" ? String(h) : pad2(h);
        }
        case "minute": return f.hour || f.second ? pad2(d.getUTCMinutes()) : String(d.getUTCMinutes());
        case "second": return f.minute ? pad2(d.getUTCSeconds()) : String(d.getUTCSeconds());
        case "fractionalSecond": return pad(d.getUTCMilliseconds(), 3).slice(0, f.fractionalSecondDigits);
        case "dayPeriod": return hours < 12 ? "AM" : "PM";
        case "timeZoneName": return zoneName(zone, ms, f.timeZoneName);
      }
      return "";
    };
    return rec.pattern.map((item) => (typeof item === "string" ? { type: "literal", value: item } : { type: item.f, value: value(item.f) }));
  }

  function toTime(value) {
    const ms = value === undefined ? Date.now() : Number(value);
    if (ms !== ms || Math.abs(ms) > 8.64e15) throw new RangeError("Invalid time value");
    return Math.trunc(ms) + 0;
  }

  const DateTimeFormat = makeConstructor("DateTimeFormat", 0, function (locales, options) {
    return initDateTimeFormat(this, locales, options, "any", "date");
  }, true);
  installStatics(DateTimeFormat, "DateTimeFormat");
  defineGetter(DateTimeFormat.prototype, "format", function () {
    const rec = slotOf(this, "DateTimeFormat", "format");
    if (!rec.bound) {
      const bound = (date) => joinParts(dateParts(rec, toTime(date)));
      Object.defineProperty(bound, "name", { value: "", configurable: true });
      rec.bound = bound;
    }
    return rec.bound;
  });
  defineMethod(DateTimeFormat.prototype, "formatToParts", 1, function formatToParts(date) {
    return dateParts(slotOf(this, "DateTimeFormat", "formatToParts"), toTime(date));
  });
  defineMethod(DateTimeFormat.prototype, "resolvedOptions", 0, function resolvedOptions() {
    const rec = slotOf(this, "DateTimeFormat", "resolvedOptions");
    const out = { locale: rec.locale, calendar: "gregory", numberingSystem: "latn", timeZone: zoneId(rec.zone) };
    if (rec.hourCycle !== undefined) { out.hourCycle = rec.hourCycle; out.hour12 = rec.hour12; }
    if (!rec.dateStyle && !rec.timeStyle) {
      const f = rec.fields;
      for (const name of ["weekday", "era", "year", "month", "day", "hour", "minute", "second"]) {
        if (f[name] === undefined) continue;
        let v = f[name];
        if (name === "minute") v = f.hour || f.second ? "2-digit" : "numeric";
        if (name === "second") v = f.minute ? "2-digit" : "numeric";
        if (name === "hour" && !rec.hour12) v = "2-digit";
        out[name] = v;
      }
      if (f.fractionalSecondDigits !== undefined) out.fractionalSecondDigits = f.fractionalSecondDigits;
      if (f.timeZoneName !== undefined) out.timeZoneName = f.timeZoneName;
    } else {
      if (rec.dateStyle) out.dateStyle = rec.dateStyle;
      if (rec.timeStyle) out.timeStyle = rec.timeStyle;
    }
    return out;
  });

  // ---------------------------------------------------------------- Collator
  // Three-level comparison in the spirit of the UCA: primary (base letters), secondary
  // (accents), tertiary (case, lower first). Latin text matches ICU's en collation.
  const PUNCT_ORDER = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$";
  // Letters that expand to a base plus a secondary-level mark ("\u00df" sorts as "ss" but after it).
  const SPECIAL_LETTERS = { "\u00df": ["ss", 0x111], "\u00e6": ["ae", 0x110], "\u0153": ["oe", 0x110], "\u00f8": ["o", 0x338], "\u0111": ["d", 0x335], "\u0142": ["l", 0x335] };
  const IGNORABLE = /^[\s\p{P}]$/u;
  function primaryWeight(ch) {
    const cp = ch.codePointAt(0);
    const punct = PUNCT_ORDER.indexOf(ch);
    if (punct >= 0) return 100 + punct;
    if (cp >= 48 && cp <= 57) return 500 + (cp - 48);
    if (cp >= 97 && cp <= 122) return 1000 + (cp - 97);
    if (cp === 0x131) return 1000 + 8 + 0.5; // dotless i is its own letter, right after i
    if (/^[\s\p{P}\p{S}]$/u.test(ch)) return 200 + cp / 0x20000;
    if (cp >= 0xac00 && cp <= 0xd7af) return 0x10000 + 0x2fff + (cp - 0xac00) / 0x10000;
    return 0x10000 + cp;
  }
  function collationKey(text, opts) {
    const primary = [], secondary = [], tertiary = [], caseLevel = [];
    const add = (p, s, t, c) => { primary.push(p); secondary.push(s); tertiary.push(t); if (p !== 0) caseLevel.push(c); };
    // NFKD folds compatibility characters ("\ufb01" -> "fi", "\u01c5" -> "D\u017e") into their base letters;
    // they differ from the plain letters only at the tertiary level.
    const chars = [], compat = [];
    for (const original of text) {
      const plain = original.normalize("NFD");
      const folded = original.normalize("NFKD");
      for (const ch of folded) { chars.push(ch); compat.push(folded !== plain); }
    }
    for (let i = 0; i < chars.length; i++) {
      const ch = chars[i];
      if (/^\p{M}$/u.test(ch)) { add(0, ch.codePointAt(0), 0, 0); continue; }
      if (opts.ignorePunctuation && IGNORABLE.test(ch)) continue;
      if (opts.numeric && /^[0-9]$/.test(ch)) {
        let j = i;
        while (j < chars.length && /^[0-9]$/.test(chars[j])) j++;
        const digits = chars.slice(i, j).join("").replace(/^0+(?=\d)/, "");
        add(500.5, 0, 0, 0);
        add(digits.length, 0, 0, 0);
        for (const digit of digits) add(Number(digit), 0, 0, 0);
        i = j - 1;
        continue;
      }
      const lower = ch.toLowerCase();
      const upper = lower !== ch && ch === ch.toUpperCase();
      const caseBit = upper ? (opts.caseFirst === "upper" ? -1 : 1) : 0;
      const variant = compat[i] ? 4 : 0;
      const special = SPECIAL_LETTERS[lower];
      if (special) {
        const [base, mark] = special;
        for (let k = 0; k < base.length; k++) {
          add(primaryWeight(base[k]), 0, caseBit, caseBit);
          if (k === 0) add(0, mark, 0, 0);
        }
        continue;
      }
      add(primaryWeight(lower.length === 1 || lower.codePointAt(0) > 0xffff ? lower : ch), 0, caseBit + variant, caseBit);
    }
    return { primary, secondary, tertiary, caseLevel };
  }
  function compareArrays(a, b, skipZeros) {
    let i = 0, j = 0;
    for (;;) {
      if (skipZeros) {
        while (i < a.length && a[i] === 0) i++;
        while (j < b.length && b[j] === 0) j++;
      }
      if (i >= a.length || j >= b.length) return i >= a.length && j >= b.length ? 0 : i >= a.length ? -1 : 1;
      if (a[i] !== b[j]) return a[i] < b[j] ? -1 : 1;
      i++; j++;
    }
  }
  function compareStrings(rec, x, y) {
    if (x === y) return 0;
    const cache = rec.cache;
    const key = (s) => { let k = cache.get(s); if (!k) { if (cache.size > 4000) cache.clear(); k = collationKey(s, rec); cache.set(s, k); } return k; };
    const a = key(x), b = key(y);
    let result = compareArrays(a.primary, b.primary, true);
    if (result !== 0) return result;
    if (rec.sensitivity === "base") return 0;
    if (rec.sensitivity === "case") return compareArrays(a.caseLevel, b.caseLevel, false);
    result = compareArrays(a.secondary, b.secondary, false);
    if (result !== 0) return result;
    if (rec.sensitivity === "accent") return 0;
    return compareArrays(a.tertiary, b.tertiary, false);
  }

  const Collator = makeConstructor("Collator", 0, function (locales, options) {
    const locale = resolveLocale(locales);
    options = coerceOptions(options);
    const rec = { kind: "Collator", locale };
    rec.usage = stringOption(options, "usage", ["sort", "search"], "sort");
    stringOption(options, "localeMatcher", ["lookup", "best fit"], "best fit");
    rec.collation = "default";
    rec.numeric = boolOption(options, "numeric", false);
    rec.caseFirst = stringOption(options, "caseFirst", ["upper", "lower", "false"], "false");
    rec.sensitivity = stringOption(options, "sensitivity", ["base", "accent", "case", "variant"], "variant");
    rec.ignorePunctuation = boolOption(options, "ignorePunctuation", false);
    rec.cache = new Map();
    slots.set(this, rec);
    return this;
  }, true);
  installStatics(Collator, "Collator");
  defineGetter(Collator.prototype, "compare", function () {
    const rec = slotOf(this, "Collator", "compare");
    if (!rec.bound) {
      const bound = (x, y) => compareStrings(rec, String(x), String(y));
      Object.defineProperty(bound, "name", { value: "", configurable: true });
      rec.bound = bound;
    }
    return rec.bound;
  });
  defineMethod(Collator.prototype, "resolvedOptions", 0, function resolvedOptions() {
    const rec = slotOf(this, "Collator", "resolvedOptions");
    return {
      locale: rec.locale, usage: rec.usage, sensitivity: rec.sensitivity, ignorePunctuation: rec.ignorePunctuation,
      collation: "default", numeric: rec.numeric, caseFirst: rec.caseFirst,
    };
  });
  let defaultCollator;
  const getDefaultCollator = () => defaultCollator || (defaultCollator = new Collator());

  // ---------------------------------------------------------------- PluralRules
  const PluralRules = makeConstructor("PluralRules", 0, function (locales, options) {
    const locale = resolveLocale(locales);
    options = coerceOptions(options);
    stringOption(options, "localeMatcher", ["lookup", "best fit"], "best fit");
    const rec = { kind: "PluralRules", locale, type: stringOption(options, "type", ["cardinal", "ordinal"], "cardinal") };
    resolveDigitOptions(rec, options, 0, 3, false);
    rec.roundingMode = "halfExpand";
    rec.trailingZeroDisplay = "auto";
    slots.set(this, rec);
    return this;
  }, false);
  installStatics(PluralRules, "PluralRules");
  defineMethod(PluralRules.prototype, "select", 1, function select(value) {
    const rec = slotOf(this, "PluralRules", "select");
    const number = Number(value);
    if (number !== number || number === Infinity || number === -Infinity) return "other";
    let dec = toDecimal(Math.abs(number));
    dec = rec.roundingType === "significant" ? roundAt(dec, rec.maximumSignificantDigits, "halfExpand") : roundAt(dec, dec.point + rec.maximumFractionDigits, "halfExpand");
    const [intText, fracText] = digitStrings(rec, dec, rec.roundingType);
    const integer = Number(intText);
    const visibleFraction = fracText.length > 0;
    if (rec.type === "ordinal") {
      if (/[1-9]/.test(fracText)) return "other";
      const mod10 = integer % 10, mod100 = integer % 100;
      if (mod10 === 1 && mod100 !== 11) return "one";
      if (mod10 === 2 && mod100 !== 12) return "two";
      if (mod10 === 3 && mod100 !== 13) return "few";
      return "other";
    }
    return integer === 1 && !visibleFraction ? "one" : "other";
  });
  defineMethod(PluralRules.prototype, "resolvedOptions", 0, function resolvedOptions() {
    const rec = slotOf(this, "PluralRules", "resolvedOptions");
    const out = { locale: rec.locale, type: rec.type, notation: "standard", minimumIntegerDigits: rec.minimumIntegerDigits };
    if (rec.roundingType === "significant") { out.minimumSignificantDigits = rec.minimumSignificantDigits; out.maximumSignificantDigits = rec.maximumSignificantDigits; }
    else { out.minimumFractionDigits = rec.minimumFractionDigits; out.maximumFractionDigits = rec.maximumFractionDigits; }
    out.pluralCategories = rec.type === "ordinal" ? ["one", "two", "few", "other"] : ["one", "other"];
    out.roundingIncrement = 1; out.roundingMode = "halfExpand"; out.roundingPriority = "auto"; out.trailingZeroDisplay = "auto";
    return out;
  });

  // ---------------------------------------------------------------- RelativeTimeFormat
  const RTF_UNITS = ["second", "minute", "hour", "day", "week", "month", "quarter", "year"];
  const decimalFormat = () => new NumberFormat();
  const RelativeTimeFormat = makeConstructor("RelativeTimeFormat", 0, function (locales, options) {
    const locale = resolveLocale(locales);
    options = coerceOptions(options);
    stringOption(options, "localeMatcher", ["lookup", "best fit"], "best fit");
    const rec = { kind: "RelativeTimeFormat", locale, numberingSystem: "latn" };
    rec.style = stringOption(options, "style", ["long", "short", "narrow"], "long");
    rec.numeric = stringOption(options, "numeric", ["always", "auto"], "always");
    rec.numberFormat = decimalFormat();
    slots.set(this, rec);
    return this;
  }, false);
  installStatics(RelativeTimeFormat, "RelativeTimeFormat");
  function relativeParts(rec, value, unit) {
    const number = Number(value);
    if (number !== number || number === Infinity || number === -Infinity) throw new RangeError("Value need to be finite number for Intl.RelativeTimeFormat.prototype.format()");
    let name = String(unit);
    if (name.endsWith("s")) name = name.slice(0, -1);
    if (!RTF_UNITS.includes(name)) throw new RangeError(`Invalid unit argument for format() '${unit}'`);
    const table = data().rtf[rec.style][name];
    if (rec.numeric === "auto") {
      const special = table.auto[Object.is(number, -0) ? "0" : String(number)];
      if (special !== undefined && Number.isFinite(number)) return [{ type: "literal", value: special }];
    }
    const past = number < 0 || Object.is(number, -0);
    const abs = Math.abs(number);
    const templates = past ? table.past : table.future;
    const template = templates[abs === 1 ? 0 : 1];
    const numberParts = rec.numberFormat.formatToParts(abs).map((p) => ({ type: p.type, value: p.value, unit: name }));
    const [before, after] = template.split("{0}");
    const out = [];
    if (before) out.push({ type: "literal", value: before });
    out.push(...numberParts);
    if (after) out.push({ type: "literal", value: after });
    return out;
  }
  defineMethod(RelativeTimeFormat.prototype, "format", 2, function format(value, unit) {
    return joinParts(relativeParts(slotOf(this, "RelativeTimeFormat", "format"), value, unit));
  });
  defineMethod(RelativeTimeFormat.prototype, "formatToParts", 2, function formatToParts(value, unit) {
    return relativeParts(slotOf(this, "RelativeTimeFormat", "formatToParts"), value, unit);
  });
  defineMethod(RelativeTimeFormat.prototype, "resolvedOptions", 0, function resolvedOptions() {
    const rec = slotOf(this, "RelativeTimeFormat", "resolvedOptions");
    return { locale: rec.locale, style: rec.style, numeric: rec.numeric, numberingSystem: "latn" };
  });

  // ---------------------------------------------------------------- ListFormat
  const ListFormat = makeConstructor("ListFormat", 0, function (locales, options) {
    const locale = resolveLocale(locales);
    options = coerceOptions(options);
    stringOption(options, "localeMatcher", ["lookup", "best fit"], "best fit");
    const rec = { kind: "ListFormat", locale };
    rec.type = stringOption(options, "type", ["conjunction", "disjunction", "unit"], "conjunction");
    rec.style = stringOption(options, "style", ["long", "short", "narrow"], "long");
    slots.set(this, rec);
    return this;
  }, false);
  installStatics(ListFormat, "ListFormat");
  function listParts(rec, list) {
    const items = [];
    if (list !== undefined) {
      for (const item of list) {
        if (typeof item !== "string") throw new TypeError("Iterable yielded " + String(item) + " which is not a string");
        items.push(item);
      }
    }
    const patterns = data().list[rec.type][rec.style];
    const out = [];
    items.forEach((item, i) => {
      if (i > 0) {
        const glue = items.length === 2 ? patterns.two : i === items.length - 1 ? patterns.end : patterns.mid;
        out.push({ type: "literal", value: glue });
      }
      out.push({ type: "element", value: item });
    });
    return out;
  }
  defineMethod(ListFormat.prototype, "format", 1, function format(list) {
    return joinParts(listParts(slotOf(this, "ListFormat", "format"), list));
  });
  defineMethod(ListFormat.prototype, "formatToParts", 1, function formatToParts(list) {
    return listParts(slotOf(this, "ListFormat", "formatToParts"), list);
  });
  defineMethod(ListFormat.prototype, "resolvedOptions", 0, function resolvedOptions() {
    const rec = slotOf(this, "ListFormat", "resolvedOptions");
    return { locale: rec.locale, type: rec.type, style: rec.style };
  });

  // ---------------------------------------------------------------- Segmenter
  const GRAPHEME = /\r\n|\p{Regional_Indicator}{2}|\P{M}(?:\p{M}|\p{Emoji_Modifier}|[\u{E0020}-\u{E007F}])*(?:\u200d\p{Extended_Pictographic}(?:\p{M}|\p{Emoji_Modifier})*)*|[\s\S]/gu;
  const WORD = new RegExp("[\\p{L}\\p{N}_](?:[\\p{L}\\p{N}_\\p{M}]|(?<=[\\p{L}])['\u2019.:](?=[\\p{L}])|(?<=\\p{N})[.,](?=\\p{N}))*|[\\s]+|" + GRAPHEME.source, "gu");
  const SENTENCE = /(?:[^.!?\n]|[.!?]+(?!["')\]\u201d\u2019]*(?:\s|$))|\.+["')\]\u201d\u2019]*\s+(?=\p{Ll}))*(?:[.!?]+["')\]\u201d\u2019]*(?:\s+|$)|\n+|$)/gu;
  const KANA_OR_HAN = /^[\p{Script=Han}\p{Script=Hiragana}]/u;
  function segmentList(rec, text) {
    const regex = rec.granularity === "grapheme" ? GRAPHEME : rec.granularity === "word" ? WORD : SENTENCE;
    regex.lastIndex = 0;
    const out = [];
    let match;
    while ((match = regex.exec(text)) !== null) {
      if (match[0] === "") { if (regex.lastIndex >= text.length) break; regex.lastIndex++; continue; }
      const entry = { segment: match[0], index: match.index, input: text };
      if (rec.granularity === "word") entry.isWordLike = /^[\p{L}\p{N}_]/u.test(match[0]) || KANA_OR_HAN.test(match[0]);
      out.push(entry);
    }
    return out;
  }
  const Segmenter = makeConstructor("Segmenter", 0, function (locales, options) {
    const locale = resolveLocale(locales);
    options = coerceOptions(options);
    stringOption(options, "localeMatcher", ["lookup", "best fit"], "best fit");
    slots.set(this, { kind: "Segmenter", locale, granularity: stringOption(options, "granularity", ["grapheme", "word", "sentence"], "grapheme") });
    return this;
  }, false);
  installStatics(Segmenter, "Segmenter");
  const SegmentsPrototype = Object.create(Object.prototype);
  defineMethod(SegmentsPrototype, "containing", 1, function containing(index) {
    const slot = slots.get(this);
    let position = Math.trunc(Number(index)) || 0;
    if (position < 0 || position >= slot.text.length) return undefined;
    return slot.list.find((entry) => position >= entry.index && position < entry.index + entry.segment.length);
  });
  defineHidden(SegmentsPrototype, Symbol.iterator, function () {
    const slot = slots.get(this);
    let i = 0;
    const iterator = { next: () => (i < slot.list.length ? { value: slot.list[i++], done: false } : { value: undefined, done: true }) };
    defineTag(iterator, "Segmenter String Iterator");
    defineHidden(iterator, Symbol.iterator, function () { return this; });
    return iterator;
  });
  defineMethod(Segmenter.prototype, "segment", 1, function segment(input) {
    const rec = slotOf(this, "Segmenter", "segment");
    const text = String(input);
    const segments = Object.create(SegmentsPrototype);
    slots.set(segments, { kind: "Segments", text, list: segmentList(rec, text) });
    return segments;
  });
  defineMethod(Segmenter.prototype, "resolvedOptions", 0, function resolvedOptions() {
    const rec = slotOf(this, "Segmenter", "resolvedOptions");
    return { locale: rec.locale, granularity: rec.granularity };
  });

  // ---------------------------------------------------------------- Locale
  const Locale = makeConstructor("Locale", 1, function (tag, options) {
    if (typeof tag !== "string" && (tag === null || typeof tag !== "object")) throw new TypeError("First argument to Intl.Locale constructor can't be empty or missing");
    const source = typeof tag === "object" && slots.get(tag)?.kind === "Locale" ? slots.get(tag).tag : String(tag);
    let canonical = canonicalTag(source);
    options = coerceOptions(options);
    const [base, ...extension] = canonical.split(/-(?=[a-wy-z0-9]-)/);
    const parts = base.split("-");
    let language = parts[0], script, region;
    for (const part of parts.slice(1)) {
      if (part.length === 4 && /^[A-Z]/.test(part) && !script) script = part;
      else if ((part.length === 2 || /^\d{3}$/.test(part)) && !region) region = part;
    }
    language = stringOption(options, "language", undefined, language);
    script = stringOption(options, "script", undefined, script);
    region = stringOption(options, "region", undefined, region);
    const rec = { kind: "Locale", language, script, region, extension: extension.join("-") };
    for (const key of ["calendar", "collation", "hourCycle", "caseFirst", "numeric", "numberingSystem"]) {
      if (options[key] !== undefined) rec[key] = String(options[key]);
    }
    rec.tag = [language, script, region].filter(Boolean).join("-") + (rec.extension ? "-" + rec.extension : "");
    slots.set(this, rec);
    return this;
  }, false);
  defineTag(Locale.prototype, "Intl.Locale");
  for (const key of ["language", "script", "region", "calendar", "collation", "hourCycle", "caseFirst", "numeric", "numberingSystem"]) {
    defineGetter(Locale.prototype, key, function () {
      const rec = slotOf(this, "Locale", key);
      return key === "numeric" ? rec.numeric === "true" : rec[key];
    });
  }
  defineGetter(Locale.prototype, "baseName", function () {
    const rec = slotOf(this, "Locale", "baseName");
    return [rec.language, rec.script, rec.region].filter(Boolean).join("-");
  });
  defineMethod(Locale.prototype, "toString", 0, function toString() { return slotOf(this, "Locale", "toString").tag; });

  // ---------------------------------------------------------------- Intl object
  const Intl = {};
  defineTag(Intl, "Intl");
  for (const [name, ctor] of [["Collator", Collator], ["DateTimeFormat", DateTimeFormat], ["ListFormat", ListFormat], ["Locale", Locale], ["NumberFormat", NumberFormat], ["PluralRules", PluralRules], ["RelativeTimeFormat", RelativeTimeFormat], ["Segmenter", Segmenter]]) {
    defineHidden(Intl, name, ctor);
  }
  defineMethod(Intl, "getCanonicalLocales", 1, function getCanonicalLocales(locales) { return canonicalizeLocaleList(locales); });
  defineHidden(global, "Intl", Intl);

  // ---------------------------------------------------------------- locale-sensitive built-ins
  const numberFormatFor = (locales, options) => (locales === undefined && options === undefined ? (defaultNumberFormat || (defaultNumberFormat = new NumberFormat())) : new NumberFormat(locales, options));
  let defaultNumberFormat;
  defineMethod(Number.prototype, "toLocaleString", 0, function toLocaleString(locales, options) {
    const value = typeof this === "number" ? this : Number.prototype.valueOf.call(this);
    return numberFormatFor(locales, options).format(value);
  });
  if (typeof BigInt === "function") {
    defineMethod(BigInt.prototype, "toLocaleString", 0, function toLocaleString(locales, options) {
      return numberFormatFor(locales, options).format(BigInt.prototype.valueOf.call(this));
    });
  }
  const formatDate = (self, locales, options, required, defaults) => {
    const ms = Date.prototype.getTime.call(self);
    if (ms !== ms) return "Invalid Date";
    const format = Object.create(DateTimeFormat.prototype);
    initDateTimeFormat(format, locales, options, required, defaults);
    return joinParts(dateParts(slots.get(format), ms));
  };
  defineMethod(Date.prototype, "toLocaleString", 0, function toLocaleString(locales, options) { return formatDate(this, locales, options, "any", "all"); });
  defineMethod(Date.prototype, "toLocaleDateString", 0, function toLocaleDateString(locales, options) { return formatDate(this, locales, options, "date", "date"); });
  defineMethod(Date.prototype, "toLocaleTimeString", 0, function toLocaleTimeString(locales, options) { return formatDate(this, locales, options, "time", "time"); });
  defineMethod(String.prototype, "localeCompare", 1, function localeCompare(that, locales, options) {
    if (this === undefined || this === null) throw new TypeError("String.prototype.localeCompare called on null or undefined");
    const collator = locales === undefined && options === undefined ? getDefaultCollator() : new Collator(locales, options);
    return collator.compare(String(this), String(that));
  });
  defineMethod(Array.prototype, "toLocaleString", 0, function toLocaleString(locales, options) {
    const list = Object(this);
    const length = Math.min(Math.max(Math.floor(Number(list.length)) || 0, 0), 2 ** 32 - 1);
    let out = "";
    for (let i = 0; i < length; i++) {
      if (i > 0) out += ",";
      const item = list[i];
      if (item !== undefined && item !== null) out += String(item.toLocaleString(locales, options));
    }
    return out;
  });
})
