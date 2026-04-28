/**
 * MASC Cockpit Design System — Token Source (SSOT)
 *
 * Authoring source for the codegen pipeline. Edit this file, then run
 * `pnpm tokens:build` to emit the four downstream artifacts:
 *   - dashboard/design-system/source_styles/tokens.generated.css
 *   - dashboard/src/styles/tokens.generated.css      (Tailwind v4 @theme)
 *   - dashboard/src/styles/tokens.generated.ts       (Preact typed const)
 *   - dashboard_bonsai/src/tokens.ml + .mli          (OCaml polyvar)
 *
 * Design tier mapping (matches SPEC.md §3 Token Taxonomy):
 *   - tier:'raw'      — atomic values; never reference another token
 *   - tier:'semantic' — 4-slot status / role aliases derived from raw
 *   - tier:'role'     — component-facing semantic (state, divider, etc.)
 *
 * Type kind:
 *   - 'color'        — hex, rgb-triplet, or rgb()/var() expression
 *   - 'dimension'    — px, em, %, calc()
 *   - 'typography'   — font shorthand or stack
 *   - 'duration'     — ms
 *   - 'easing'       — cubic-bezier()
 *   - 'shadow'       — box-shadow value
 *   - 'number'       — unitless scalar
 *
 * Keeper 12-slot palette is generated algorithmically (OkLCH L=68 C=0.09,
 * H stride 30°). Status 4-slot semantics are derived from raw. The status
 * canon (--ok/--warn/--err/--info) is locked at #6b9e6b/#c9a24a/#c46a5a/
 * #6a8eb0; check-equivalence.mjs enforces this against tokens.css.
 */

import { oklch, formatHex, type Color } from "culori";

// ─────────────────────────────────────────────────────────────────────────
// Types — discriminated union per tier × kind
// ─────────────────────────────────────────────────────────────────────────

export type Tier = "raw" | "semantic" | "role";
export type Kind =
  | "color"
  | "dimension"
  | "typography"
  | "duration"
  | "easing"
  | "shadow"
  | "number";

export interface TokenBase {
  readonly name: string; // CSS custom property name without leading --
  readonly value: string; // CSS value text (already formatted)
  readonly tier: Tier;
  readonly kind: Kind;
  readonly description?: string;
}

export interface Theme {
  readonly id: string; // e.g. "dark-fantasy", "paper"
  readonly mode: "dark" | "light";
  readonly tokens: ReadonlyArray<TokenBase>;
}

// ─────────────────────────────────────────────────────────────────────────
// Helpers — keep authoring concise without sacrificing types
// ─────────────────────────────────────────────────────────────────────────

const t = (
  name: string,
  value: string,
  tier: Tier,
  kind: Kind,
  description?: string,
): TokenBase => ({ name, value, tier, kind, description });

// rgb-triplet (space separated) for use inside `rgb(var(--x) / .35)`
const rgbTriplet = (hex: string): string => {
  const m = /^#([0-9a-f]{6})$/i.exec(hex);
  if (!m) throw new Error(`bad hex: ${hex}`);
  const n = parseInt(m[1], 16);
  return `${(n >> 16) & 0xff} ${(n >> 8) & 0xff} ${n & 0xff}`;
};

// ─────────────────────────────────────────────────────────────────────────
// Keeper 12-slot palette — algorithmic OkLCH (L=68, C=0.09, H=i*30)
// ─────────────────────────────────────────────────────────────────────────

const KEEPER_HUE_NAMES = [
  "rose", "clay", "amber", "olive", "moss", "jade",
  "teal", "cyan", "sky", "iris", "violet", "mauve",
] as const;

function generateKeeperSlot(slot: number): { hex: string; hue: number; name: string } {
  // slot is 1..12
  const hue = (slot - 1) * 30;
  const c: Color = { mode: "oklch", l: 0.68, c: 0.09, h: hue };
  const hex = formatHex(c);
  if (!hex) throw new Error(`oklch -> hex failed for slot ${slot}`);
  return { hex, hue, name: KEEPER_HUE_NAMES[slot - 1] };
}

// ─────────────────────────────────────────────────────────────────────────
// Raw tokens — atomic values
// ─────────────────────────────────────────────────────────────────────────

