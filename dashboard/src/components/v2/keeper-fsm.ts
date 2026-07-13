// MASC v2 — Keeper lifecycle FSM tables (ported 1:1 from prototype data.jsx)
//
// The prototype's 12-state FSM drives every keeper's status dot tone, the
// breathing pulse, the hover gloss, and the operator action set. The live
// dashboard's `KeeperPhase` (types/core.ts) uses the same 12 states, so
// these tables map directly onto live keeper data. Unknown /
// null phases fall back to the idle/off bucket (a total display default —
// the prototype used the same `?? 'idle'` pattern), never throwing.
//
// All four lookup tables (PHASE_TONE / PHASE_PULSE / PHASE_INFO / FSM_ACTIONS)
// key on `KeeperPhase` (PascalCase). The
// closed-sum shape means: a future `KeeperPhase` variant added in core.ts
// fails TypeScript compilation here until this surface catches up — which
// is the whole point of the SSOT lift in iter-4. Public function signatures
// still accept `string | null | undefined` so live callers (which may emit
// unknown wire strings during rollout) keep working; the table access is
// type-guarded at the read site.

import type { KeeperPhase } from '../../types/core'

export type KeeperTone = 'ok' | 'warn' | 'bad' | 'busy' | 'idle'
export type KeeperCoarseStatus = 'run' | 'pause' | 'off'

// An operator-issued lifecycle action. `via` shows a transient phase first,
// then auto-advances to `to` after `ms`. Without `via`, the transition is
// instant. `danger` marks destructive (drain/stop) actions.
export interface FsmAction {
  readonly id: string
  readonly label: string
  readonly glyph: string
  readonly hint: string
  readonly to: string
  readonly via?: string
  readonly ms?: number
  readonly danger?: boolean
}

// The 12 canonical FSM phases (prototype FSM_STATES).
export const FSM_STATES = [
  'Offline',
  'Restarting',
  'Running',
  'Compacting',
  'HandingOff',
  'Failing',
  'Overflowed',
  'Draining',
  'Paused',
  'Stopped',
  'Crashed',
  'Dead',
] as const

// phase → status-dot tone (12 phases collapse into 5 buckets).
const PHASE_TONE: Readonly<Record<KeeperPhase, KeeperTone>> = {
  Running: 'ok',
  Paused: 'warn',
  Draining: 'warn',
  Compacting: 'busy',
  HandingOff: 'busy',
  Restarting: 'busy',
  Failing: 'bad',
  Overflowed: 'bad',
  Crashed: 'bad',
  Dead: 'bad',
  Stopped: 'idle',
  Offline: 'idle',
}

// phase → whether the dot breathes (active/transient phases only).
// Verbatim from prototype data.jsx:43-45.
const PHASE_PULSE: Readonly<Record<KeeperPhase, boolean>> = {
  Running: true,
  Compacting: true,
  HandingOff: true,
  Restarting: true,
  Failing: true,
  Paused: false,
  Draining: false,
  Overflowed: false,
  Crashed: false,
  Dead: false,
  Stopped: false,
  Offline: false,
}

// phase → KR hover gloss. 12 entries verbatim from prototype data.jsx:19-32.
const PHASE_INFO: Readonly<Record<KeeperPhase, string>> = {
  Offline: '오프라인 — 실행 중이 아님',
  Restarting: '재시작 중',
  Running: '실행 중 — 작업/라운드 순환',
  Compacting: '컨텍스트 압축 중',
  HandingOff: '작업을 다른 keeper 에게 인계하는 중',
  Failing: '실패 처리 중',
  Overflowed: '컨텍스트 윈도우 초과',
  Draining: '정상 종료를 위해 작업을 비우는 중',
  Paused: '슈퍼바이저가 일시정지함',
  Stopped: '중지됨',
  Crashed: '비정상 종료',
  Dead: '복구 불가 — 종료됨',
}

// Reusable action literals (shared across phases keeps the table honest).
const A_STOP: FsmAction = { id: 'stop', label: '중지', glyph: '⏹', via: 'Draining', to: 'Stopped', ms: 1500, danger: true, hint: '작업을 비우고 종료 (Drain → Stopped)' }

