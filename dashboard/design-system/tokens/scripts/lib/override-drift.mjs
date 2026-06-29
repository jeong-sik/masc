/**
 * Override-drift detector (shared by check-equivalence.mjs and the
 * baseline generator).
 *
 * The dashboard renders design tokens from `src/styles/tokens.generated.css`
 * (@theme block, @generated) but `src/styles/variables.css` is imported AFTER
 * it (global.css import order) and re-defines a subset of those tokens to
 * different values — so the *rendered* value diverges from the generated SSOT.
 * The tokens-drift workflow only guards source.ts ↔ generated equivalence, so
 * this generated ↔ variables.css divergence is otherwise unchecked.
 *
 * This module extracts the conflict set so the gate can ratchet it against a
 * reviewed baseline: pre-existing intentional overrides are allow-listed with
 * a reason; any NEW (or value-changed) divergence fails the gate.
 */
import { readFileSync } from "node:fs";
import postcss from "postcss";

// Collect `--token: value` declarations that determine the base (desktop)
// cascade value: decls inside top-level `:root` rules and `@theme` at-rules,
// but NOT inside `@media`/other conditional at-rules (those are responsive
// overrides, compared separately if ever needed). Last write wins, mirroring
// the CSS cascade within a single file.
export function collectBaseTokens(cssText) {
  const root = postcss.parse(cssText);
  const out = new Map();

  const insideConditional = (node) => {
    for (let p = node.parent; p && p.type !== "root"; p = p.parent) {
      if (p.type === "atrule" && p.name !== "theme") return true;
    }
    return false;
  };

  root.walkDecls((decl) => {
    if (!decl.prop.startsWith("--")) return;
    if (insideConditional(decl)) return;
    // Only count decls that live under :root or @theme (token surfaces).
    let surface = false;
    for (let p = decl.parent; p && p.type !== "root"; p = p.parent) {
      if (p.type === "atrule" && p.name === "theme") { surface = true; break; }
      if (p.type === "rule") {
        const sels = p.selector.split(",").map((s) => s.trim());
        if (sels.some((s) => s === ":root" || s.startsWith(":root"))) { surface = true; break; }
      }
    }
    if (!surface) return;
    out.set(decl.prop, decl.value.trim());
  });
  return out;
}

// Returns the sorted list of tokens defined in BOTH files with different base
// values: { token, generated, override }.
export function computeConflicts(generatedCssPath, overrideCssPath) {
  const gen = collectBaseTokens(readFileSync(generatedCssPath, "utf8"));
  const ovr = collectBaseTokens(readFileSync(overrideCssPath, "utf8"));
  const conflicts = [];
  for (const [token, ovrVal] of ovr) {
    if (!gen.has(token)) continue;
    const genVal = gen.get(token);
    if (genVal !== ovrVal) conflicts.push({ token, generated: genVal, override: ovrVal });
  }
  conflicts.sort((a, b) => a.token.localeCompare(b.token));
  return conflicts;
}