export const raw: ReadonlyArray<TokenBase> = (() => {
  const out: TokenBase[] = [];

  // Surfaces — almost-black with 2-3% warm tint
  out.push(t("bg-0", "#0c0b08", "raw", "color", "page bg"));
  out.push(t("bg-1", "#141210", "raw", "color", "topbar / composer"));
  out.push(t("bg-2", "#1a1815", "raw", "color", "panel surface"));
  out.push(t("bg-3", "#211e1a", "raw", "color", "elevated card"));
  out.push(t("bg-4", "#2a2621", "raw", "color", "hover / active row"));

  // Hairlines — warm neutral
  out.push(t("line-1", "#2a2520", "raw", "color", "default border"));
  out.push(t("line-2", "#3a332c", "raw", "color", "emphasized border"));
  out.push(t("line-3", "#4a4137", "raw", "color", "divider between zones"));

  // Text — 4 steps, never pure white
  out.push(t("fg-1", "#f0e9dc", "raw", "color", "primary"));
  out.push(t("fg-2", "#b8ad9a", "raw", "color", "secondary"));
  out.push(t("fg-3", "#7a7065", "raw", "color", "tertiary / labels"));
  out.push(t("fg-4", "#4a453e", "raw", "color", "disabled / placeholder"));

  // Brass — the ONE accent (running state, focused row, primary button)
  out.push(t("brass-1", "#d4a14a", "raw", "color", "primary brass"));
  out.push(t("brass-2", "#b8843a", "raw", "color"));
  out.push(t("brass-3", "#8a5f28", "raw", "color"));
  out.push(t("brass-glow", rgbTriplet("#d4a14a"), "raw", "color", "rgb triplet for alpha"));

  // Status — muted, desaturated. Never neon. Locked canon.
  out.push(t("ok", "#6b9e6b", "raw", "color", "done, success"));
  out.push(t("warn", "#c9a24a", "raw", "color", "at-risk, degraded"));
  out.push(t("err", "#c46a5a", "raw", "color", "failed, blocker"));
  out.push(t("info", "#6a8eb0", "raw", "color", "pending, queued"));
  out.push(t("idle", "#6a6a6a", "raw", "color", "silent, noop"));
  out.push(t("stalled", "#8a6aa0", "raw", "color", "stalled, drift"));

  // Status glow rgb triplets
  out.push(t("ok-glow", rgbTriplet("#6b9e6b"), "raw", "color"));
  out.push(t("warn-glow", rgbTriplet("#c9a24a"), "raw", "color"));
  out.push(t("err-glow", rgbTriplet("#c46a5a"), "raw", "color"));
  out.push(t("info-glow", rgbTriplet("#6a8eb0"), "raw", "color"));
  out.push(t("stalled-glow", rgbTriplet("#8a6aa0"), "raw", "color"));

  // Keeper 12-slot OkLCH spectrum
  for (let i = 1; i <= 12; i++) {
    const { hex, hue, name } = generateKeeperSlot(i);
    out.push(t(`k-${i}`, hex, "raw", "color", `H=${String(hue).padStart(3, "0")} · ${name}`));
  }
  for (let i = 1; i <= 12; i++) {
    const { hex } = generateKeeperSlot(i);
    out.push(t(`k-${i}-glow`, rgbTriplet(hex), "raw", "color"));
  }

  // Provider palette
  out.push(t("p-anthropic", "#c9a88a", "raw", "color", "warm sand"));
  out.push(t("p-moonshot", "#8a98c9", "raw", "color", "cool indigo"));
  out.push(t("p-openai", "#6b9e8e", "raw", "color", "muted teal"));
  out.push(t("p-xai", "#a896a0", "raw", "color", "mauve"));

  // Type scale — tabular, compact
  out.push(t("font-sans",
    `ui-sans-serif, -apple-system, "SF Pro Text", "Inter", system-ui, sans-serif`,
    "raw", "typography"));
  out.push(t("font-mono",
    `ui-monospace, "SF Mono", "JetBrains Mono", Menlo, monospace`,
    "raw", "typography"));

  for (const px of [9, 10, 11, 12, 13, 14, 16, 20, 28, 36]) {
    out.push(t(`fs-${px}`, `${px}px`, "raw", "dimension"));
  }

  out.push(t("lh-tight", "1.2", "raw", "number"));
  out.push(t("lh-body", "1.45", "raw", "number"));
  out.push(t("lh-loose", "1.6", "raw", "number"));

  out.push(t("fw-reg", "400", "raw", "number"));
  out.push(t("fw-med", "500", "raw", "number"));
  out.push(t("fw-semi", "600", "raw", "number"));
  out.push(t("fw-bold", "700", "raw", "number"));

  out.push(t("track-tight", "-0.01em", "raw", "dimension"));
  out.push(t("track-normal", "0", "raw", "dimension"));
  out.push(t("track-wide", "0.04em", "raw", "dimension"));
  out.push(t("track-caps", "0.08em", "raw", "dimension"));

  // Spacing — 4px atomic scale
  for (const [step, px] of [
    [1, 4], [2, 8], [3, 12], [4, 16], [5, 20], [6, 24], [7, 32], [8, 40],
  ] as const) {
    out.push(t(`sp-${step}`, `${px}px`, "raw", "dimension"));
  }
  out.push(t("sp-0h", "2px", "raw", "dimension", "half-step gutter"));

  // Radius
  out.push(t("r-1", "3px", "raw", "dimension"));
  out.push(t("r-2", "5px", "raw", "dimension"));
  out.push(t("r-3", "8px", "raw", "dimension"));

  // Motion — durations + easings
  out.push(t("t-fast", "120ms", "raw", "duration"));
  out.push(t("t-med", "200ms", "raw", "duration"));
  out.push(t("t-slow", "360ms", "raw", "duration"));
  out.push(t("t-xslow", "600ms", "raw", "duration"));

  out.push(t("ease", "cubic-bezier(.2, .7, .2, 1)", "raw", "easing"));
  out.push(t("ease-out", "cubic-bezier(.16, 1, .3, 1)", "raw", "easing"));
  out.push(t("ease-in", "cubic-bezier(.7, 0, .84, 0)", "raw", "easing"));
  out.push(t("ease-inout", "cubic-bezier(.65, 0, .35, 1)", "raw", "easing"));
  out.push(t("ease-spring", "cubic-bezier(.34, 1.56, .64, 1)", "raw", "easing"));

  // Bonsai 8-step structural spacing (theme-invariant, parallel to --sp-*)
  for (const [step, px] of [
    [1, 4], [2, 8], [3, 12], [4, 16], [5, 24], [6, 32], [7, 48], [8, 64],
  ] as const) {
    out.push(t(`space-${step}`, `${px}px`, "raw", "dimension"));
  }

  // Bonsai radius primitives (cyberpunk + terminal flatten xs/sm/md to 0)
  out.push(t("radius-xs", "2px", "raw", "dimension"));
  out.push(t("radius-sm", "4px", "raw", "dimension"));
  out.push(t("radius-md", "6px", "raw", "dimension"));
  out.push(t("radius-lg", "12px", "raw", "dimension"));
  out.push(t("radius-pill", "999px", "raw", "dimension"));

  // Bonsai font stacks (cyberpunk + terminal collapse to mono)
  out.push(t("font-display",
    `'Cinzel', 'Noto Sans KR', 'EB Garamond', serif`,
    "raw", "typography"));
  out.push(t("font-body",
    `'EB Garamond', 'Noto Sans KR', Georgia, serif`,
    "raw", "typography"));
  out.push(t("font-ui",
    `'Noto Sans KR', 'IBM Plex Sans KR', -apple-system, sans-serif`,
    "raw", "typography"));

  // Scrollbar primitives — bonsai surface uses these via fallback chain
  out.push(t("scrollbar-thumb", "#2a1f1a", "raw", "color"));
  out.push(t("scrollbar-thumb-hover", "#3d2e22", "raw", "color"));

  // Density scale — body[data-density="..."] flips this scalar; role
  // tokens (--sp-inline / --row-h / --ctrl-h*) read from it.
  out.push(t("density", "1", "raw", "number",
    "0.85 compact · 1 normal · 1.15 comfortable"));

  // 8px baseline grid (alignment rhythm)
  out.push(t("grid-unit", "8px", "raw", "dimension"));
  out.push(t("grid-half", "4px", "raw", "dimension"));
  out.push(t("grid-dbl", "16px", "raw", "dimension"));

  // Zone heights (cockpit grid rows)
  out.push(t("h-topbar", "36px", "raw", "dimension"));
  out.push(t("h-ticker", "32px", "raw", "dimension"));
  out.push(t("h-kpi", "56px", "raw", "dimension"));
  out.push(t("h-lifeline", "28px", "raw", "dimension"));
  out.push(t("h-composer", "48px", "raw", "dimension"));
  out.push(t("h-deck", "240px", "raw", "dimension"));
  out.push(t("w-sidebar", "168px", "raw", "dimension"));
  out.push(t("w-rail", "300px", "raw", "dimension"));

  // z-index scale — avoid magic numbers
  out.push(t("z-base", "1", "raw", "number"));
  out.push(t("z-sticky", "20", "raw", "number"));
  out.push(t("z-dropdown", "30", "raw", "number"));
  out.push(t("z-overlay", "40", "raw", "number", "comment composer, tooltips"));
  out.push(t("z-drawer", "60", "raw", "number", "inspector / right drawer"));
  out.push(t("z-modal", "80", "raw", "number"));
  out.push(t("z-toast", "100", "raw", "number"));

  // ── Legacy named scales — preserved verbatim from the deleted hand-written
  // tokens.css. Components reference these literal names (variables.css
  // aliases --fs-* → --font-size-*; lifeline-bar / kpi-cell / chat
  // primitives reach for --spacing-element / --spacing-group /
  // --radius-xl directly). Parallel to the canonical fs-N / sp-N / r-N
  // raw scale; both kept until consumers migrate.
  out.push(t("font-size-3xs", "10px", "raw", "dimension"));
  out.push(t("font-size-2xs", "11px", "raw", "dimension"));
  out.push(t("font-size-xs",  "12px", "raw", "dimension"));
  out.push(t("font-size-sm",  "13px", "raw", "dimension",
    "intentional override: Tailwind v4 default is 14px"));
  out.push(t("font-size-base","14px", "raw", "dimension"));
  out.push(t("font-size-md",  "15px", "raw", "dimension",
    "intentional addition: Tailwind v4 has no built-in md"));
  out.push(t("font-size-lg",  "16px", "raw", "dimension"));

  out.push(t("spacing-element", "8px",  "raw", "dimension", "tight element spacing"));
  out.push(t("spacing-group",   "12px", "raw", "dimension", "grouped items"));
  out.push(t("spacing-card",    "16px", "raw", "dimension", "card internal padding"));

  out.push(t("radius-xl", "24px", "raw", "dimension"));

  // ── Tailwind palette aliases (Iter 2c-1, v2 design-system pivot)
  // Lifted from dashboard/src/styles/variables.css. Component code
  // references these by Tailwind-canonical name (e.g. --slate-500) and
  // they should originate from source.ts so the codegen owns the hex
  // and tokens-drift Gate 2 enforces consistency. Theme-scoped names
  // like the paper-theme `slate` raw (line ~686) are unrelated and
  // unaffected — these aliases are global Tailwind palette references.
  out.push(t("slate-400",   "#94a3b8", "raw", "color", "Tailwind slate-400 alias"));
  out.push(t("slate-500",   "#64748b", "raw", "color", "Tailwind slate-500 alias"));
  out.push(t("slate-600",   "#475569", "raw", "color", "Tailwind slate-600 alias"));
  out.push(t("slate-800",   "#1e293b", "raw", "color", "Tailwind slate-800 alias"));
  out.push(t("blue-400",    "#60a5fa", "raw", "color", "Tailwind blue-400 alias"));
  out.push(t("sky-400",     "#38bdf8", "raw", "color", "Tailwind sky-400 alias"));
  out.push(t("purple-500",  "#a855f7", "raw", "color", "Tailwind purple-500 alias"));
  out.push(t("yellow-100",  "#fde68a", "raw", "color", "Tailwind yellow-100 alias"));
  out.push(t("red-100",     "#fecaca", "raw", "color", "Tailwind red-100 alias"));
  out.push(t("cyan-100",    "#cffafe", "raw", "color", "Tailwind cyan-100 alias"));

  // Iter 2c-2: Tailwind palette aliases retaining the original short
  // names from variables.css (no -N suffix). The hex matches a specific
  // Tailwind shade per token (emerald-500, emerald-200, indigo-400,
  // yellow-400, amber-500); names mirror existing call-site usage so
  // no consumer rename is required.
  out.push(t("emerald",        "#22c55e", "raw", "color", "Tailwind emerald-500 alias (kept short name)"));
  out.push(t("emerald-fg",     "#bbf7d0", "raw", "color", "Tailwind emerald-200 alias (kept short name)"));
  out.push(t("indigo",         "#818cf8", "raw", "color", "Tailwind indigo-400 alias (kept short name)"));
  out.push(t("yellow-bright",  "#facc15", "raw", "color", "Tailwind yellow-400 alias (kept short name)"));
  out.push(t("amber-bright",   "#f59e0b", "raw", "color", "Tailwind amber-500 alias (kept short name)"));

  // Iter 2c-3: rose family. Pink-red shades distinct from the bright/
  // muted status canon (--bad / --bad-light). Use-sites call them by
  // existing short names; companion alpha variants (--rose-10,
  // --rose-28) stay hand-authored in variables.css per the lift policy
  // introduced in Iter 2c-2.
  out.push(t("rose",           "#f43f5e", "raw", "color", "Tailwind rose-500 alias"));
  out.push(t("rose-fg",        "#fecdd3", "raw", "color", "Tailwind rose-200 alias"));
  out.push(t("rose-light",     "#fb7185", "raw", "color", "Tailwind rose-400 alias"));

  // Iter 2c-4: cyan/purple short names. Companion alpha variants
  // (--cyan-12, --cyan-16, --purple-12, --purple-24, --purple-50) stay
  // hand-authored in variables.css per the companion alpha policy.
  out.push(t("cyan",           "#22d3ee", "raw", "color", "Tailwind cyan-400 alias (kept short name)"));
  out.push(t("purple",         "#a78bfa", "raw", "color", "Tailwind purple-400 alias (kept short name)"));

  // Iter 2c-5: neutral scale. The "frost-100, white-pure queued for the
  // next wave" comment in variables.css (post-Iter 2c-1) explicitly
  // anchored these. text-near-white and text-slate-light join because
  // they map cleanly to Tailwind slate shades and have no companion
  // alpha variants.
  out.push(t("frost-100",       "#e2e8f0", "raw", "color", "Tailwind slate-200 alias (kept legacy frost name)"));
  out.push(t("white-pure",      "#ffffff", "raw", "color", "Pure white #ffffff (canon constant, distinct from --text-strong tints)"));
  out.push(t("text-near-white", "#f8fafc", "raw", "color", "Tailwind slate-50 alias"));
  out.push(t("text-slate-light","#cbd5e1", "raw", "color", "Tailwind slate-300 alias"));

  // Iter 2c-6: text body family. Custom dashboard-tuned shades that do
  // not map to standard Tailwind slate stops; semantic role is the
  // primary identity (strong > body > muted > dim luminance ladder).
  // Lifted as raw because they are direct color values consumed by the
  // semantic text-* role layer.
  out.push(t("text-strong",     "#eaf1ff", "raw", "color", "Brightest text on dark surfaces"));
  out.push(t("text-body",       "#c0d2f2", "raw", "color", "Default body copy on dark surfaces"));
  out.push(t("text-muted",      "#a8bfdf", "raw", "color", "Secondary/labels"));
  out.push(t("text-dim",        "#a0a8b4", "raw", "color", "Tertiary/captions"));

  // Iter 2c-7: state + agent domain colors. Dashboard-tuned shades, NOT
  // Tailwind palette aliases (state-idle #b8c0cc sits between slate-300
  // and slate-400; agent-working #7ae09a is warmer than green-300).
  out.push(t("state-idle",      "#b8c0cc", "raw", "color", "Keeper idle / no signal"));
  out.push(t("state-offline",   "#7a8494", "raw", "color", "Keeper offline / unreachable"));
  out.push(t("agent-working",   "#7ae09a", "raw", "color", "Agent actively running"));
  out.push(t("agent-busy",      "#f0c060", "raw", "color", "Agent busy / queued"));

  // Iter 2c-8: chat domain colors. Conversation surface palette —
  // 3 role pairs (user/assistant/error) each with avatar (deeper) +
  // chip (paler) tints, plus a single bright code-callout green.
  // Custom dashboard hues, not Tailwind aliases. Pair structure is
  // intentional: avatar reads on light bg, chip reads on dark bg.
  out.push(t("chat-user-avatar",      "#d8f0ff", "raw", "color", "Chat user avatar tint"));
  out.push(t("chat-user-chip",        "#c9ebff", "raw", "color", "Chat user message chip"));
  out.push(t("chat-assistant-avatar", "#efe6ff", "raw", "color", "Chat assistant avatar tint"));
  out.push(t("chat-assistant-chip",   "#ded0ff", "raw", "color", "Chat assistant message chip"));
  out.push(t("chat-error-avatar",     "#ffe1e1", "raw", "color", "Chat error avatar tint"));
  out.push(t("chat-error-chip",       "#ffb4b4", "raw", "color", "Chat error message chip"));
  out.push(t("chat-code-callout",     "#95f3bc", "raw", "color", "Chat inline code callout (bright mint)"));

  // Iter 2c-9: vote button Reddit-pattern colors. Used identically by
  // board.css and dashboard.css; hex values are CANONICAL (Reddit
  // upvote = #ff4500) and intentionally preserved exactly.
  out.push(t("vote-up",         "#ff4500", "raw", "color", "Reddit-canonical upvote orange-red"));
  out.push(t("vote-down",       "#7193ff", "raw", "color", "Reddit-canonical downvote blue-violet"));
  out.push(t("vote-hover",      "#ccc",    "raw", "color", "Vote button hover (3-digit short hex)"));
  return Object.freeze(out);
})();

