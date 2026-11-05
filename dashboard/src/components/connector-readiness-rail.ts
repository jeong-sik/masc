// ConnectorReadinessRail — single horizontal status rail at the top of
// each connector card. Four pills (Token / Process / Gate / Bindings)
// answer "what state is this connector in" in one glance, and clicking
// a pill jumps to the action that resolves it. The rail intentionally
// duplicates information that's also discoverable through the per-card
// expand toggles — its job is to make the operator never have to drill
// in just to see what's wrong.
//
// Status mapping:
//   ok    — the thing is set up and live (green)
//   warn  — set up but not live (keepers exist but no channel is bound)
//   bad   — actively missing / broken (red)
//   idle  — unknown / not measured yet (gray)

import { html } from 'htm/preact'

type RailState = 'ok' | 'warn' | 'bad' | 'idle'

export interface RailPill {
  key: 'token' | 'process' | 'gate' | 'bindings'
  state: RailState
  label: string
  detail: string
  hint: string | null
  onClick: () => void
}

const TONE: Record<RailState, { bg: string; border: string; text: string; dot: string; icon: string; gradient: string }> = {
  ok: {
    bg: 'bg-[var(--ok-10)]',
    border: 'border-[var(--ok-border)]',
    text: 'text-[var(--color-status-ok)]',
    dot: 'bg-[var(--ok-10)]',
    icon: '✓',
    // Grafana Stat panel "Background Gradient" mode — subtle vertical
    // fade from the state's tone into the card surface so the pill
    // reads as a threshold color zone, not a flat chip.
    gradient: 'bg-gradient-to-b from-emerald-500/15 to-emerald-500/0',
  },
  warn: {
    bg: 'bg-[var(--warn-10)]',
    border: 'border-[var(--warn-20)]',
    text: 'text-[var(--color-status-warn)]',
    dot: 'bg-[var(--warn-10)]',
    icon: '!',
    gradient: 'bg-gradient-to-b from-amber-500/15 to-amber-500/0',
  },
  bad: {
    bg: 'bg-[var(--bad-10)]',
    border: 'border-[var(--err-border)]',
    text: 'text-[var(--bad-light)]',
    dot: 'bg-[var(--bad-10)]',
    icon: '⊘',
    gradient: 'bg-gradient-to-b from-rose-500/15 to-rose-500/0',
  },
  idle: {
    bg: 'bg-[var(--color-bg-surface)]',
    border: 'border-[var(--color-border-default)]',
    text: 'text-[var(--color-fg-disabled)]',
    dot: 'bg-[var(--color-bg-hover)]',
    icon: '·',
    gradient: 'bg-gradient-to-b from-[var(--color-bg-elevated)] to-[var(--color-bg-surface)]',
  },
}

/** Pure: map a rail state to the Grafana Stat panel style "threshold
    color zone" gradient class. Exposed so callers outside the rail
    (e.g. setup-guide cards, fleet tiles) can reuse the exact same
    tone-to-gradient mapping without forking the palette. */
export function statToneGradient(state: RailState): string {
  return TONE[state].gradient
}

/** Pure: compose a screen-reader label for the pill so assistive
    technology reads "Token — 게이트웨이 설정됨" instead
    of just "Token" (which is what a button with only visible <span>
    children would otherwise expose). Kept pure so tests can pin the
    concatenation rules without mounting a DOM. */
export function railPillAriaLabel(pill: RailPill): string {
  const parts = [pill.label, pill.detail]
  if (pill.hint !== null) parts.push(pill.hint)
  return parts.join(' — ')
}

function Pill({ pill }: { pill: RailPill }) {
  const tone = TONE[pill.state]
  // Grafana Stat panel layout — vertical stack (icon dominates, label
  // secondary) with a threshold-color gradient background. Detail moves
  // entirely to `title` + aria-label so a narrow tile can never render
  // "BINDIN k.." or "TOKEN 설." — the label is always the full word and
  // the detail is always the full sentence, no matter the column width.
  // Keyboard focus ring uses the accent token (PatternFly AA target:
  // visible 2px ring on :focus-visible only).
  return html`
    <button
      type="button"
      class=${`group flex min-w-0 flex-1 cursor-pointer flex-col items-center gap-1 overflow-hidden rounded-[var(--r-1)] border px-2 py-2.5 text-center transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--color-accent-fg)] ${tone.gradient} ${tone.border} hover:brightness-125`}
      title=${pill.hint ?? pill.detail}
      aria-label=${railPillAriaLabel(pill)}
      onClick=${pill.onClick}
      data-rail-pill=${pill.key}
      data-rail-state=${pill.state}
      data-rail-layout="stat-tile"
    >
      <span
        aria-hidden="true"
        class=${`flex h-6 w-6 shrink-0 items-center justify-center rounded-[var(--r-0)] text-sm font-bold ${tone.dot} text-[var(--color-bg-page)]`}
      >
        ${tone.icon}
      </span>
      <span
        aria-hidden="true"
        class=${`block text-2xs font-semibold uppercase tracking-4 ${tone.text}`}
      >${pill.label}</span>
    </button>
  `
}

