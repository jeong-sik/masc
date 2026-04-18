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
//   warn  — set up but not live (running sidecar with no bindings, etc.)
//   bad   — actively missing / broken (red)
//   idle  — unknown / not measured yet (gray)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'

type RailState = 'ok' | 'warn' | 'bad' | 'idle'
export type RailKey = 'token' | 'process' | 'gate' | 'bindings'

/** Per-connector × per-pill in-flight tracker. Subscribed by deriveRail
    callers so a click on the Process pill can flip the pill into a
    pulsing "진행 중..." state until the underlying action settles. */
const inflightState = signal<Record<string, Partial<Record<RailKey, boolean>>>>({})

export function markRailInflight(connectorId: string, key: RailKey) {
  const cur = inflightState.value[connectorId] ?? {}
  inflightState.value = { ...inflightState.value, [connectorId]: { ...cur, [key]: true } }
}

export function clearRailInflight(connectorId: string, key: RailKey) {
  const cur = inflightState.value[connectorId] ?? {}
  if (!cur[key]) return
  const next = { ...cur }
  delete next[key]
  inflightState.value = { ...inflightState.value, [connectorId]: next }
}

export function getRailInflight(connectorId: string): Partial<Record<RailKey, boolean>> {
  return inflightState.value[connectorId] ?? {}
}

export function resetRailInflightState() {
  inflightState.value = {}
}

/** Wrap an async action so the pill it backs pulses for its duration.
    Helper for callers that don't want to remember mark/clear. */
export async function withRailInflight<T>(connectorId: string, key: RailKey, fn: () => Promise<T>): Promise<T> {
  markRailInflight(connectorId, key)
  try {
    return await fn()
  } finally {
    clearRailInflight(connectorId, key)
  }
}

export interface RailPill {
  key: 'token' | 'process' | 'gate' | 'bindings'
  state: RailState
  label: string
  detail: string
  hint: string | null
  onClick: () => void
  /** Action triggered by clicking this pill is currently in flight.
      Renders a muted pulse + spinner glyph instead of the state icon. */
  inflight?: boolean
}