// ─────────────────────────────────────────────────────────────────────────
// Semantic tokens — 4-slot per status, derived from raw
// ─────────────────────────────────────────────────────────────────────────

const STATUS_FG_OVERRIDES: Record<string, string> = {
  // Status -fg is a brightened variant of raw — preserved verbatim from
  // tokens.css §1 to keep contrast pinned. NOT derivable purely from raw
  // without a perceptual lift function; pinning is the conservative call.
  ok: "#8ebc8e",
  warn: "#d9b764",
  err: "#d8806f",
  info: "#8aa6c4",
  idle: "#8a8a8a",
  stalled: "#a88ac0",
};

interface SemSlotsOpts {
  softAlpha: number;
  borderAlpha: number;
  ringInner: number;
  ringOuter: number;
  ringBlur: string;
  fgPinned?: string;
}

function fourSlotForRgbTriplet(
  prefix: string,
  triplet: string,
  opts: SemSlotsOpts,
  description?: string,
): TokenBase[] {
  const arr: TokenBase[] = [];
  arr.push(t(`${prefix}-soft`,
    `rgb(${triplet} / .${String(Math.round(opts.softAlpha * 100)).padStart(2, "0")})`,
    "semantic", "color", description));
  if (opts.fgPinned) {
    arr.push(t(`${prefix}-fg`, opts.fgPinned, "semantic", "color"));
  }
  arr.push(t(`${prefix}-border`,
    `rgb(${triplet} / .${String(Math.round(opts.borderAlpha * 100)).padStart(2, "0")})`,
    "semantic", "color"));
  arr.push(t(`${prefix}-ring`,
    `0 0 0 1px rgb(${triplet} / .${String(Math.round(opts.ringInner * 100)).padStart(2, "0")}), 0 0 ${opts.ringBlur} rgb(${triplet} / .${String(Math.round(opts.ringOuter * 100)).padStart(2, "0")})`,
    "semantic", "shadow"));
  return arr;
}

