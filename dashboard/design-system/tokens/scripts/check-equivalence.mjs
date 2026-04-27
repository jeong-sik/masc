#!/usr/bin/env node
/**
 * MASC Cockpit Design System — equivalence check
 *
 * Verifies that the generated preview CSS matches the original
 * source_styles/tokens.css on three axes:
 *
 *   1. Raw token name set equality (every --bg-*, --fg-*, --line-*,
 *      --brass-*, status, --k-*, --p-*, etc. exists in both).
 *   2. Status canon — --ok/--warn/--err/--info hex values are pinned
 *      to #6b9e6b/#c9a24a/#c46a5a/#6a8eb0.
 *   3. Keeper 12-slot palette is within ΔE < 2 (CIE2000) of the
 *      OkLCH-generated palette.
 *
 * Exits 0 only on full pass. Prints diffs to stderr on failure.
 *
 * Usage:  pnpm tokens:check
 */

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import postcss from "postcss";
import { oklch, formatHex, parseHex, differenceCiede2000 } from "culori";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..", "..", "..");

const SOURCE_CSS = resolve(REPO, "dashboard/design-system/source_styles/tokens.css");
const GENERATED_CSS = resolve(REPO, "dashboard/design-system/source_styles/tokens.generated.css");

const STATUS_CANON = {
  ok: "#6b9e6b",
  warn: "#c9a24a",
  err: "#c46a5a",
  info: "#6a8eb0",
};

// ─────────────────────────────────────────────────────────────────────────
// Parse helpers
// ─────────────────────────────────────────────────────────────────────────

/**
 * Walk a CSS file, collect every --token in any `:root` rule.
 * Returns { name -> value } map (last write wins, mirroring browser CSSOM).
 */
function collectRootTokens(cssText) {
  const root = postcss.parse(cssText);
  const out = new Map();
  root.walkRules((rule) => {
    // We want any rule whose selector contains :root (covers
    // `:root`, `:root, [data-theme="dark-fantasy"]`, etc.)
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

// ─────────────────────────────────────────────────────────────────────────
// Checks
// ─────────────────────────────────────────────────────────────────────────

function checkNameSet(srcMap, genMap) {
  // Generated may have a SUPERSET of source names (we add e.g. derived
  // semantic colors and themed token blocks not present at :root in the
  // legacy file). What matters is: every token NAME in source must exist
  // in generated. The reverse is not required for the additive scaffold.
  const missing = [];
  for (const name of srcMap.keys()) {
    if (!genMap.has(name)) missing.push(name);
  }
  return missing;
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

// ─────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────

function main() {
  let srcText, genText;
  try {
    srcText = readFileSync(SOURCE_CSS, "utf8");
  } catch (e) {
    console.error(`source not found: ${SOURCE_CSS}`);
    process.exit(2);
  }
  try {
    genText = readFileSync(GENERATED_CSS, "utf8");
  } catch (e) {
    console.error(`generated not found: ${GENERATED_CSS} — run \`pnpm tokens:build\` first`);
    process.exit(2);
  }

  const srcMap = collectRootTokens(srcText);
  const genMap = collectRootTokens(genText);

  let failed = false;

  const missingNames = checkNameSet(srcMap, genMap);
  if (missingNames.length > 0) {
    console.error(`[FAIL] ${missingNames.length} source tokens missing in generated:`);
    for (const n of missingNames) console.error(`  - --${n}`);
    failed = true;
  } else {
    console.log(`[OK] every source token name (${srcMap.size}) exists in generated`);
  }

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

  if (failed) {
    console.error("\nequivalence check FAILED");
    process.exit(1);
  }
  console.log("\nequivalence check passed");
}

main();
