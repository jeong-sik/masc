/**
 * MASC Dashboard Design System — Single OKLCH Token Source (SSOT)
 *
 * "Tempered Slate + Surgical Hearth"
 * - Dark default (:root): neutral-warm slate surfaces oklch(0.145..0.270 0.005 70),
 *   Bone primary CTA, Steel-Ice focus ring, Candle Brass domain-only accent,
 *   5 disjoint status hues (ok 152°, warn 95°, err 24°, info 238°, stalled 310°).
 * - Light theme ([data-theme="light"]): "Warm Archival Paper" bg-0 oklch(0.975 0.005 75),
 *   fg-1 oklch(0.200 0.010 70).
 * - Static High-Contrast preset ([data-contrast="high"] & @media (prefers-contrast: more)):
 *   APCA Lc >= 90 with zero runtime color conversion (0 culori, 0 raw hex).
 *
 * Run `pnpm --dir dashboard tokens:build` after editing to emit:
 *   - dashboard/src/styles/tokens.generated.css
 *   - dashboard/design-system/source_styles/tokens.generated.css
 *   - dashboard/design-system/tokens/build/tokens.json
 */

export type Tier = 'raw' | 'semantic' | 'role'
export type Kind =
  | 'color'
  | 'dimension'
  | 'typography'
  | 'duration'
  | 'easing'
  | 'shadow'
  | 'number'

export interface TokenBase {
  readonly name: string
  readonly value: string
  readonly tier: Tier
  readonly kind: Kind
  readonly description?: string
}

export interface Theme {
  readonly id: 'dark' | 'light' | 'high-contrast-dark' | 'high-contrast-light'
  readonly selector: string
  readonly media?: string
  readonly mode: 'dark' | 'light'
  readonly tokens: ReadonlyArray<TokenBase>
}

const t = (
  name: string,
  value: string,
  tier: Tier,
  kind: Kind,
  description?: string,
): TokenBase => ({ name, value, tier, kind, description })

const mix = (token: string, pct: number): string =>
  `color-mix(in oklch, var(--${token}) ${pct}%, transparent)`

const KEEPER_HUE_NAMES = [
  'rose', 'clay', 'amber', 'olive', 'moss', 'jade',
  'teal', 'cyan', 'sky', 'iris', 'violet', 'mauve',
] as const

// ─────────────────────────────────────────────────────────────────────────
// Raw tokens — Dark default ("Tempered Slate + Surgical Hearth")
// Zero raw hex; every color is perceptual OKLCH.
// ─────────────────────────────────────────────────────────────────────────