export const semantic: ReadonlyArray<TokenBase> = (() => {
  const out: TokenBase[] = [];

  // Status 4-slot — alphas pinned to source tokens.css to preserve parity
  out.push(...fourSlotForRgbTriplet("ok", rgbTriplet("#6b9e6b"),
    { softAlpha: 0.10, borderAlpha: 0.35, ringInner: 0.45, ringOuter: 0.35, ringBlur: "8px", fgPinned: STATUS_FG_OVERRIDES.ok }));
  out.push(...fourSlotForRgbTriplet("warn", rgbTriplet("#c9a24a"),
    { softAlpha: 0.12, borderAlpha: 0.35, ringInner: 0.45, ringOuter: 0.35, ringBlur: "8px", fgPinned: STATUS_FG_OVERRIDES.warn }));
  out.push(...fourSlotForRgbTriplet("err", rgbTriplet("#c46a5a"),
    { softAlpha: 0.12, borderAlpha: 0.40, ringInner: 0.50, ringOuter: 0.40, ringBlur: "8px", fgPinned: STATUS_FG_OVERRIDES.err }));
  out.push(...fourSlotForRgbTriplet("info", rgbTriplet("#6a8eb0"),
    { softAlpha: 0.12, borderAlpha: 0.35, ringInner: 0.45, ringOuter: 0.35, ringBlur: "8px", fgPinned: STATUS_FG_OVERRIDES.info }));

  // idle has no -ring (intentional: silent state, no emphasis)
  out.push(t("idle-soft", `rgb(${rgbTriplet("#6a6a6a")} / .10)`, "semantic", "color"));
  out.push(t("idle-fg", STATUS_FG_OVERRIDES.idle, "semantic", "color"));
  out.push(t("idle-border", `rgb(${rgbTriplet("#6a6a6a")} / .30)`, "semantic", "color"));

  out.push(...fourSlotForRgbTriplet("stalled", rgbTriplet("#8a6aa0"),
    { softAlpha: 0.12, borderAlpha: 0.35, ringInner: 0.45, ringOuter: 0.35, ringBlur: "8px", fgPinned: STATUS_FG_OVERRIDES.stalled }));

  // Brass 4-slot — fg is a var() back-reference to brass-1
  out.push(t("brass-soft", `rgb(${rgbTriplet("#d4a14a")} / .10)`, "semantic", "color"));
  out.push(t("brass-fg", "var(--brass-1)", "semantic", "color"));
  out.push(t("brass-border", `rgb(${rgbTriplet("#d4a14a")} / .35)`, "semantic", "color"));
  out.push(t("brass-ring",
    `0 0 0 1px rgb(${rgbTriplet("#d4a14a")} / .50), 0 0 10px rgb(${rgbTriplet("#d4a14a")} / .50)`,
    "semantic", "shadow"));

  // Keeper 4-slot — derived from generated palette
  for (let i = 1; i <= 12; i++) {
    const { hex } = generateKeeperSlot(i);
    const triplet = rgbTriplet(hex);
    out.push(...fourSlotForRgbTriplet(`k-${i}`, triplet,
      { softAlpha: 0.10, borderAlpha: 0.35, ringInner: 0.45, ringOuter: 0.35, ringBlur: "8px" }));
  }

  // Provider 2-slot
  for (const [name, hex] of [
    ["anthropic", "#c9a88a"],
    ["moonshot", "#8a98c9"],
    ["openai", "#6b9e8e"],
    ["xai", "#a896a0"],
  ] as const) {
    out.push(t(`p-${name}-soft`, `rgb(${rgbTriplet(hex)} / .10)`, "semantic", "color"));
    out.push(t(`p-${name}-border`, `rgb(${rgbTriplet(hex)} / .30)`, "semantic", "color"));
  }

  // ── Color role aliases — late-binding semantic layer ────────────────
  // These mirror tokens.css §end. Components prefer --color-* over raw bg-N.
  out.push(t("color-bg-page", "var(--bg-0)", "role", "color"));
  out.push(t("color-bg-surface", "var(--bg-1)", "role", "color"));
  out.push(t("color-bg-panel-alt", "var(--bg-2)", "role", "color"));
  out.push(t("color-bg-elevated", "var(--bg-3)", "role", "color"));
  out.push(t("color-bg-hover", "var(--bg-4)", "role", "color"));

  out.push(t("color-fg-primary", "var(--fg-1)", "role", "color"));
  out.push(t("color-fg-secondary", "var(--fg-2)", "role", "color"));
  out.push(t("color-fg-muted", "var(--fg-3)", "role", "color"));
  out.push(t("color-fg-disabled", "var(--fg-4)", "role", "color"));

  out.push(t("color-border-default", "var(--line-1)", "role", "color"));
  out.push(t("color-border-strong", "var(--line-2)", "role", "color"));
  out.push(t("color-border-divider", "var(--line-3)", "role", "color"));

  out.push(t("color-accent-fg", "var(--brass-1)", "role", "color"));
  out.push(t("color-accent-fg-dim", "var(--brass-3)", "role", "color"));
  out.push(t("color-accent-glow", "var(--brass-glow)", "role", "color"));

  out.push(t("color-status-ok", "var(--ok)", "role", "color"));
  out.push(t("color-status-warn", "var(--warn)", "role", "color"));
  out.push(t("color-status-err", "var(--err)", "role", "color"));
  out.push(t("color-status-info", "var(--info)", "role", "color"));
  out.push(t("color-status-idle", "var(--idle)", "role", "color"));
  out.push(t("color-status-stalled", "var(--stalled)", "role", "color"));

  for (let i = 1; i <= 12; i++) {
    out.push(t(`color-keeper-${i}`, `var(--k-${i})`, "role", "color"));
  }
  out.push(t("color-focus-ring", "var(--brass-1)", "role", "color"));

  // Diff status aliases — drives diff-add / diff-del / diff-modified surfaces
  out.push(t("color-status-added", "var(--ok)", "role", "color"));
  out.push(t("color-status-modified", "var(--warn)", "role", "color"));
  out.push(t("color-status-deleted", "var(--err)", "role", "color"));

  // ── Type role tokens — bundle size / line-height / family ──────────
  // shorthand: `<size>/<lh> <family>` for use as `font: var(--type-body)`.
  const typeRole = (
    name: string, fs: string, lh: string, family: string, desc?: string,
  ): TokenBase => t(name,
    `var(--${fs})/var(--${lh}) var(--${family})`,
    "role", "typography", desc);
  out.push(typeRole("type-micro",   "fs-9",  "lh-tight", "font-mono"));
  out.push(typeRole("type-caption", "fs-10", "lh-tight", "font-mono"));
  out.push(typeRole("type-label",   "fs-11", "lh-tight", "font-sans"));
  out.push(typeRole("type-meta",    "fs-12", "lh-tight", "font-mono"));
  out.push(typeRole("type-body",    "fs-13", "lh-body",  "font-sans"));
  out.push(typeRole("type-code",    "fs-12", "lh-body",  "font-mono"));
  out.push(typeRole("type-title",   "fs-14", "lh-tight", "font-sans"));
  out.push(typeRole("type-kpi-m",   "fs-16", "lh-tight", "font-mono"));
  out.push(typeRole("type-kpi-l",   "fs-20", "lh-tight", "font-mono"));
  out.push(typeRole("type-hero",    "fs-28", "lh-tight", "font-mono"));
  out.push(typeRole("type-display", "fs-36", "lh-tight", "font-mono"));

  // ── Density-aware spacing roles ────────────────────────────────────
  out.push(t("sp-inline",  "calc(var(--density) * 4px)",  "role", "dimension", "icon-to-label gap"));
  out.push(t("sp-gutter",  "calc(var(--density) * 8px)",  "role", "dimension", "between sibling fields"));
  out.push(t("sp-stack",   "calc(var(--density) * 12px)", "role", "dimension", "between blocks"));
  out.push(t("sp-section", "calc(var(--density) * 20px)", "role", "dimension", "between sections"));
  out.push(t("sp-region",  "calc(var(--density) * 32px)", "role", "dimension", "between regions"));

  // Row heights — density-aware
  out.push(t("row-h-micro", "calc(var(--density) * 18px)", "role", "dimension"));
  out.push(t("row-h-tight", "calc(var(--density) * 22px)", "role", "dimension"));
  out.push(t("row-h",       "calc(var(--density) * 26px)", "role", "dimension"));
  out.push(t("row-h-loose", "calc(var(--density) * 32px)", "role", "dimension"));
  out.push(t("row-h-tall",  "calc(var(--density) * 40px)", "role", "dimension"));

  // Control heights — density-aware
  out.push(t("ctrl-h-xs", "calc(var(--density) * 16px)", "role", "dimension"));
  out.push(t("ctrl-h-sm", "calc(var(--density) * 20px)", "role", "dimension"));
  out.push(t("ctrl-h",    "calc(var(--density) * 24px)", "role", "dimension"));
  out.push(t("ctrl-h-lg", "calc(var(--density) * 28px)", "role", "dimension"));

  // Density-scope sentinel — closes the auto-var block in tokens.css so the
  // body[data-density="..."] override below scopes cleanly. Kept for parity.
  out.push(t("_density-scope", "1", "role", "number", "scope sentinel"));

  // ── Elevation 7-step — bundle bg / border / shadow per level ───────
  const elev = (n: number, bg: string, border: string, shadow: string, desc?: string): TokenBase[] => [
    t(`elev-${n}-bg`,     bg,     "role", "color", desc),
    t(`elev-${n}-border`, border, "role", "color"),
    t(`elev-${n}-shadow`, shadow, "role", "shadow"),
  ];
  out.push(...elev(0, "var(--bg-0)", "transparent",  "none", "page / inset"));
  out.push(...elev(1, "var(--bg-1)", "var(--line-1)", "0 1px 0 rgb(0 0 0 / .4)", "resting panel"));
  out.push(...elev(2, "var(--bg-2)", "var(--line-1)",
    "0 1px 0 rgb(0 0 0 / .4), inset 0 1px 0 rgb(255 255 255 / .02)",
    "card / default surface"));
  out.push(...elev(3, "var(--bg-3)", "var(--line-2)",
    "0 2px 6px rgb(0 0 0 / .45), inset 0 1px 0 rgb(255 255 255 / .03)",
    "hovered card"));
  out.push(...elev(4, "var(--bg-3)", "var(--line-2)",
    "0 6px 18px rgb(0 0 0 / .55), 0 0 0 1px var(--line-2), inset 0 1px 0 rgb(255 255 255 / .03)",
    "floating menu / popover"));
  out.push(...elev(5, "var(--bg-3)", "var(--line-3)",
    "0 12px 32px rgb(0 0 0 / .6), 0 0 0 1px var(--line-3), inset 0 1px 0 rgb(255 255 255 / .04)",
    "drawer / sheet"));
  out.push(...elev(6, "var(--bg-3)", "var(--line-3)",
    "0 24px 64px rgb(0 0 0 / .7), 0 0 0 1px var(--line-3), inset 0 1px 0 rgb(255 255 255 / .04)",
    "modal overlay"));

  // Shadow aliases (compat with existing styles)
  out.push(t("shadow-1", "var(--elev-2-shadow)", "role", "shadow"));
  out.push(t("shadow-2", "var(--elev-4-shadow)", "role", "shadow"));
  out.push(t("shadow-3", "var(--elev-5-shadow)", "role", "shadow"));
  out.push(t("shadow-inset", "inset 0 1px 0 rgb(255 255 255 / .03)", "role", "shadow"));

  // Bonsai shadow primitives (theme-overridden in dark-fantasy / cyberpunk)
  out.push(t("shadow-card",   "0 1px 4px rgba(0, 0, 0, 0.5)", "role", "shadow"));
  out.push(t("shadow-panel",  "0 2px 12px rgba(0, 0, 0, 0.6)", "role", "shadow"));
  out.push(t("shadow-glow",   "0 0 20px var(--accent-glow)",  "role", "shadow"));
  out.push(t("shadow-raised",
    "0 8px 24px rgba(0, 0, 0, 0.55), 0 0 0 1px var(--border-highlight)",
    "role", "shadow"));
  out.push(t("shadow-ring",   "inset 0 0 0 1px rgba(196, 162, 101, 0.25)", "role", "shadow",
    "bonsai-only 1px ring (distinct from --shadow-inset)"));

  // Focus / interaction overlays
  out.push(t("focus-ring",
    `0 0 0 1px var(--brass-1), 0 0 0 3px rgb(var(--brass-glow) / .25)`,
    "role", "shadow"));
  out.push(t("focus-ring-err",
    `0 0 0 1px var(--err), 0 0 0 3px rgb(var(--err-glow) / .3)`,
    "role", "shadow"));
  out.push(t("hover-overlay",  "rgb(255 255 255 / .03)", "role", "color"));
  out.push(t("active-overlay", "rgb(0 0 0 / .25)",       "role", "color"));

  // Interactive state roles — explicit hover/selected/pressed semantics
  out.push(t("state-hover-bg",       "var(--bg-3)",   "role", "color"));
  out.push(t("state-hover-fg",       "var(--fg-1)",   "role", "color"));
  out.push(t("state-hover-border",   "var(--line-2)", "role", "color"));
  out.push(t("state-selected-bg",    "var(--bg-4)",   "role", "color"));
  out.push(t("state-selected-fg",    "var(--fg-1)",   "role", "color"));
  out.push(t("state-selected-border","var(--line-3)", "role", "color"));
  out.push(t("state-pressed-bg",     "rgb(0 0 0 / .4)", "role", "color"));
  out.push(t("state-active-bg",      "rgb(var(--brass-glow) / .08)", "role", "color"));
  out.push(t("state-active-fg",      "var(--brass-1)", "role", "color"));
  out.push(t("state-active-border",  "var(--brass-3)", "role", "color"));
  out.push(t("state-disabled-fg",    "var(--fg-4)",   "role", "color"));
  out.push(t("state-disabled-bg",    "transparent",   "role", "color"));

  // Divider roles
  out.push(t("divider",          "var(--line-1)", "role", "color"));
  out.push(t("divider-emphasis", "var(--line-2)", "role", "color"));
  out.push(t("divider-zone",     "var(--line-3)", "role", "color"));

  // Overlay scrims — drawer / modal / sheet backdrops
  out.push(t("scrim-subtle", "rgb(0 0 0 / .3)", "role", "color"));
  out.push(t("scrim",        "rgb(0 0 0 / .5)", "role", "color"));
  out.push(t("scrim-strong", "rgb(0 0 0 / .7)", "role", "color"));
  out.push(t("scrim-brass",  "rgb(var(--brass-glow) / .04)", "role", "color",
    "warm wash behind active region"));
  out.push(t("bg-tab-sticky-hover", "rgb(30 41 59 / .95)", "role", "color",
    "sticky tab hover backdrop (slate-800 / 95%)"));

  // ── Motion role tokens — bundle duration + easing ──────────────────
  out.push(t("motion-enter",  "var(--t-med) var(--ease-out)", "role", "duration"));
  out.push(t("motion-exit",   "var(--t-fast) var(--ease-in)", "role", "duration"));
  out.push(t("motion-swap",   "var(--t-fast) var(--ease)", "role", "duration"));
  out.push(t("motion-reveal", "var(--t-slow) var(--ease-out)", "role", "duration"));
  out.push(t("motion-settle", "var(--t-xslow) var(--ease-out)", "role", "duration"));
  out.push(t("motion-pop",    "var(--t-med) var(--ease-spring)", "role", "duration"));

  // Motion-scope sentinel — parallel to _density-scope
  out.push(t("_motion-scope", "1", "role", "number", "scope sentinel"));

  // Comment kind — semantic colors distinct from raw status
  out.push(t("cmt-question", "var(--info)",    "role", "color"));
  out.push(t("cmt-flag",     "var(--err)",     "role", "color"));
  out.push(t("cmt-note",     "var(--fg-2)",    "role", "color"));
  out.push(t("cmt-approve",  "var(--ok)",      "role", "color"));
  out.push(t("cmt-suggest",  "var(--brass-1)", "role", "color"));

  // Diff overlay tints
  out.push(t("diff-add",     "rgb(107 158 107 / .08)", "role", "color"));
  out.push(t("diff-del",     "rgb(196 106 90 / .08)",  "role", "color"));
  out.push(t("diff-add-bar", "rgb(107 158 107 / .35)", "role", "color"));
  out.push(t("diff-del-bar", "rgb(196 106 90 / .35)",  "role", "color"));

  // Heatmap — brass-tinted, 3 steps
  out.push(t("heat-1", "rgb(212 161 74 / .04)", "role", "color"));
  out.push(t("heat-2", "rgb(212 161 74 / .08)", "role", "color"));
  out.push(t("heat-3", "rgb(212 161 74 / .14)", "role", "color"));

  // ── Legacy named role aliases — preserved verbatim from the deleted
  // hand-written tokens.css. Each maps a legacy --color-* name to the
  // canonical dark-fantasy raw/semantic so 40+ components keep working
  // through their literal token references. Mappings collapse the old
  // navy/cyan palette onto the new brass/warm canon (intentional —
  // resurrecting the legacy hex would re-fork the palette).
  //
  // Color → tier:'role', kind:'color'.
  // Tailwind passthrough: names already start with --color- (no re-prefix).
  out.push(t("color-text-body",  "var(--fg-2)", "role", "color",
    "legacy alias for body copy"));
  out.push(t("color-text-muted", "var(--fg-3)", "role", "color",
    "legacy alias for muted copy"));
  out.push(t("color-text-dim",   "var(--fg-3)", "role", "color",
    "legacy alias; collapses to fg-3 same as muted"));

  // Brass aliases — legacy names for the canonical accent.
  out.push(t("color-accent-brass", "var(--brass-1)",   "role", "color",
    "legacy alias for the brass primary"));
  out.push(t("color-accent-soft",  "var(--brass-soft)","role", "color",
    "legacy alias for the brass soft tint"));

  // Status tone variants — used by chat warn banners and error text.
  // Legacy names map onto the canonical err/warn raw rather than the
  // pinned -fg variants because consumers use them for body text on a
  // tinted background, where raw err/warn provide the same WCAG ramp.
  out.push(t("bad-light",    "var(--err)",  "role", "color",
    "legacy alias for body-on-tinted error text"));
  out.push(t("warn-bright",  "var(--warn)", "role", "color",
    "legacy alias for body-on-tinted warn text"));

  // Per-keeper glow rgb triplets — legacy --color-keeper-N-glow names
  // referenced by keeper-badge.ts via dynamic template literal, so all
  // 12 are required even though static grep finds zero literal matches.
  // Each aliases the canonical --k-N-glow raw (same OkLCH palette).
  for (let i = 1; i <= 12; i++) {
    out.push(t(`color-keeper-${i}-glow`, `var(--k-${i}-glow)`, "role", "color"));
  }

  return Object.freeze(out);
})();

