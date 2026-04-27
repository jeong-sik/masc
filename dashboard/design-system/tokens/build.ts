/**
 * MASC Cockpit Design System — Codegen Driver
 *
 * Reads source.ts, emits six artifacts:
 *   1. dashboard/design-system/source_styles/tokens.generated.css
 *   2. dashboard/src/styles/tokens.generated.css      (Tailwind v4 @theme)
 *   3. dashboard/src/styles/tokens.generated.ts       (Preact typed)
 *   4. dashboard_bonsai/src/tokens.ml + tokens.mli    (OCaml polyvar)
 *   5. dashboard/design-system/tokens/build/tokens.json (DTCG 2025.10)
 *   6. dashboard_bonsai/static/colors_and_type.generated.css (Bonsai naming)
 *
 * Run:  pnpm tokens:build  (from dashboard/)
 *
 * source.ts is the SSOT for the design-system preview surface; the
 * legacy hand-written tokens.css / semantic.css / colors_and_type.css
 * have been deleted (Wave 2 preview swap). The Tailwind v4 entry
 * (dashboard/src/styles/tokens.generated.css) and the Bonsai outputs
 * are still consumed alongside their hand-written counterparts and
 * follow on a later wave.
 */

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { source, type TokenBase, type Theme } from "./source.js";

// ─────────────────────────────────────────────────────────────────────────
// Path resolution — relative to this file, walk up to repo root
// ─────────────────────────────────────────────────────────────────────────

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..", ".."); // <repo>/dashboard/design-system/tokens -> <repo>

const OUT = {
  previewCss: resolve(REPO, "dashboard/design-system/source_styles/tokens.generated.css"),
  tailwindCss: resolve(REPO, "dashboard/src/styles/tokens.generated.css"),
  preactTs: resolve(REPO, "dashboard/src/styles/tokens.generated.ts"),
  bonsaiMl: resolve(REPO, "dashboard_bonsai/src/tokens.ml"),
  bonsaiMli: resolve(REPO, "dashboard_bonsai/src/tokens.mli"),
  dtcgJson: resolve(REPO, "dashboard/design-system/tokens/build/tokens.json"),
  bonsaiCss: resolve(REPO, "dashboard_bonsai/static/colors_and_type.generated.css"),
} as const;

const HEADER_TEXT =
  "@generated DO NOT EDIT — run `pnpm tokens:build` (source: dashboard/design-system/tokens/source.ts)";

const cssHeader = `/* ${HEADER_TEXT} */\n\n`;
const tsHeader = `// ${HEADER_TEXT}\n\n`;
const mlHeader = `(* ${HEADER_TEXT} *)\n\n`;

function ensureDir(path: string): void {
  mkdirSync(dirname(path), { recursive: true });
}

function writeFile(path: string, content: string): void {
  ensureDir(path);
  writeFileSync(path, content, "utf8");
  console.log(`  wrote ${path.replace(REPO + "/", "")}`);
}

// ─────────────────────────────────────────────────────────────────────────
// Renderers
// ─────────────────────────────────────────────────────────────────────────

const renderTokenLine = (tok: TokenBase): string => {
  const cmt = tok.description ? `  /* ${tok.description} */` : "";
  return `  --${tok.name}: ${tok.value};${cmt}`;
};

const renderRootBlock = (toks: ReadonlyArray<TokenBase>, label: string): string => {
  const body = toks.map(renderTokenLine).join("\n");
  return `:root {\n  /* ── ${label} ── */\n${body}\n}\n`;
};

const renderThemeBlock = (theme: Theme): string => {
  const sel = theme.id === "dark-fantasy"
    ? `:root, [data-theme="dark-fantasy"]`
    : `[data-theme="${theme.id}"]`;
  const colorScheme = `  color-scheme: ${theme.mode};`;
  const body = theme.tokens.map(renderTokenLine).join("\n");
  return `${sel} {\n${colorScheme}\n${body}\n}\n`;
};