const TONE: Record<RailState, { bg: string; border: string; text: string; dot: string; icon: string; gradient: string }> = {
  ok: {
    bg: 'bg-emerald-500/10',
    border: 'border-emerald-400/40',
    text: 'text-[var(--ok)]',
    dot: 'bg-emerald-400',
    icon: '✓',
    // Grafana Stat panel "Background Gradient" mode — subtle vertical
    // fade from the state's tone into the card surface so the pill
    // reads as a threshold color zone, not a flat chip.
    gradient: 'bg-gradient-to-b from-emerald-500/15 to-emerald-500/0',
  },
  warn: {
    bg: 'bg-amber-500/10',
    border: 'border-amber-400/40',
    text: 'text-[var(--warn)]',
    dot: 'bg-amber-400',
    icon: '!',
    gradient: 'bg-gradient-to-b from-amber-500/15 to-amber-500/0',
  },
  bad: {
    bg: 'bg-rose-500/10',
    border: 'border-rose-400/40',
    text: 'text-[var(--bad-light)]',
    dot: 'bg-rose-400',
    icon: '⊘',
    gradient: 'bg-gradient-to-b from-rose-500/15 to-rose-500/0',
  },
  idle: {
    bg: 'bg-[var(--white-3)]',
    border: 'border-[var(--white-8)]',
    text: 'text-[var(--text-dim)]',
    dot: 'bg-[var(--white-10)]',
    icon: '·',
    gradient: 'bg-gradient-to-b from-[var(--white-4)] to-[var(--white-2)]',
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
    technology reads "Token — 설정됨 (sidecar 부팅 통과). 클릭하면 Config" instead
    of just "Token" (which is what a button with only visible <span>
    children would otherwise expose). Kept pure so tests can pin the
    concatenation rules without mounting a DOM. */
export function railPillAriaLabel(pill: RailPill): string {
  const detail = pill.inflight === true ? '진행 중' : pill.detail
  const parts = [pill.label, detail]
  if (pill.hint !== null) parts.push(pill.hint)
  return parts.join(' — ')
}

function Pill({ pill }: { pill: RailPill }) {
  const tone = TONE[pill.state]
  const inflight = pill.inflight === true
  // Grafana Stat panel layout — vertical stack (icon dominates, label
  // secondary) with a threshold-color gradient background. Detail moves
  // entirely to `title` + aria-label so a narrow tile can never render
  // "BINDIN k.." or "TOKEN 설." — the label is always the full word and
  // the detail is always the full sentence, no matter the column width.
  // Keyboard focus ring uses the accent token (PatternFly AA target:
  // visible 2px ring on :focus-visible only). aria-busy announces
  // "진행 중…" to AT without a separate visually-hidden span.
  return html`
    <button
      type="button"
      class=${`group flex min-w-0 flex-1 cursor-pointer flex-col items-center gap-1 overflow-hidden rounded-md border px-1.5 py-2 text-center transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent-1)] ${tone.gradient} ${tone.border} hover:brightness-125 ${inflight ? 'animate-pulse' : ''}`}
      title=${pill.hint ?? pill.detail}
      aria-label=${railPillAriaLabel(pill)}
      aria-busy=${inflight ? 'true' : 'false'}
      onClick=${pill.onClick}
      data-rail-pill=${pill.key}
      data-rail-state=${pill.state}
      data-rail-inflight=${inflight ? 'true' : 'false'}
      data-rail-layout="stat-tile"
      disabled=${inflight}
    >
      <span
        aria-hidden="true"
        class=${`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[12px] font-bold ${inflight ? 'bg-[var(--white-10)]' : tone.dot} text-[var(--bg-0)]`}
      >
        ${inflight ? '…' : tone.icon}
      </span>
      <span
        aria-hidden="true"
        class=${`block text-[10px] uppercase tracking-[0.14em] ${tone.text}`}
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
    <div class="mt-2 grid grid-cols-4 items-stretch gap-2" data-rail-layout="grid-4">
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
  /** Sidecar process is up and reachable. */
  sidecarUp: boolean
  /** Channel Gate /health responded healthy. null = unknown. */
  gateHealthy: boolean | null
  /** Number of channel↔keeper bindings configured. */
  bindingCount: number
  /** Total keepers known to the directory (drives bindings warn vs idle). */
  keeperCount: number
}

export interface RailHandlers {
  openConfig: () => void
  toggleProcess: () => void
  expandHeader: () => void
  scrollToBindings: () => void
}

export function deriveRail(
  input: RailInputs,
  on: RailHandlers,
  inflight: Partial<Record<RailKey, boolean>> = {},
): RailPill[] {
  // Token: heuristic — if the sidecar is running, the operator has set
  // a valid token (the bridge would have crashed at startup otherwise).
  // If it's down we can't know, so we suggest setting one.
  const tokenState: RailState = input.sidecarUp ? 'ok' : 'bad'
  const tokenDetail = input.sidecarUp ? '설정됨 (sidecar 부팅 통과)' : '필요 — ⚙ Config 에서 입력'

  // Process
  const processState: RailState = input.sidecarUp ? 'ok' : 'bad'
  const processDetail = input.sidecarUp ? '🟢 실행 중' : '⊘ 정지'

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
      inflight: inflight.token === true,
    },
    {
      key: 'process',
      state: processState,
      label: 'Process',
      detail: processDetail,
      hint: processState === 'bad' ? '클릭하면 sidecar Start' : '클릭하면 sidecar Stop',
      onClick: on.toggleProcess,
      inflight: inflight.process === true,
    },
    {
      key: 'gate',
      state: gateState,
      label: 'Gate',
      detail: gateDetail,
      hint: '클릭하면 헤더 detail 펼침',
      onClick: on.expandHeader,
      inflight: inflight.gate === true,
    },
    {
      key: 'bindings',
      state: bindingsState,
      label: 'Bindings',
      detail: bindingsDetail,
      hint: bindingsState !== 'ok' ? 'keeper 디렉토리로 스크롤' : null,
      onClick: on.scrollToBindings,
      inflight: inflight.bindings === true,
    },
  ]
}