// ─────────────────────────────────────────────────────────────────────────
// Themes — dark-fantasy (default) + paper. Other themes deferred per
// roadmap; emit them later when consumer migration is unblocked.
// ─────────────────────────────────────────────────────────────────────────

export const themes: ReadonlyArray<Theme> = Object.freeze([
  {
    id: "dark-fantasy",
    mode: "dark",
    tokens: Object.freeze([
      t("bg-deep", "#0a0706", "raw", "color", "pitch with red undertone"),
      t("bg-panel", "#14100d", "raw", "color", "rotted wood"),
      t("bg-panel-alt", "#1b1612", "raw", "color"),
      t("bg-card", "#221815", "raw", "color"),
      t("bg-card-hover", "#2e211c", "raw", "color"),
      t("border-main", "#2a1a14", "raw", "color"),
      t("border-highlight", "#5a3028", "raw", "color"),
      t("text-bright", "#e8d8b8", "raw", "color", "clean bone"),
      t("text-primary", "#b8a488", "raw", "color", "dirty bandage"),
      t("text-dim", "#9a846e", "raw", "color", "WCAG AA"),
      t("accent-blood", "#e85050", "raw", "color"),
      t("accent-blood-dim", "#8a2828", "raw", "color"),
      t("accent-viscera", "#c94a3a", "raw", "color"),
      t("accent-bile", "#6a7a3a", "raw", "color"),
      t("accent-mold", "#3a5a48", "raw", "color"),
      t("accent-brass", "#968228", "raw", "color", "bonsai brass differs from --brass-1"),
      t("accent-brass-dim", "#6a5620", "raw", "color"),
      t("accent-bone", "#d8c8a0", "raw", "color"),
      t("accent-ink", "#3a2a5a", "raw", "color"),
      t("accent-ember", "#c4461a", "raw", "color"),
      t("accent-glow", "rgba(232, 80, 80, 0.28)", "raw", "color"),
      t("accent-blood-glow", "rgba(232, 80, 80, 0.32)", "raw", "color"),
      t("status-ok", "#6a9a4a", "raw", "color"),
      t("status-warn", "#b87828", "raw", "color"),
      t("status-bad", "#e85050", "raw", "color"),
      t("status-idle", "#4a3a32", "raw", "color"),
      // Trace frame — bonsai-only swimlane / flame / tool-category bars
      t("t-llm",   "#6a7a9c", "raw", "color", "muted blue-gray — inference"),
      t("t-tool",  "#8a7a3a", "raw", "color", "muted brass — tool call"),
      t("t-think", "#4a4a5a", "raw", "color", "slate — reasoning"),
      t("t-wait",  "#2a2520", "raw", "color", "deep dusk — idle"),
      t("t-err",   "var(--accent-blood)", "raw", "color"),
    ]),
  },
  {
    id: "paper",
    mode: "light",
    tokens: Object.freeze([
      t("paper", "#F5F2EA", "raw", "color"),
      t("paper-2", "#EFEBE0", "raw", "color"),
      t("paper-3", "#E5E0D1", "raw", "color"),
      t("paper-4", "#D8D2BF", "raw", "color"),
      t("ink", "#151515", "raw", "color"),
      t("ink-2", "#2E2E2C", "raw", "color"),
      t("ink-3", "#515049", "raw", "color"),
      t("ink-4", "#656358", "raw", "color"),
      t("ink-5", "#9A978D", "raw", "color"),
      t("ink-6", "#BCB8AC", "raw", "color"),
      t("forest", "#2D5F4E", "raw", "color"),
      t("forest-fill", "#CFDFD7", "raw", "color"),
      t("brass", "#8C6A1E", "raw", "color"),
      t("brass-fill", "#E9DDB8", "raw", "color"),
      t("brick", "#8B3A3A", "raw", "color"),
      t("brick-fill", "#E8CFCB", "raw", "color"),
      t("ember", "#B35A1F", "raw", "color"),
      t("ember-fill", "#ECD5BD", "raw", "color"),
      t("slate", "#3E4A5C", "raw", "color"),
      t("slate-fill", "#D6DBE2", "raw", "color"),
      t("plum", "#5C3E56", "raw", "color"),
      t("plum-fill", "#E0D4DE", "raw", "color"),
      t("teal", "#236874", "raw", "color"),
      t("teal-fill", "#CEDEE2", "raw", "color"),
    ]),
  },
]);