// 1. Preview CSS — :root + theme overrides, sole SSOT for preview surface
function buildPreviewCss(): string {
  const parts: string[] = [cssHeader];
  parts.push(renderRootBlock(source.raw, "Raw tokens (atomic)"));
  parts.push("\n");
  parts.push(renderRootBlock(source.semantic, "Semantic tokens (4-slot + role aliases)"));
  parts.push("\n");
  for (const theme of source.themes) {
    parts.push(renderThemeBlock(theme));
    parts.push("\n");
  }
  return parts.join("");
}

// 2. Tailwind v4 entry CSS — must use `@theme {}` at top-level (not @import-ed,
//    not nested under :root). Tailwind v4 only treats @theme in entry CSS as
//    Tailwind utilities. ref: tailwindlabs/tailwindcss#18966
//
// Legacy color names that consumers reference verbatim (e.g.
// `var(--bad-light)`) opt out of the implicit --color- prefix that
// the rule below applies to color-kind tokens. Without this list a
// token named `bad-light` would emit `--color-bad-light` and the
// 130+ component sites referencing `var(--bad-light)` would fall
// through to CSS `initial`.
const TAILWIND_COLOR_PREFIX_OPTOUT: ReadonlySet<string> = new Set([
  "bad-light",
  "warn-bright",
]);

function buildTailwindCss(): string {
  const tailwindNamed = (tok: TokenBase): string => {
    // For Tailwind v4 to expose utilities (text-*, bg-*, border-*),
    // color tokens must be prefixed with --color-. We re-prefix only
    // those that aren't already in --color-* form. Non-color tokens
    // pass through with their raw name.
    const isColorish = tok.kind === "color";
    const alreadyColorPrefixed = tok.name.startsWith("color-");
    const optedOut = TAILWIND_COLOR_PREFIX_OPTOUT.has(tok.name);
    if (isColorish && !alreadyColorPrefixed && !optedOut) {
      return `  --color-${tok.name}: ${tok.value};`;
    }
    return `  --${tok.name}: ${tok.value};`;
  };
  const all = [...source.raw, ...source.semantic];
  const body = all.map(tailwindNamed).join("\n");
  return `${cssHeader}@theme {\n${body}\n}\n`;
}

// 3. Preact typed const + literal-string union
function buildPreactTs(): string {
  const all: TokenBase[] = [...source.raw, ...source.semantic];
  // De-dupe by name (semantic and raw must not collide; this is a guard).
  const seen = new Set<string>();
  const dedup = all.filter((tk) => {
    if (seen.has(tk.name)) return false;
    seen.add(tk.name);
    return true;
  });
  const entries = dedup.map((tk) => {
    const camel = tk.name.replace(/-(.)/g, (_, c: string) => c.toUpperCase());
    return `  ${JSON.stringify(camel)}: { name: ${JSON.stringify(`--${tk.name}`)}, value: ${JSON.stringify(tk.value)}, tier: ${JSON.stringify(tk.tier)}, kind: ${JSON.stringify(tk.kind)} }`;
  });
  return `${tsHeader}export const TOKENS = {\n${entries.join(",\n")},\n} as const;\n\nexport type TokenName = keyof typeof TOKENS;\nexport type TokenVar = typeof TOKENS[TokenName]["name"];\n\n/** \`var(--token-name)\` for the given token. */\nexport const tokenVar = (k: TokenName): string => \`var(\${TOKENS[k].name})\`;\n`;
}

// 4. OCaml polyvar — tokens.ml + tokens.mli
//    Pattern: `type semantic = [\`Color_bg_page | ...]` plus `var_of`
//    returning the `var(--name)` string.
//    polyvar tag rules: identifier-like, must start with [A-Z]; we
//    transform `bg-0` -> `Bg_0` and `color-bg-page` -> `Color_bg_page`.
function tokenToPolyvarTag(name: string): string {
  return name
    .replace(/[^a-zA-Z0-9]/g, "_")
    .replace(/^([a-z])/, (_, c: string) => c.toUpperCase())
    .replace(/^([0-9])/, "_$1"); // start with letter; if name starts with digit, prepend _
}