export function ConnectorReadinessRail({ pills }: { pills: RailPill[] }) {
  // Grid (not flex-wrap) so all four pills share equal column widths. Under
  // flex-wrap, per-pill width depended on intrinsic content, which meant
  // short-label pills (Token) snapped tiny while long-label pills (Bindings)
  // blew out and wrapped mid-word ("BINDIN…", "필…"). A 4-column grid makes
  // every card's rail line up at the same cell boundaries across the 4-tile
  // strip, and labels truncate symmetrically when the tile is narrow instead
  // of each pill truncating at a different point.
  return html`
    <div class="mt-2 grid grid-cols-4 items-stretch gap-2 v2-connector-readiness-rail" data-rail-layout="grid-4">
      ${pills.map(pill => html`<${Pill} pill=${pill} />`)}
    </div>
  `
}

/**
 * Pure helper: derive the 4 pill states from connector flags.
 *
 * Inputs are passed in flat instead of taking a GateConnectorInfo so
 * the helper stays unit-testable without the full Gate API shape.
 */
interface RailInputs {
  /** The gateway has readable connection configuration. */
  gatewayAvailable: boolean
  /** Channel Gate /health responded healthy. null = unknown. */
  gateHealthy: boolean | null
  /** Number of channel↔keeper bindings configured. */
  bindingCount: number
  /** Total keepers known to the directory (drives bindings warn vs idle). */
  keeperCount: number
}

export interface RailHandlers {
  openConfig: () => void
  expandHeader: () => void
  scrollToBindings: () => void
}

export function deriveRail(input: RailInputs, on: RailHandlers): RailPill[] {
  const tokenState: RailState = input.gatewayAvailable ? 'ok' : 'bad'
  const tokenDetail = input.gatewayAvailable ? '게이트웨이 설정됨' : '필요 — ⚙ Config 에서 입력'

  // Process
  const processState: RailState = input.gatewayAvailable ? 'ok' : 'bad'
  const processDetail = input.gatewayAvailable ? '게이트웨이 설정됨' : '게이트웨이 설정 필요'
  const processHint = '클릭하면 서버 게이트웨이 상세 카드'

  // Gate
  let gateState: RailState
  let gateDetail: string
  if (input.gateHealthy === true) {
    gateState = 'ok'
    gateDetail = '/api/v1/gate/health → ok'
  } else if (input.gateHealthy === false) {
    gateState = 'bad'
    gateDetail = '/api/v1/gate/health → unhealthy'
  } else {
    gateState = 'idle'
    gateDetail = '아직 점검 안 됨'
  }

  // Bindings
  let bindingsState: RailState
  let bindingsDetail: string
  if (input.bindingCount > 0) {
    bindingsState = 'ok'
    bindingsDetail = `${input.bindingCount} 개 매핑됨`
  } else if (input.keeperCount > 0) {
    bindingsState = 'warn'
    bindingsDetail = `0 개 — 아래 keeper 섹션에서 채널 바인딩`
  } else {
    bindingsState = 'idle'
    bindingsDetail = 'keeper 디렉토리 비어있음'
  }

  return [
    {
      key: 'token',
      state: tokenState,
      label: 'Token',
      detail: tokenDetail,
      hint: tokenState === 'bad' ? '클릭하면 ⚙ Config 가 열립니다' : null,
      onClick: on.openConfig,
    },
    {
      key: 'process',
      state: processState,
      label: '프로세스',
      detail: processDetail,
      hint: processHint,
      onClick: on.expandHeader,
    },
    {
      key: 'gate',
      state: gateState,
      label: 'Gate',
      detail: gateDetail,
      hint: '클릭하면 헤더 detail 펼침',
      onClick: on.expandHeader,
    },
    {
      key: 'bindings',
      state: bindingsState,
      label: '바인딩',
      detail: bindingsDetail,
      hint: bindingsState !== 'ok' ? 'keeper 디렉토리로 스크롤' : null,
      onClick: on.scrollToBindings,
    },
  ]
}