// ─────────────────────────────────────────────────────────────────────────
// Bonsai-side codegen — naming alias + paper override layer
//
// dashboard_bonsai/static/colors_and_type.css uses Bonsai-native names
// (--bg-deep / --accent-brass / --space-1) that differ from dashboard's
// (--bg-0 / --brass-1 / --sp-1). The bonsai output is emitted alongside
// the Preact outputs and shares the same SSOT (this file).
//
// Per user decision: only 2 themes (dark-fantasy canonical + paper light).
// cyberpunk / terminal / parchment are archived to static/themes/archive/.
// ─────────────────────────────────────────────────────────────────────────

/**
 * Names of [tier:'raw'] tokens that are Bonsai-side theme-invariant
 * primitives (radius / space / scrollbar). Theme-overridable shadow
 * primitives like --shadow-card are tier:'role' and emitted separately
 * via [bonsaiInvariantRoleNames] below.
 *
 * Font stacks are intentionally excluded — Bonsai uses different stacks
 * (JetBrains Mono first, Cinzel display) per SPEC §6 divergence list.
 * Bonsai font values are emitted from [bonsaiFontOverrides] as :root
 * tokens that shadow the canonical raw --font-* values.
 */
export const bonsaiInvariantRawNames: ReadonlyArray<string> = Object.freeze([
  // Radius
  "radius-xs", "radius-sm", "radius-md", "radius-lg", "radius-pill",
  // Spacing — bonsai 8-step (parallel to --sp-*)
  "space-1", "space-2", "space-3", "space-4",
  "space-5", "space-6", "space-7", "space-8",
  // Scrollbar primitives
  "scrollbar-thumb", "scrollbar-thumb-hover",
]);