export const raw: ReadonlyArray<TokenBase> = (() => {
  const out: TokenBase[] = []

  // Surfaces — Tempered Slate (0.005 chroma @ 70° warm-neutral)
  out.push(t('bg-0', 'oklch(0.145 0.005 70)', 'raw', 'color', 'page canvas'))
  out.push(t('bg-1', 'oklch(0.175 0.005 70)', 'raw', 'color', 'topbar / nav rail'))
  out.push(t('bg-2', 'oklch(0.205 0.005 70)', 'raw', 'color', 'panel surface'))
  out.push(t('bg-3', 'oklch(0.238 0.005 70)', 'raw', 'color', 'elevated card / popover'))
  out.push(t('bg-4', 'oklch(0.270 0.005 70)', 'raw', 'color', 'hover / active row'))

  // Hairlines
  out.push(t('line-1', 'oklch(0.295 0.006 70)', 'raw', 'color', 'default hairline border'))
  out.push(t('line-2', 'oklch(0.365 0.007 70)', 'raw', 'color', 'emphasized border'))
  out.push(t('line-3', 'oklch(0.455 0.008 70)', 'raw', 'color', 'zone divider'))

  // Foreground ink — 4 steps (APCA Lc >= 75 primary, >= 60 secondary)
  out.push(t('fg-1', 'oklch(0.935 0.008 80)', 'raw', 'color', 'primary ink (Lc >= 85)'))
  out.push(t('fg-2', 'oklch(0.790 0.010 78)', 'raw', 'color', 'secondary ink (Lc >= 60)'))
  out.push(t('fg-3', 'oklch(0.650 0.009 75)', 'raw', 'color', 'muted labels'))
  out.push(t('fg-4', 'oklch(0.490 0.008 72)', 'raw', 'color', 'disabled / placeholder'))

  // Bone Primary CTA (neutral high-contrast — separates CTA from Candle Brass)
  out.push(t('cta-bg', 'oklch(0.920 0.010 80)', 'raw', 'color', 'Bone primary CTA fill'))
  out.push(t('cta-fg', 'oklch(0.160 0.008 75)', 'raw', 'color', 'Bone primary CTA dark ink'))
  out.push(t('cta-bg-hover', 'oklch(0.960 0.008 80)', 'raw', 'color', 'Bone primary CTA hover fill'))

  // Steel-Ice Focus Ring (disjoint from brass and status hues)
  out.push(t('focus', 'oklch(0.720 0.110 245)', 'raw', 'color', 'steel-ice :focus-visible ring'))

  // Candle Brass — domain-only accent (Candle economy / live Hearth / active run)
  out.push(t('brass-1', 'oklch(0.770 0.135 74)', 'raw', 'color', 'Candle Brass domain accent'))
  out.push(t('brass-2', 'oklch(0.680 0.125 72)', 'raw', 'color', 'Candle Brass medium'))
  out.push(t('brass-3', 'oklch(0.560 0.105 70)', 'raw', 'color', 'Candle Brass deep'))

  // Disjoint Status Hues (152° ok, 95° warn, 24° err, 238° info, 310° stalled)
  out.push(t('ok', 'oklch(0.740 0.135 152)', 'raw', 'color', 'healthy / succeeded (152°)'))
  out.push(t('ok-fg', 'oklch(0.810 0.125 152)', 'raw', 'color', 'ok text foreground'))
  out.push(t('warn', 'oklch(0.830 0.150 95)', 'raw', 'color', 'degraded / attention (95°)'))
  out.push(t('warn-fg', 'oklch(0.860 0.140 95)', 'raw', 'color', 'warn text foreground'))
  out.push(t('err', 'oklch(0.670 0.165 24)', 'raw', 'color', 'error / failed (24°)'))
  out.push(t('err-fg', 'oklch(0.730 0.160 24)', 'raw', 'color', 'error text foreground (24°)'))
  out.push(t('info', 'oklch(0.740 0.120 238)', 'raw', 'color', 'informational / pending (238°)'))
  out.push(t('info-fg', 'oklch(0.800 0.110 238)', 'raw', 'color', 'info text foreground'))
  out.push(t('stalled', 'oklch(0.720 0.120 310)', 'raw', 'color', 'stalled / drift (310°)'))
  out.push(t('stalled-fg', 'oklch(0.790 0.110 310)', 'raw', 'color', 'stalled text foreground'))
  out.push(t('idle', 'oklch(0.620 0.008 72)', 'raw', 'color', 'idle / silent'))
  out.push(t('idle-fg', 'oklch(0.700 0.008 72)', 'raw', 'color', 'idle text foreground'))

  // Keeper 12-slot perceptual OKLCH spectrum (30° hue stride, uniform L=0.73 C=0.105)
  for (let i = 1; i <= 12; i++) {
    const hue = (i - 1) * 30
    const label = KEEPER_HUE_NAMES[i - 1]
    out.push(t(`k-${i}`, `oklch(0.730 0.105 ${hue})`, 'raw', 'color', `Keeper slot ${i} · H=${hue}° (${label})`))
  }

  // Typography — zero external webfont downloads on body; local JetBrains Mono for code/numbers
  out.push(t(
    'font-sans',
    'ui-sans-serif, -apple-system, BlinkMacSystemFont, "Pretendard Variable", "Pretendard", "Apple SD Gothic Neo", "Malgun Gothic", system-ui, sans-serif',
    'raw',
    'typography',
  ))
  out.push(t(
    'font-mono',
    '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, Consolas, monospace',
    'raw',
    'typography',
  ))

  for (const px of [10, 11, 12, 13, 14, 16, 20, 28]) {
    out.push(t(`fs-${px}`, `${px}px`, 'raw', 'dimension'))
  }
  out.push(t('font-size-3xs', '10px', 'raw', 'dimension'))
  out.push(t('font-size-2xs', '11px', 'raw', 'dimension'))
  out.push(t('font-size-xs', '12px', 'raw', 'dimension'))
  out.push(t('font-size-sm', '13px', 'raw', 'dimension'))
  out.push(t('font-size-base', '14px', 'raw', 'dimension'))
  out.push(t('font-size-md', '15px', 'raw', 'dimension'))
  out.push(t('font-size-lg', '16px', 'raw', 'dimension'))

  out.push(t('lh-tight', '1.25', 'raw', 'number'))
  out.push(t('lh-body', '1.5', 'raw', 'number', 'Hangul-safe body leading'))
  out.push(t('lh-loose', '1.65', 'raw', 'number'))

  // 4px spacing scale (6 tokens)
  out.push(t('sp-1', '4px', 'raw', 'dimension'))
  out.push(t('sp-2', '8px', 'raw', 'dimension'))
  out.push(t('sp-3', '12px', 'raw', 'dimension'))
  out.push(t('sp-4', '16px', 'raw', 'dimension'))
  out.push(t('sp-5', '24px', 'raw', 'dimension'))
  out.push(t('sp-6', '32px', 'raw', 'dimension'))
  out.push(t('grid-unit', '8px', 'raw', 'dimension'))

  // Radius
  out.push(t('r-0', '2px', 'raw', 'dimension'))
  out.push(t('r-1', '4px', 'raw', 'dimension'))
  out.push(t('r-2', '6px', 'raw', 'dimension'))
  out.push(t('r-3', '10px', 'raw', 'dimension'))
  out.push(t('radius-xs', '2px', 'raw', 'dimension'))
  out.push(t('radius-sm', '4px', 'raw', 'dimension'))
  out.push(t('radius-md', '6px', 'raw', 'dimension'))
  out.push(t('radius-lg', '10px', 'raw', 'dimension'))
  out.push(t('radius-pill', '999px', 'raw', 'dimension'))
  out.push(t('radius-circle', '50%', 'raw', 'dimension'))

  // Motion
  out.push(t('t-fast', '120ms', 'raw', 'duration'))
  out.push(t('t-med', '200ms', 'raw', 'duration'))
  out.push(t('t-slow', '320ms', 'raw', 'duration'))
  out.push(t('ease', 'cubic-bezier(0.2, 0.7, 0.2, 1)', 'raw', 'easing'))
  out.push(t('ease-out', 'cubic-bezier(0.16, 1, 0.3, 1)', 'raw', 'easing'))
  out.push(t('ease-in', 'cubic-bezier(0.7, 0, 0.84, 0)', 'raw', 'easing'))
  out.push(t('ease-inout', 'cubic-bezier(0.65, 0, 0.35, 1)', 'raw', 'easing'))

  // Z-index layers
  out.push(t('z-base', '1', 'raw', 'number'))
  out.push(t('z-sticky', '20', 'raw', 'number'))
  out.push(t('z-dropdown', '30', 'raw', 'number'))
  out.push(t('z-overlay', '40', 'raw', 'number'))
  out.push(t('z-drawer', '60', 'raw', 'number'))
  out.push(t('z-modal', '80', 'raw', 'number'))
  out.push(t('z-toast', '100', 'raw', 'number'))

  return Object.freeze(out)
})()

