#!/usr/bin/env node
/**
 * MASC Cockpit Design System — equivalence check
 *
 * Verifies generated CSS conforms to canonical invariants:
 *
 *   1. Status canon — --ok/--warn/--err/--info hex values pinned to
 *      #6b9e6b/#c9a24a/#c46a5a/#6a8eb0 (warm dim palette per SPEC §3.5).
 *   2. Keeper 12-slot palette is within ΔE < 2 (CIE2000) of the
 *      OkLCH-generated palette (L=0.68, C=0.09, H=(i-1)*30).
 *
 * Token name set superset is enforced by the idempotent build gate
 * (tokens-drift workflow Gate 1) — re-running tokens:build with no
 * source change must produce zero diff. That makes a separate name-set
 * check redundant here.
 *
 * Exits 0 only on full pass. Prints diffs to stderr on failure.
 *
 * Usage:  pnpm tokens:check
 */

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import postcss from "postcss";
import { formatHex, parseHex, differenceCiede2000 } from "culori";
import { computeConflicts } from "./lib/override-drift.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..", "..", "..");

const GENERATED_CSS = resolve(REPO, "dashboard/design-system/source_styles/tokens.generated.css");

// Override-drift gate: the app imports src/styles/tokens.generated.css (@theme)
// then src/styles/variables.css (:root), which re-defines a subset of tokens to
// different RENDERED values. The drift workflow only guards source.ts ↔
// generated, so this divergence is otherwise unchecked. We ratchet it against a
// reviewed baseline — NEW divergence, a value change, or a stale entry all fail.
const APP_GENERATED_CSS = resolve(REPO, "dashboard/src/styles/tokens.generated.css");
const APP_VARIABLES_CSS = resolve(REPO, "dashboard/src/styles/variables.css");
const OVERRIDE_BASELINE = resolve(HERE, "..", "override-drift-baseline.json");

const STATUS_CANON = {
  ok: "#6b9e6b",
  warn: "#c9a24a",
  err: "#c46a5a",
  info: "#6a8eb0",
};

function collectRootTokens(cssText) {
  const root = postcss.parse(cssText);
  const out = new Map();
  root.walkRules((rule) => {
    const selectors = rule.selector.split(",").map((s) => s.trim());
    if (!selectors.some((s) => s === ":root" || s.startsWith(":root"))) return;
    rule.walkDecls((decl) => {
      if (decl.prop.startsWith("--")) {
        const name = decl.prop.slice(2);
        out.set(name, decl.value.trim());
      }
    });
  });
  return out;
}

function toHex6(value) {
  const m = /^#([0-9a-fA-F]{6})$/.exec(value);
  if (!m) return null;
  return `#${m[1].toLowerCase()}`;
}

function expectedKeeperHex(slot) {
  const c = { mode: "oklch", l: 0.68, c: 0.09, h: (slot - 1) * 30 };
  return formatHex(c);
}

function checkStatusCanon(genMap) {
  const errors = [];
  for (const [name, expected] of Object.entries(STATUS_CANON)) {
    const got = genMap.get(name);
    const gotHex = got ? toHex6(got) : null;
    if (gotHex !== expected) {
      errors.push(`status canon drift: --${name} expected ${expected}, got ${got ?? "<missing>"}`);
    }
  }
  return errors;
}

function checkKeeperPalette(genMap) {
  const errors = [];
  for (let i = 1; i <= 12; i++) {
    const value = genMap.get(`k-${i}`);
    if (!value) {
      errors.push(`keeper slot --k-${i} missing in generated`);
      continue;
    }
    const gotHex = toHex6(value);
    if (!gotHex) {
      errors.push(`keeper slot --k-${i} unparseable: ${value}`);
      continue;
    }
    const expectedHex = expectedKeeperHex(i);
    if (!expectedHex) {
      errors.push(`OkLCH formatting failed for slot ${i}`);
      continue;
    }
    const got = parseHex(gotHex);
    const expected = parseHex(expectedHex);
    const dE = differenceCiede2000()(got, expected);
    if (dE >= 2) {
      errors.push(`keeper slot --k-${i} ΔE=${dE.toFixed(3)} >= 2  got=${gotHex} expected=${expectedHex}`);
    }
  }
  return errors;
}

function checkOverrideDrift() {
  const errors = [];
  let baseline;
  try {
    baseline = JSON.parse(readFileSync(OVERRIDE_BASELINE, "utf8"));
  } catch (e) {
    return [`override-drift baseline unreadable: ${OVERRIDE_BASELINE} (${e.message})`];
  }
  const allowed = new Map(Object.entries(baseline.overrides ?? {}));

  let conflicts;
  try {
    conflicts = computeConflicts(APP_GENERATED_CSS, APP_VARIABLES_CSS);
  } catch (e) {
    return [`override-drift scan failed: ${e.message}`];
  }
  const current = new Map(conflicts.map((c) => [c.token, c]));

  // NEW divergence or a value change on an allow-listed entry.
  for (const c of conflicts) {
    const entry = allowed.get(c.token);
    if (!entry) {
      errors.push(
        `NEW override drift: ${c.token} generated=${c.generated} variables.css=${c.override} — ` +
          `add a reviewed entry to override-drift-baseline.json (with a reason) or reconcile the value`,
      );
    } else if (entry.generated !== c.generated || entry.override !== c.override) {
      errors.push(
        `override drift value changed: ${c.token} now generated=${c.generated} variables.css=${c.override}, ` +
          `baseline had generated=${entry.generated} variables.css=${entry.override} — re-review and update the baseline`,
      );
    }
  }
  // Stale baseline entry — the divergence is gone, so the entry must be removed
  // to keep the baseline honest (prevents the allow-list from rotting open).
  for (const token of allowed.keys()) {
    if (!current.has(token)) {
      errors.push(`stale baseline entry: ${token} no longer diverges — remove it from override-drift-baseline.json`);
    }
  }
  return errors;
}

function main() {
  let genText;
  try {
    genText = readFileSync(GENERATED_CSS, "utf8");
  } catch (e) {
    console.error(`generated not found: ${GENERATED_CSS} — run \`pnpm tokens:build\` first`);
    process.exit(2);
  }

  const genMap = collectRootTokens(genText);

  let failed = false;

  const statusErrors = checkStatusCanon(genMap);
  if (statusErrors.length > 0) {
    console.error(`[FAIL] status canon mismatch:`);
    for (const e of statusErrors) console.error(`  - ${e}`);
    failed = true;
  } else {
    console.log(`[OK] status canon (--ok/--warn/--err/--info) pinned`);
  }

  const keeperErrors = checkKeeperPalette(genMap);
  if (keeperErrors.length > 0) {
    console.error(`[FAIL] keeper palette ΔE check:`);
    for (const e of keeperErrors) console.error(`  - ${e}`);
    failed = true;
  } else {
    console.log(`[OK] keeper 12-slot palette ΔE < 2 vs OkLCH(L=68, C=0.09, H=i*30)`);
  }

  const overrideErrors = checkOverrideDrift();
  if (overrideErrors.length > 0) {
    console.error(`[FAIL] generated ↔ variables.css override drift:`);
    for (const e of overrideErrors) console.error(`  - ${e}`);
    failed = true;
  } else {
    console.log(`[OK] generated ↔ variables.css override drift matches reviewed baseline`);
  }

  if (failed) {
    console.error("\nequivalence check FAILED");
    process.exit(1);
  }
  console.log("\nequivalence check passed");
}

main();