/**
 * Names of [tier:'role'] tokens that are Bonsai-side theme-invariant
 * defaults (overridden by paper theme).
 */
export const bonsaiInvariantRoleNames: ReadonlyArray<string> = Object.freeze([
  "shadow-card", "shadow-panel", "shadow-glow", "shadow-raised", "shadow-ring",
]);

/**
 * Bonsai font stacks — distinct from canonical raw per SPEC §6.323
 * (dashboard uses ui-monospace first; bonsai uses JetBrains Mono first).
 * Emitted as raw declarations inside the :root block so Bonsai-only
 * components see Bonsai-native typography without affecting dashboard.
 */
export const bonsaiFontOverrides: ReadonlyArray<TokenBase> = Object.freeze([
  t("font-display", "'Cinzel', 'Noto Sans KR', 'EB Garamond', serif", "raw", "typography"),
  t("font-body",    "'EB Garamond', 'Noto Sans KR', Georgia, serif",   "raw", "typography"),
  t("font-ui",      "'Noto Sans KR', 'IBM Plex Sans KR', -apple-system, sans-serif", "raw", "typography"),
  t("font-mono",    "'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace",     "raw", "typography"),
]);

/**
 * SPEC v0.1 §3.1-3.5 — Bonsai semantic vocabulary aliasing Bonsai raw.
 * Mirrors the [color-bg-page / color-fg-primary / ...] role in the
 * dashboard semantic layer, but each alias points at Bonsai-named raw
 * (e.g. --bg-deep) rather than dashboard raw (--bg-0). The paper theme
 * then overrides the underlying Bonsai raw so the alias inherits.
 */