// ─────────────────────────────────────────────────────────────────────────
// Semantic & Component Role tokens — pure var() / color-mix(in oklch, ...)
// ─────────────────────────────────────────────────────────────────────────

export const semantic: ReadonlyArray<TokenBase> = (() => {
  const out: TokenBase[] = []

  // Status soft tints & borders (OKLCH color-mix, 0 raw hex)
  for (const name of ['ok', 'warn', 'err', 'info', 'stalled', 'idle', 'brass'] as const) {
    const base = name === 'brass' ? 'brass-1' : name
    out.push(t(`${name}-soft`, mix(base, 14), 'semantic', 'color'))
    out.push(t(`${name}-border`, mix(base, 36), 'semantic', 'color'))
    if (name === 'brass') {
      out.push(t('brass-fg', 'var(--brass-1)', 'semantic', 'color'))
    }
  }

  // Keeper 12-slot soft-tinted chips (16% bg / 35% border per #29 V3)
  for (let i = 1; i <= 12; i++) {
    out.push(t(`k-${i}-soft`, mix(`k-${i}`, 16), 'semantic', 'color'))
    out.push(t(`k-${i}-border`, mix(`k-${i}`, 35), 'semantic', 'color'))
    out.push(t(`kp${i}`, `var(--k-${i})`, 'role', 'color'))
    out.push(t(`kp${i}-soft`, `var(--k-${i}-soft)`, 'role', 'color'))
    out.push(t(`kp${i}-border`, `var(--k-${i}-border)`, 'role', 'color'))
    out.push(t(`color-keeper-${i}`, `var(--k-${i})`, 'role', 'color'))
  }

  // Surface / Ink / Border semantic roles
  out.push(t('color-bg-page', 'var(--bg-0)', 'role', 'color'))
  out.push(t('color-bg-surface', 'var(--bg-1)', 'role', 'color'))
  out.push(t('color-bg-panel-alt', 'var(--bg-2)', 'role', 'color'))
  out.push(t('color-bg-elevated', 'var(--bg-3)', 'role', 'color'))
  out.push(t('color-bg-hover', 'var(--bg-4)', 'role', 'color'))

  out.push(t('color-fg-primary', 'var(--fg-1)', 'role', 'color'))
  out.push(t('color-fg-secondary', 'var(--fg-2)', 'role', 'color'))
  out.push(t('color-fg-muted', 'var(--fg-3)', 'role', 'color'))
  out.push(t('color-fg-disabled', 'var(--fg-4)', 'role', 'color'))

  out.push(t('color-border-default', 'var(--line-1)', 'role', 'color'))
  out.push(t('color-border-strong', 'var(--line-2)', 'role', 'color'))
  out.push(t('color-border-divider', 'var(--line-3)', 'role', 'color'))

  out.push(t('color-accent-fg', 'var(--brass-1)', 'role', 'color'))
  out.push(t('color-accent-fg-dim', 'var(--brass-3)', 'role', 'color'))
  out.push(t('color-accent-brass', 'var(--brass-1)', 'role', 'color'))
  out.push(t('color-accent-soft', 'var(--brass-soft)', 'role', 'color'))
  out.push(t('color-focus-ring', 'var(--focus)', 'role', 'color'))

  out.push(t('color-status-ok', 'var(--ok)', 'role', 'color'))
  out.push(t('color-status-warn', 'var(--warn)', 'role', 'color'))
  out.push(t('color-status-err', 'var(--err-fg)', 'role', 'color'))
  out.push(t('color-status-info', 'var(--info)', 'role', 'color'))
  out.push(t('color-status-idle', 'var(--idle)', 'role', 'color'))
  out.push(t('color-status-stalled', 'var(--stalled)', 'role', 'color'))
  out.push(t('color-status-added', 'var(--ok)', 'role', 'color'))
  out.push(t('color-status-modified', 'var(--warn)', 'role', 'color'))
  out.push(t('color-status-deleted', 'var(--err-fg)', 'role', 'color'))

  // Compat alpha helpers via OKLCH color-mix (keeps existing Tailwind arbitrary classes working)
  out.push(t('color-ok', 'var(--ok)', 'role', 'color'))
  out.push(t('color-warn', 'var(--warn)', 'role', 'color'))
  out.push(t('color-err', 'var(--err-fg)', 'role', 'color'))
  out.push(t('color-info', 'var(--info)', 'role', 'color'))
  out.push(t('color-ok-soft', 'var(--ok-soft)', 'role', 'color'))
  out.push(t('color-warn-soft', 'var(--warn-soft)', 'role', 'color'))
  out.push(t('color-err-soft', 'var(--err-soft)', 'role', 'color'))
  out.push(t('color-info-soft', 'var(--info-soft)', 'role', 'color'))
  out.push(t('color-info-fg', 'var(--info-fg)', 'role', 'color'))
  out.push(t('color-info-border', 'var(--info-border)', 'role', 'color'))
  out.push(t('color-brass-fg', 'var(--brass-1)', 'role', 'color'))
  out.push(t('color-brass-soft', 'var(--brass-soft)', 'role', 'color'))
  out.push(t('color-brass-border', 'var(--brass-border)', 'role', 'color'))
  out.push(t('color-text-body', 'var(--fg-2)', 'role', 'color'))
  out.push(t('color-text-muted', 'var(--fg-3)', 'role', 'color'))
  out.push(t('color-text-dim', 'var(--fg-3)', 'role', 'color'))

  out.push(t('ok-10', mix('ok', 10), 'role', 'color'))
  out.push(t('ok-20', mix('ok', 20), 'role', 'color'))
  out.push(t('warn-10', mix('warn', 10), 'role', 'color'))
  out.push(t('warn-14', mix('warn', 14), 'role', 'color'))
  out.push(t('warn-24', mix('warn', 24), 'role', 'color'))
  out.push(t('bad-10', mix('err', 10), 'role', 'color'))
  out.push(t('bad-20', mix('err', 20), 'role', 'color'))
  out.push(t('bad-30', mix('err', 30), 'role', 'color'))
  out.push(t('bad-light', 'var(--err-fg)', 'role', 'color'))
  out.push(t('warn-bright', 'var(--warn)', 'role', 'color'))
  out.push(t('accent-12', mix('brass-1', 12), 'role', 'color'))
  out.push(t('accent-20', mix('brass-1', 20), 'role', 'color'))
  out.push(t('accent-30', mix('brass-1', 30), 'role', 'color'))
  out.push(t('white-4', mix('fg-1', 4), 'role', 'color'))
  out.push(t('white-6', mix('fg-1', 6), 'role', 'color'))
  out.push(t('white-8', mix('fg-1', 8), 'role', 'color'))

  // Interactive component slots (Bone CTA primary, steel-ice focus)
  out.push(t('button-primary-bg', 'var(--cta-bg)', 'role', 'color'))
  out.push(t('button-primary-fg', 'var(--cta-fg)', 'role', 'color'))
  out.push(t('button-primary-border', 'transparent', 'role', 'color'))
  out.push(t('button-primary-bg-hover', 'var(--cta-bg-hover)', 'role', 'color'))
  out.push(t('button-primary-bg-pressed', 'var(--cta-bg)', 'role', 'color'))

  out.push(t('button-ghost-bg', 'var(--white-4)', 'role', 'color'))
  out.push(t('button-ghost-fg', 'var(--fg-1)', 'role', 'color'))
  out.push(t('button-ghost-border', 'var(--line-1)', 'role', 'color'))
  out.push(t('button-ghost-bg-hover', 'var(--white-8)', 'role', 'color'))
  out.push(t('button-ghost-bg-pressed', 'var(--bg-4)', 'role', 'color'))

  out.push(t('button-danger-bg', 'var(--err-soft)', 'role', 'color'))
  out.push(t('button-danger-fg', 'var(--err-fg)', 'role', 'color'))
  out.push(t('button-danger-border', 'var(--err-border)', 'role', 'color'))
  out.push(t('button-danger-bg-hover', 'var(--bad-20)', 'role', 'color'))
  out.push(t('button-danger-bg-pressed', 'var(--bad-30)', 'role', 'color'))

  out.push(t('button-ok-bg', 'var(--ok-soft)', 'role', 'color'))
  out.push(t('button-ok-fg', 'var(--ok-fg)', 'role', 'color'))
  out.push(t('button-ok-border', 'var(--ok-border)', 'role', 'color'))
  out.push(t('button-ok-bg-hover', 'var(--ok-20)', 'role', 'color'))
  out.push(t('button-ok-bg-pressed', 'var(--ok-20)', 'role', 'color'))

  out.push(t('button-warn-bg', 'var(--warn-soft)', 'role', 'color'))
  out.push(t('button-warn-fg', 'var(--warn-fg)', 'role', 'color'))
  out.push(t('button-warn-border', 'var(--warn-border)', 'role', 'color'))
  out.push(t('button-warn-bg-hover', 'var(--warn-24)', 'role', 'color'))
  out.push(t('button-warn-bg-pressed', 'var(--warn-24)', 'role', 'color'))

  out.push(t('button-subtle-bg', 'transparent', 'role', 'color'))
  out.push(t('button-subtle-fg', 'var(--fg-3)', 'role', 'color'))
  out.push(t('button-subtle-border', 'transparent', 'role', 'color'))
  out.push(t('button-subtle-bg-hover', 'var(--white-6)', 'role', 'color'))
  out.push(t('button-subtle-bg-pressed', 'var(--white-8)', 'role', 'color'))

  out.push(t('input-bg', 'var(--bg-1)', 'role', 'color'))
  out.push(t('input-fg', 'var(--fg-1)', 'role', 'color'))
  out.push(t('input-border', 'var(--line-1)', 'role', 'color'))
  out.push(t('input-bg-hover', 'var(--bg-2)', 'role', 'color'))
  out.push(t('input-bg-focus', 'var(--bg-0)', 'role', 'color'))
  out.push(t('input-placeholder', 'var(--fg-4)', 'role', 'color'))
  out.push(t('input-border-focus', 'var(--focus)', 'role', 'color'))

  out.push(t('dialog-panel-bg', 'var(--bg-2)', 'role', 'color'))
  out.push(t('dialog-panel-border', 'var(--line-2)', 'role', 'color'))
  out.push(t('dialog-overlay-bg', 'oklch(0 0 0 / 0.56)', 'role', 'color'))
  out.push(t('toast-bg', 'var(--bg-3)', 'role', 'color'))
  out.push(t('toast-fg', 'var(--fg-1)', 'role', 'color'))
  out.push(t('toast-border', 'var(--line-2)', 'role', 'color'))

  out.push(t('focus-ring', '0 0 0 2px color-mix(in oklch, var(--focus) 55%, transparent)', 'role', 'shadow'))
  out.push(t('focus-ring-err', '0 0 0 2px color-mix(in oklch, var(--err-fg) 60%, transparent)', 'role', 'shadow'))
  out.push(t('shadow-1', '0 1px 2px oklch(0 0 0 / 0.35)', 'role', 'shadow'))
  out.push(t('shadow-2', '0 6px 18px oklch(0 0 0 / 0.45)', 'role', 'shadow'))
  out.push(t('shadow-3', '0 16px 40px oklch(0 0 0 / 0.55)', 'role', 'shadow'))

  // Mobile operator controls keep a 44px minimum touch target
  out.push(t('mobile-touch-target-min', '44px', 'role', 'dimension', 'minimum hit target for mobile operator controls'))

  return Object.freeze(out)
})()