// phase → ordered operator actions. Phases absent here (Compacting,
// HandingOff, Draining, Restarting, Dead) expose no action — they are
// transient or terminal.
const FSM_ACTIONS: Readonly<Partial<Record<KeeperPhase, readonly FsmAction[]>>> = {
  Running: [
    { id: 'pause', label: '일시정지', glyph: '⏸', to: 'Paused', hint: '슈퍼바이저가 잠시 멈춤 — 컨텍스트·소유 태스크 보존, 즉시 재개 가능' },
    { id: 'compact', label: '컴팩션', glyph: '◉', via: 'Compacting', to: 'Running', ms: 1700, hint: '컨텍스트를 지금 압축하고 실행 복귀' },
    { id: 'handoff', label: '핸드오프', glyph: '⇄', via: 'HandingOff', to: 'Stopped', ms: 1700, hint: '소유 태스크를 인계하고 이 세션 정리' },
    A_STOP,
  ],
  Paused: [
    { id: 'resume', label: '재개', glyph: '▶', to: 'Running', hint: '멈춘 지점부터 다시 실행' },
    A_STOP,
  ],
  Overflowed: [
    { id: 'compact', label: '컴팩션', glyph: '◉', via: 'Compacting', to: 'Running', ms: 2000, hint: '윈도우 초과 — 압축으로 복구' },
    { ...A_STOP, hint: '복구 대신 종료' },
  ],
  Failing: [
    { id: 'restart', label: '재시작', glyph: '↻', via: 'Restarting', to: 'Running', ms: 1700, hint: '실패 처리 후 재시작' },
    { ...A_STOP, hint: '종료' },
  ],
  Crashed: [
    { id: 'restart', label: '재시작', glyph: '↻', via: 'Restarting', to: 'Running', ms: 1800, hint: '비정상 종료 — 재시작 시도' },
  ],
  Stopped: [
    { id: 'start', label: '시작', glyph: '▶', via: 'Restarting', to: 'Running', ms: 1500, hint: '중지된 keeper 새로 시작' },
  ],
  Offline: [
    { id: 'start', label: '시작', glyph: '▶', via: 'Restarting', to: 'Running', ms: 1500, hint: '오프라인 keeper 시작' },
  ],
}

const RUN_PHASES: ReadonlySet<KeeperPhase> = new Set<KeeperPhase>([
  'Running',
  'Compacting',
  'HandingOff',
  'Restarting',
  'Failing',
])
const PAUSE_PHASES: ReadonlySet<KeeperPhase> = new Set<KeeperPhase>(['Paused', 'Draining'])

/** phase → coarse status bucket (mirrors prototype phaseStatus). */
export function phaseStatus(phase: string | null | undefined): KeeperCoarseStatus {
  if (phase && isKeeperPhase(phase) && RUN_PHASES.has(phase)) return 'run'
  if (phase && isKeeperPhase(phase) && PAUSE_PHASES.has(phase)) return 'pause'
  return 'off'
}

export function phaseTone(phase: string | null | undefined): KeeperTone {
  return (phase && isKeeperPhase(phase) && PHASE_TONE[phase]) || 'idle'
}

export function phasePulse(phase: string | null | undefined): boolean {
  return !!(phase && isKeeperPhase(phase) && PHASE_PULSE[phase])
}

export function phaseInfo(phase: string | null | undefined): string {
  return (phase && isKeeperPhase(phase) && PHASE_INFO[phase]) || phase || '알 수 없음'
}

export function fsmActions(phase: string | null | undefined): readonly FsmAction[] {
  return (phase && isKeeperPhase(phase) && FSM_ACTIONS[phase]) || []
}

// Closed-sum guard. `phase` arrives from the live wire as `string | null`; we
// accept only the canonical PascalCase tokens of `KeeperPhase`. Unknown /
// null falls through to the function-level fallback. Own-property check via
// a null-prototype registry keeps the closed-sum boundary honest (rejects
// 'constructor', '__proto__', etc. that would otherwise pass `in KeeperPhase`).
function isKeeperPhase(phase: string): phase is KeeperPhase {
  return phase in KEEPER_PHASE_REGISTRY
}
const KEEPER_PHASE_REGISTRY: Readonly<Record<string, true>> = Object.freeze(
  Object.assign(Object.create(null), {
    Offline: true,
    Restarting: true,
    Running: true,
    Compacting: true,
    HandingOff: true,
    Failing: true,
    Overflowed: true,
    Draining: true,
    Paused: true,
    Stopped: true,
    Crashed: true,
    Dead: true,
  } as Record<string, true>),
)
