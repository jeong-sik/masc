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

export type RailState = 'ok' | 'warn' | 'bad' | 'idle'

export interface RailPill {
  key: 'token' | 'process' | 'gate' | 'bindings'
  state: RailState
  label: string
  detail: string
  hint: string | null
  onClick: () => void
}

const TONE: Record<RailState, { bg: string; border: string; text: string; dot: string; icon: string }> = {
  ok: {
    bg: 'bg-emerald-500/10',
    border: 'border-emerald-400/40',
    text: 'text-emerald-100',
    dot: 'bg-emerald-400',
    icon: '✓',
  },
  warn: {
    bg: 'bg-amber-500/10',
    border: 'border-amber-400/40',
    text: 'text-amber-100',
    dot: 'bg-amber-400',
    icon: '!',
  },
  bad: {
    bg: 'bg-rose-500/10',
    border: 'border-rose-400/40',
    text: 'text-rose-100',
    dot: 'bg-rose-400',
    icon: '⊘',
  },
  idle: {
    bg: 'bg-[var(--white-3)]',
    border: 'border-[var(--white-8)]',
    text: 'text-[var(--text-dim)]',
    dot: 'bg-[var(--white-10)]',
    icon: '·',
  },
}

function Pill({ pill }: { pill: RailPill }) {
  const tone = TONE[pill.state]
  return html`
    <button
      type="button"
      class=${`group flex min-w-0 flex-1 cursor-pointer items-center gap-2 rounded-md border px-2.5 py-1.5 text-left transition-colors ${tone.bg} ${tone.border} hover:brightness-125`}
      title=${pill.hint ?? pill.detail}
      onClick=${pill.onClick}
      data-rail-pill=${pill.key}
      data-rail-state=${pill.state}
    >
      <span class=${`flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-[11px] font-bold ${tone.dot} text-[var(--bg-0)]`}>
        ${tone.icon}
      </span>
      <span class="min-w-0 flex-1">
        <span class=${`block text-[10px] uppercase tracking-[0.14em] ${tone.text}`}>${pill.label}</span>
        <span class="block truncate text-[11px] text-[var(--text-body)]">${pill.detail}</span>
      </span>
    </button>
  `
}

export function ConnectorReadinessRail({ pills }: { pills: RailPill[] }) {
  return html`
    <div class="mt-2 flex flex-wrap items-stretch gap-2">
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
export interface RailInputs {
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

export function deriveRail(input: RailInputs, on: RailHandlers): RailPill[] {
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
    },
    {
      key: 'process',
      state: processState,
      label: 'Process',
      detail: processDetail,
      hint: processState === 'bad' ? '클릭하면 sidecar Start' : '클릭하면 sidecar Stop',
      onClick: on.toggleProcess,
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
      label: 'Bindings',
      detail: bindingsDetail,
      hint: bindingsState !== 'ok' ? 'keeper 디렉토리로 스크롤' : null,
      onClick: on.scrollToBindings,
    },
  ]
}