// ─────────────────────────────────────────────────────────────────────────
// Themes: Warm Archival Paper (light) + Static High-Contrast (dark & light)
// ─────────────────────────────────────────────────────────────────────────

const lightTokens: ReadonlyArray<TokenBase> = (() => {
  const out: TokenBase[] = [
    t('bg-0', 'oklch(0.975 0.005 75)', 'raw', 'color', 'Warm Archival Paper canvas'),
    t('bg-1', 'oklch(0.955 0.006 75)', 'raw', 'color', 'topbar / nav rail'),
    t('bg-2', 'oklch(0.930 0.007 75)', 'raw', 'color', 'panel surface'),
    t('bg-3', 'oklch(0.900 0.008 75)', 'raw', 'color', 'elevated card'),
    t('bg-4', 'oklch(0.865 0.009 75)', 'raw', 'color', 'hover / active row'),
    t('line-1', 'oklch(0.840 0.010 75)', 'raw', 'color'),
    t('line-2', 'oklch(0.760 0.012 75)', 'raw', 'color'),
    t('line-3', 'oklch(0.670 0.014 75)', 'raw', 'color'),
    t('fg-1', 'oklch(0.200 0.010 70)', 'raw', 'color', 'primary archival ink'),
    t('fg-2', 'oklch(0.350 0.010 70)', 'raw', 'color'),
    t('fg-3', 'oklch(0.490 0.009 70)', 'raw', 'color'),
    t('fg-4', 'oklch(0.620 0.008 70)', 'raw', 'color'),
    t('cta-bg', 'oklch(0.210 0.010 70)', 'raw', 'color'),
    t('cta-fg', 'oklch(0.975 0.005 75)', 'raw', 'color'),
    t('cta-bg-hover', 'oklch(0.290 0.010 70)', 'raw', 'color'),
    t('focus', 'oklch(0.500 0.140 245)', 'raw', 'color'),
    t('brass-1', 'oklch(0.540 0.130 74)', 'raw', 'color'),
    t('brass-2', 'oklch(0.470 0.120 72)', 'raw', 'color'),
    t('brass-3', 'oklch(0.400 0.100 70)', 'raw', 'color'),
    t('ok', 'oklch(0.480 0.130 152)', 'raw', 'color'),
    t('ok-fg', 'oklch(0.420 0.130 152)', 'raw', 'color'),
    t('warn', 'oklch(0.580 0.150 90)', 'raw', 'color'),
    t('warn-fg', 'oklch(0.480 0.140 88)', 'raw', 'color'),
    t('err', 'oklch(0.520 0.170 24)', 'raw', 'color'),
    t('err-fg', 'oklch(0.460 0.175 24)', 'raw', 'color'),
    t('info', 'oklch(0.490 0.130 238)', 'raw', 'color'),
    t('info-fg', 'oklch(0.430 0.135 238)', 'raw', 'color'),
    t('stalled', 'oklch(0.490 0.130 310)', 'raw', 'color'),
    t('stalled-fg', 'oklch(0.430 0.135 310)', 'raw', 'color'),
    t('idle', 'oklch(0.520 0.008 72)', 'raw', 'color'),
    t('idle-fg', 'oklch(0.460 0.008 72)', 'raw', 'color'),
  ]
  for (let i = 1; i <= 12; i++) {
    const hue = (i - 1) * 30
    out.push(t(`k-${i}`, `oklch(0.470 0.115 ${hue})`, 'raw', 'color'))
  }
  return Object.freeze(out)
})()