function buildBonsaiMli(): string {
  const all: TokenBase[] = [...source.raw, ...source.semantic];
  const seen = new Set<string>();
  const dedup = all.filter((tk) => {
    if (seen.has(tk.name)) return false;
    seen.add(tk.name);
    return true;
  });
  const constructors = dedup.map((tk) => `  | \`${tokenToPolyvarTag(tk.name)}`);
  return `${mlHeader}(** MASC Cockpit design tokens — strongly-typed accessors for ppx_css.

    Use [var_of] to obtain a CSS [var(--...)] reference:
    {[
      let style = [%css {|
        background: %{Tokens.var_of \`Color_bg_page};
        color:      %{Tokens.var_of \`Color_fg_primary};
      |}]
    ]}
*)

type semantic =
  [
${constructors.join("\n")}
  ]

(** Returns ["var(--name)"] for the given token. *)
val var_of : semantic -> string

(** Raw CSS variable name without the leading [--]. *)
val name_of : semantic -> string
`;
}

function buildBonsaiMl(): string {
  const all: TokenBase[] = [...source.raw, ...source.semantic];
  const seen = new Set<string>();
  const dedup = all.filter((tk) => {
    if (seen.has(tk.name)) return false;
    seen.add(tk.name);
    return true;
  });
  const constructors = dedup.map((tk) => `  | \`${tokenToPolyvarTag(tk.name)}`);
  const arms = dedup.map((tk) => `  | \`${tokenToPolyvarTag(tk.name)} -> ${JSON.stringify(tk.name)}`);
  return `${mlHeader}type semantic =
  [
${constructors.join("\n")}
  ]

let name_of = function
${arms.join("\n")}

let var_of t = "var(--" ^ name_of t ^ ")"
`;
}

// 6. Bonsai-side colors_and_type.generated.css — uses Bonsai naming
//    (--bg-deep / --accent-brass / --space-1 / --status-ok). Two themes
//    only per user decision: dark-fantasy (canonical, on :root) + paper
//    (light, on [data-theme="paper"]). cyberpunk / terminal / parchment
//    are intentionally archived (Wave 2 Friend-2C will move them to
//    static/themes/archive/).
//
//    Layout per :root block:
//      1. Bonsai theme-invariant raw (radius, space, scrollbar)
//      2. Bonsai-distinct font stacks (per SPEC §6 divergence)
//      3. Bonsai theme-invariant role defaults (shadow-card, etc.)
//      4. dark-fantasy theme tokens (bg-deep / text-* / accent-* / status-* / t-*)
//      5. Bonsai semantic aliases (color-bg-page → var(--bg-deep), …)
//
//    The [data-theme="paper"] block contains the paper raw palette
//    (paper-N / ink-N / forest / brass / brick / *-fill) followed by
//    the Bonsai-name overrides (--bg-deep: var(--paper) etc.).
function buildBonsaiColorsAndTypeCss(): string {
  const rawByName = new Map(source.raw.map((tk) => [tk.name, tk] as const));
  const semanticByName = new Map(source.semantic.map((tk) => [tk.name, tk] as const));

  const lookupOrThrow = (
    name: string, where: Map<string, TokenBase>, label: string,
  ): TokenBase => {
    const tk = where.get(name);
    if (!tk) throw new Error(`bonsai codegen: ${label} token --${name} not found in source.ts`);
    return tk;
  };

  const invariantRaw = source.bonsai.invariantRawNames.map(
    (n) => lookupOrThrow(n, rawByName, "raw"),
  );
  const invariantRole = source.bonsai.invariantRoleNames.map(
    (n) => lookupOrThrow(n, semanticByName, "role"),
  );

  const darkFantasy = source.themes.find((th) => th.id === "dark-fantasy");
  const paper = source.themes.find((th) => th.id === "paper");
  if (!darkFantasy) throw new Error("bonsai codegen: dark-fantasy theme missing");
  if (!paper) throw new Error("bonsai codegen: paper theme missing");

  const renderSection = (label: string, toks: ReadonlyArray<TokenBase>): string => {
    if (toks.length === 0) return "";
    const body = toks.map(renderTokenLine).join("\n");
    return `  /* ── ${label} ── */\n${body}\n`;
  };

  // :root + [data-theme="dark-fantasy"] — canonical block
  const rootSelector = `:root,\n[data-theme="dark-fantasy"]`;
  const rootBody = [
    "  color-scheme: dark;",
    renderSection("Theme-invariant raw (radius, space, scrollbar)", invariantRaw),
    renderSection("Font stacks (bonsai divergence — JetBrains Mono / Cinzel)",
      [...source.bonsai.fontOverrides]),
    renderSection("Theme-invariant role defaults (shadows)", invariantRole),
    renderSection("Dark Fantasy raw (visceral · decay-forward)", [...darkFantasy.tokens]),
    renderSection("Bonsai semantic aliases (SPEC v0.1 §3.1-3.5)",
      [...source.bonsai.aliases]),
  ].filter((s) => s.length > 0).join("\n");
  const rootBlock = `${rootSelector} {\n${rootBody}}\n`;

  // [data-theme="paper"] — light theme
  const paperOverrides = source.bonsai.themeOverrides.paper ?? [];
  const paperBody = [
    "  color-scheme: light;",
    renderSection("Paper / Ink raw palette", [...paper.tokens]),
    renderSection("Bonsai-name overrides (paper colorway)",
      [...paperOverrides]),
  ].filter((s) => s.length > 0).join("\n");
  const paperBlock = `[data-theme="paper"] {\n${paperBody}}\n`;

  return `${cssHeader}${rootBlock}\n${paperBlock}`;
}

