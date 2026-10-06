// Evaluated for every exec cell as `(function (global, load) { ... })`. Installs light stand-ins
// for `Intl` and for the locale-sensitive built-ins that bring in the real implementation
// (intl.js, ~60 KB of source) on first use, so a script that never touches them does not pay for
// compiling it. `load` evaluates intl.js, which replaces `Intl` and every method listed below.
(function (global, load) {
  "use strict";

  const targets = [
    [Number.prototype, "toLocaleString", 0],
    [BigInt.prototype, "toLocaleString", 0],
    [Date.prototype, "toLocaleString", 0],
    [Date.prototype, "toLocaleDateString", 0],
    [Date.prototype, "toLocaleTimeString", 0],
    [String.prototype, "localeCompare", 1],
    [Array.prototype, "toLocaleString", 0],
  ];
  const real = new Map();
  let state = 0; // 0: not loaded, 1: loading, 2: loaded

  function ensure() {
    if (state === 2) return;
    if (state === 1) throw new Error("Intl is still being initialized");
    state = 1;
    try {
      load();
      targets.forEach(([owner, name], i) => real.set(stubs[i], owner[name]));
      state = 2;
    } catch (error) {
      state = 0;
      throw error;
    }
  }

  const stubs = targets.map(([owner, name, length]) => {
    // A method (not a constructor) named like the built-in. After loading, a stub that a script
    // kept a reference to forwards to the real method.
    const stub = {
      [name](...args) {
        ensure();
        return real.get(stub).apply(this, args);
      },
    }[name];
    Object.defineProperty(stub, "length", { value: length, configurable: true });
    Object.defineProperty(owner, name, { value: stub, writable: true, configurable: true, enumerable: false });
    return stub;
  });

  Object.defineProperty(global, "Intl", {
    // ensure() replaces this accessor with the data property intl.js defines.
    get() { ensure(); return global.Intl; },
    set(value) { Object.defineProperty(global, "Intl", { value, writable: true, configurable: true, enumerable: false }); },
    configurable: true,
    enumerable: false,
  });
})