export const bonsaiAliases: ReadonlyArray<TokenBase> = Object.freeze([
  t("color-bg-page",        "var(--bg-deep)",      "role", "color"),
  t("color-bg-surface",     "var(--bg-panel)",     "role", "color"),
  t("color-bg-panel-alt",   "var(--bg-panel-alt)", "role", "color"),
  t("color-bg-elevated",    "var(--bg-card)",      "role", "color"),
  t("color-bg-hover",       "var(--bg-card-hover)","role", "color"),

  t("color-fg-primary",     "var(--text-primary)", "role", "color"),
  t("color-fg-muted",       "var(--text-dim)",     "role", "color"),

  t("color-border-default", "var(--border-main)",      "role", "color"),
  t("color-border-strong",  "var(--border-highlight)", "role", "color"),

  t("color-accent-fg",      "var(--accent-brass)",     "role", "color"),
  t("color-accent-fg-dim",  "var(--accent-brass-dim)", "role", "color"),
  t("color-accent-glow",    "var(--accent-glow)",      "role", "color"),

  t("color-status-ok",      "var(--status-ok)",   "role", "color"),
  t("color-status-warn",    "var(--status-warn)", "role", "color"),
  t("color-status-err",     "var(--status-bad)",  "role", "color"),
  t("color-status-idle",    "var(--status-idle)", "role", "color"),
]);

/**
 * Per-theme Bonsai-name overrides. The [paper] theme remaps Bonsai
 * raw (--bg-deep / --text-primary / --status-ok / ...) to paper raw
 * (--paper / --ink-2 / --forest), plus its own shadow + trace frame
 * overrides. Emitted inside the [data-theme="paper"] block right
 * after the paper raw declarations.
 */
export const bonsaiThemeOverrides: Readonly<Record<string, ReadonlyArray<TokenBase>>> = Object.freeze({
  paper: Object.freeze([
    // Surface remap → paper layers
    t("bg-deep",        "var(--paper)",   "role", "color"),
    t("bg-panel",       "var(--paper-2)", "role", "color"),
    t("bg-panel-alt",   "var(--paper-3)", "role", "color"),
    t("bg-card",        "var(--paper-2)", "role", "color"),
    t("bg-card-hover",  "var(--paper-3)", "role", "color"),
    // Border — translucent ink on paper
    t("border-main",      "rgba(21,21,21,0.22)", "role", "color"),
    t("border-highlight", "rgba(21,21,21,0.48)", "role", "color"),
    // Text — ink ramp
    t("text-bright",  "var(--ink)",   "role", "color"),
    t("text-primary", "var(--ink-2)", "role", "color"),
    t("text-dim",     "var(--ink-4)", "role", "color"),
    // Accents — brass / brick / slate from paper palette
    t("accent-brass",     "var(--brass)",      "role", "color"),
    t("accent-brass-dim", "var(--brass-fill)", "role", "color"),
    t("accent-blood",     "var(--brick)",      "role", "color"),
    t("accent-ink",       "var(--slate)",      "role", "color"),
    t("accent-glow",      "rgba(140,106,30,0.12)", "role", "color"),
    // Status — paper colorway
    t("status-ok",   "var(--forest)", "role", "color"),
    t("status-warn", "var(--ember)",  "role", "color"),
    t("status-bad",  "var(--brick)",  "role", "color"),
    t("status-idle", "var(--ink-5)",  "role", "color"),
    // Shadows — flat / no glow on paper
    t("shadow-panel", "0 1px 2px rgba(0,0,0,0.06), 0 0 0 1px rgba(0,0,0,0.06)", "role", "shadow"),
    t("shadow-card",  "0 1px 0 rgba(0,0,0,0.04)", "role", "shadow"),
    t("shadow-glow",  "none",                     "role", "shadow"),
    // Trace frames — ink on paper
    t("t-llm",   "var(--slate)",   "role", "color"),
    t("t-tool",  "var(--brass)",   "role", "color"),
    t("t-think", "var(--plum)",    "role", "color"),
    t("t-wait",  "var(--paper-3)", "role", "color"),
    t("t-err",   "var(--brick)",   "role", "color"),
  ]),
});

// ─────────────────────────────────────────────────────────────────────────
// Aggregate accessor — for build.ts consumption
// ─────────────────────────────────────────────────────────────────────────

export interface BonsaiSource {
  readonly invariantRawNames: ReadonlyArray<string>;
  readonly invariantRoleNames: ReadonlyArray<string>;
  readonly fontOverrides: ReadonlyArray<TokenBase>;
  readonly aliases: ReadonlyArray<TokenBase>;
  readonly themeOverrides: Readonly<Record<string, ReadonlyArray<TokenBase>>>;
}

export interface TokenSource {
  readonly raw: ReadonlyArray<TokenBase>;
  readonly semantic: ReadonlyArray<TokenBase>;
  readonly themes: ReadonlyArray<Theme>;
  readonly bonsai: BonsaiSource;
}

export const source: TokenSource = Object.freeze({
  raw,
  semantic,
  themes,
  bonsai: Object.freeze({
    invariantRawNames: bonsaiInvariantRawNames,
    invariantRoleNames: bonsaiInvariantRoleNames,
    fontOverrides: bonsaiFontOverrides,
    aliases: bonsaiAliases,
    themeOverrides: bonsaiThemeOverrides,
  }),
});
