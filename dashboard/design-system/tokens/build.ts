/**
 * MASC Cockpit Design System — Codegen Driver
 *
 * Reads source.ts, emits four artifacts:
 *   1. dashboard/design-system/source_styles/tokens.generated.css
 *   2. dashboard/src/styles/tokens.generated.css      (Tailwind v4 @theme)
 *   3. dashboard/src/styles/tokens.generated.ts       (Preact typed)
 *   4. dashboard/design-system/tokens/build/tokens.json (DTCG 2025.10)
 *
 * Run:  pnpm tokens:build  (from dashboard/)
 *
 * source.ts is the SSOT for the design-system preview surface; the
 * legacy hand-written tokens.css / semantic.css / colors_and_type.css
 * have been deleted (Wave 2 preview swap). The Tailwind v4 entry
 * (dashboard/src/styles/tokens.generated.css) is still consumed
 * alongside its hand-written counterparts and follows on a later wave.
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
  dtcgJson: resolve(REPO, "dashboard/design-system/tokens/build/tokens.json"),
} as const;

const HEADER_TEXT =
  "@generated DO NOT EDIT — run `pnpm tokens:build` (source: dashboard/design-system/tokens/source.ts)";

const cssHeader = `/* ${HEADER_TEXT} */\n\n`;
const tsHeader = `// ${HEADER_TEXT}\n\n`;

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

const TAILWIND_RUNTIME_ALIAS_PREFIXES: ReadonlyArray<string> = [
  "button-",
  "input-",
  "dialog-",
  "toast-",
  "state-",
  "tab-",
  "sidebar-",
  "panel-",
  "terminal-",
  "menu-",
  "menuitem-",
  "tooltip-",
];

const TAILWIND_RUNTIME_ALIAS_NAMES: ReadonlySet<string> = new Set([
  "divider",
  "divider-emphasis",
  "divider-zone",
  "scrim",
  "scrim-subtle",
  "scrim-strong",
  "scrim-brass",
  "bg-tab-sticky-hover",
]);

function shouldEmitTailwindRuntimeAlias(tok: TokenBase): boolean {
  const baseName = tailwindRuntimeBaseName(tok.name);
  return tok.kind === "color"
    && !isTailwindColorPrefixOptOut(tok.name)
    && (
      TAILWIND_RUNTIME_ALIAS_NAMES.has(baseName)
      || TAILWIND_RUNTIME_ALIAS_PREFIXES.some((prefix) => baseName.startsWith(prefix))
    );
}

function tailwindRuntimeBaseName(tokenName: string): string {
  return tokenName.startsWith("color-")
    ? tokenName.slice("color-".length)
    : tokenName;
}

function isTailwindColorPrefixOptOut(tokenName: string): boolean {
  return TAILWIND_COLOR_PREFIX_OPTOUT.has(tokenName)
    || TAILWIND_COLOR_PREFIX_OPTOUT.has(tailwindRuntimeBaseName(tokenName));
}

function buildTailwindCss(): string {
  const tailwindNamed = (tok: TokenBase): string => {
    // For Tailwind v4 to expose utilities (text-*, bg-*, border-*),
    // color tokens must be prefixed with --color-. Component/runtime
    // slots also need raw names (`var(--button-primary-bg)`,
    // `var(--dialog-panel-bg)`, ...), including when the source token
    // already has the color- prefix. Palette atoms do not; keep raw
    // alias emission scoped to those slot families.
    const isColorish = tok.kind === "color";
    const optedOut = isTailwindColorPrefixOptOut(tok.name);
    if (isColorish && !optedOut) {
      const baseName = tailwindRuntimeBaseName(tok.name);
      const colorName = `color-${baseName}`;
      const prefixed = `  --${colorName}: ${tok.value};`;
      if (shouldEmitTailwindRuntimeAlias(tok)) {
        return [
          prefixed,
          `  --${baseName}: var(--${colorName});`,
        ].join("\n");
      }
      return prefixed;
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

// 4. DTCG 2025.10 — design-tokens-format JSON
//    spec: design-tokens.github.io/community-group/format
function dtcgKindToType(kind: TokenBase["kind"]): string {
  switch (kind) {
    case "color": return "color";
    case "dimension": return "dimension";
    case "duration": return "duration";
    case "easing": return "cubicBezier";
    case "shadow": return "shadow";
    case "typography": return "fontFamily";
    case "number": return "number";
  }
}

/**
 * DTCG cubicBezier $value is required to be a 4-number array (P1x, P1y,
 * P2x, P2y). For raw easing tokens defined as `cubic-bezier(a,b,c,d)`
 * we parse the args and emit `[a, b, c, d]`. For role-tier easing
 * tokens whose value is a `var(--…)` reference (e.g.
 * `--enter-easing` → `var(--ease-out)`), we pass the string through:
 * DTCG references are still strings, just resolved to arrays at the
 * raw-tier definition site.
 */
function dtcgValue(tk: TokenBase): unknown {
  if (tk.kind !== "easing") return tk.value;
  const m = tk.value.trim().match(
    /^cubic-bezier\(\s*(-?\d*\.?\d+)\s*,\s*(-?\d*\.?\d+)\s*,\s*(-?\d*\.?\d+)\s*,\s*(-?\d*\.?\d+)\s*\)$/,
  );
  if (m === null) return tk.value;
  return [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])];
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
        $value: dtcgValue(tk),
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
        $value: dtcgValue(tk),
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
  writeFile(OUT.dtcgJson, buildDtcgJson());
  console.log("done");
}

main();