const highContrastDarkTokens: ReadonlyArray<TokenBase> = Object.freeze([
  t('bg-0', 'oklch(0.080 0.000 0)', 'raw', 'color', 'HC dark canvas (APCA Lc >= 90)'),
  t('bg-1', 'oklch(0.115 0.000 0)', 'raw', 'color'),
  t('bg-2', 'oklch(0.145 0.000 0)', 'raw', 'color'),
  t('bg-3', 'oklch(0.180 0.000 0)', 'raw', 'color'),
  t('bg-4', 'oklch(0.220 0.000 0)', 'raw', 'color'),
  t('line-1', 'oklch(0.580 0.004 70)', 'raw', 'color'),
  t('line-2', 'oklch(0.740 0.004 70)', 'raw', 'color'),
  t('line-3', 'oklch(0.860 0.004 70)', 'raw', 'color'),
  t('fg-1', 'oklch(0.990 0.000 0)', 'raw', 'color'),
  t('fg-2', 'oklch(0.915 0.004 75)', 'raw', 'color'),
  t('fg-3', 'oklch(0.820 0.004 75)', 'raw', 'color'),
  t('fg-4', 'oklch(0.670 0.004 72)', 'raw', 'color'),
  t('cta-bg', 'oklch(0.985 0.000 0)', 'raw', 'color'),
  t('cta-fg', 'oklch(0.080 0.000 0)', 'raw', 'color'),
  t('focus', 'oklch(0.840 0.140 245)', 'raw', 'color'),
  t('brass-1', 'oklch(0.860 0.150 74)', 'raw', 'color'),
  t('ok', 'oklch(0.830 0.150 152)', 'raw', 'color'),
  t('ok-fg', 'oklch(0.890 0.140 152)', 'raw', 'color'),
  t('warn', 'oklch(0.900 0.160 95)', 'raw', 'color'),
  t('warn-fg', 'oklch(0.930 0.150 95)', 'raw', 'color'),
  t('err', 'oklch(0.770 0.175 24)', 'raw', 'color'),
  t('err-fg', 'oklch(0.830 0.170 24)', 'raw', 'color'),
  t('info', 'oklch(0.830 0.135 238)', 'raw', 'color'),
  t('info-fg', 'oklch(0.880 0.125 238)', 'raw', 'color'),
  t('stalled', 'oklch(0.820 0.140 310)', 'raw', 'color'),
  t('stalled-fg', 'oklch(0.880 0.130 310)', 'raw', 'color'),
])