// 5. DTCG 2025.10 — design-tokens-format JSON
//    spec: design-tokens.github.io/community-group/format
function dtcgKindToType(kind: TokenBase["kind"]): string {
  switch (kind) {
    case "color": return "color";
    case "dimension": return "dimension";
    case "duration": return "duration";
    case "easing": return "cubicBezier"; // DTCG uses cubicBezier; we pass through string for cubic-bezier()
    case "shadow": return "shadow";
    case "typography": return "fontFamily";
    case "number": return "number";
  }
}

function buildDtcgJson(): string {
  type DtcgGroup = Record<string, unknown>;
  const root: DtcgGroup = {};
  const tiersToEmit = [
    { tier: "raw", group: "raw", toks: source.raw },
    { tier: "semantic", group: "semantic", toks: source.semantic },
  ] as const;
  for (const { group, toks } of tiersToEmit) {
    const g: DtcgGroup = {};
    for (const tk of toks) {
      g[tk.name] = {
        $type: dtcgKindToType(tk.kind),
        $value: tk.value,
        $description: tk.description ?? undefined,
      };
    }
    root[group] = g;
  }
  const themes: DtcgGroup = {};
  for (const theme of source.themes) {
    const g: DtcgGroup = {};
    for (const tk of theme.tokens) {
      g[tk.name] = {
        $type: dtcgKindToType(tk.kind),
        $value: tk.value,
        $description: tk.description ?? undefined,
      };
    }
    themes[theme.id] = { $extensions: { mode: theme.mode }, ...g };
  }
  root.themes = themes;
  return JSON.stringify(root, null, 2) + "\n";
}

// ─────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────

function main(): void {
  console.log("MASC tokens codegen");
  writeFile(OUT.previewCss, buildPreviewCss());
  writeFile(OUT.tailwindCss, buildTailwindCss());
  writeFile(OUT.preactTs, buildPreactTs());
  writeFile(OUT.bonsaiMli, buildBonsaiMli());
  writeFile(OUT.bonsaiMl, buildBonsaiMl());
  writeFile(OUT.dtcgJson, buildDtcgJson());
  writeFile(OUT.bonsaiCss, buildBonsaiColorsAndTypeCss());
  console.log("done");
}

main();