const highContrastLightTokens: ReadonlyArray<TokenBase> = Object.freeze([
  t('bg-0', 'oklch(0.995 0.000 0)', 'raw', 'color', 'HC light canvas (APCA Lc >= 90)'),
  t('bg-1', 'oklch(0.975 0.000 0)', 'raw', 'color'),
  t('bg-2', 'oklch(0.950 0.000 0)', 'raw', 'color'),
  t('bg-3', 'oklch(0.915 0.000 0)', 'raw', 'color'),
  t('bg-4', 'oklch(0.875 0.000 0)', 'raw', 'color'),
  t('line-1', 'oklch(0.450 0.004 70)', 'raw', 'color'),
  t('line-2', 'oklch(0.280 0.004 70)', 'raw', 'color'),
  t('line-3', 'oklch(0.160 0.004 70)', 'raw', 'color'),
  t('fg-1', 'oklch(0.100 0.000 0)', 'raw', 'color'),
  t('fg-2', 'oklch(0.200 0.004 70)', 'raw', 'color'),
  t('fg-3', 'oklch(0.320 0.004 70)', 'raw', 'color'),
  t('fg-4', 'oklch(0.460 0.004 70)', 'raw', 'color'),
  t('cta-bg', 'oklch(0.100 0.000 0)', 'raw', 'color'),
  t('cta-fg', 'oklch(0.995 0.000 0)', 'raw', 'color'),
  t('focus', 'oklch(0.400 0.165 245)', 'raw', 'color'),
  t('brass-1', 'oklch(0.430 0.145 74)', 'raw', 'color'),
  t('ok', 'oklch(0.380 0.145 152)', 'raw', 'color'),
  t('ok-fg', 'oklch(0.320 0.145 152)', 'raw', 'color'),
  t('warn', 'oklch(0.450 0.155 88)', 'raw', 'color'),
  t('warn-fg', 'oklch(0.380 0.150 86)', 'raw', 'color'),
  t('err', 'oklch(0.420 0.180 24)', 'raw', 'color'),
  t('err-fg', 'oklch(0.360 0.185 24)', 'raw', 'color'),
  t('info', 'oklch(0.390 0.145 238)', 'raw', 'color'),
  t('info-fg', 'oklch(0.330 0.150 238)', 'raw', 'color'),
  t('stalled', 'oklch(0.390 0.145 310)', 'raw', 'color'),
  t('stalled-fg', 'oklch(0.330 0.150 310)', 'raw', 'color'),
])

export const themes: ReadonlyArray<Theme> = Object.freeze([
  {
    id: 'light',
    selector: '[data-theme="light"]',
    mode: 'light',
    tokens: lightTokens,
  },
  {
    id: 'high-contrast-dark',
    selector: ':root[data-contrast="high"]',
    media: '(prefers-contrast: more)',
    mode: 'dark',
    tokens: highContrastDarkTokens,
  },
  {
    id: 'high-contrast-light',
    selector: '[data-theme="light"][data-contrast="high"]',
    media: '(prefers-contrast: more)',
    mode: 'light',
    tokens: highContrastLightTokens,
  },
])

export interface TokenSource {
  readonly raw: ReadonlyArray<TokenBase>
  readonly semantic: ReadonlyArray<TokenBase>
  readonly themes: ReadonlyArray<Theme>
}

export const source: TokenSource = Object.freeze({
  raw,
  semantic,
  themes,
})
