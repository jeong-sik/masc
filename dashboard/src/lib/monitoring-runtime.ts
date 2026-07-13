import type { Agent, Keeper, KeeperPhase, PipelineStage } from '../types'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import { parseAgentStatus } from './agent-status'
import { UNKNOWN_STATUS_LABEL } from './format-string'
import {
  deriveKeeperRuntimeProjection,
  type KeeperRuntimeProjection,
} from './keeper-runtime-projection'

export type RuntimeBand = 'active' | 'attention' | 'paused' | 'offline' | 'transient'

interface RuntimeBandMeta {
  key: RuntimeBand
  label: string
  description: string
}

interface PhaseMeta {
  key: string
  label: string
  description: string
}

interface StageMeta {
  key: string
  label: string
  description: string
}

export interface KeeperMonitoringSummary {
  band: RuntimeBandMeta
  phase: PhaseMeta
  stage: StageMeta
  hint: string | null
}

interface MonitoringEvidence {
  phase: PhaseMeta | null
  stage: StageMeta | null
}

const UNKNOWN_PHASE_META: PhaseMeta = {
  key: 'unknown',
  label: UNKNOWN_STATUS_LABEL,
  description: 'phase 정보가 부족해 수동 확인이 필요합니다.',
}

const OFFLINE_STAGE_META: StageMeta = {
  key: 'offline',
  label: '오프라인',
  description: '활동 정보를 확인하지 못했습니다.',
}

const PHASE_LABELS: Record<string, PhaseMeta> = {
  Offline: { key: 'Offline', label: '오프라인', description: '런타임이 올라오지 않았거나 연결 정보가 없습니다.' },
  Running: { key: 'Running', label: '실행중', description: 'keeper_state_machine 기준으로 정상 실행 상태입니다.' },
  Failing: { key: 'Failing', label: '오류중', description: '최근 실행에서 오류를 감지했습니다.' },
  Overflowed: { key: 'Overflowed', label: '컨텍스트초과', description: '프롬프트가 runtime 컨텍스트 한도를 넘겨 자동 복구가 필요합니다.' },
  Compacting: { key: 'Compacting', label: '압축중', description: '컨텍스트를 정리하는 중입니다.' },
  HandingOff: { key: 'HandingOff', label: '승계중', description: '새 세대로 넘기는 중입니다.' },
  Draining: { key: 'Draining', label: '종료중', description: '현재 작업을 마무리하는 중입니다.' },
  Paused: { key: 'Paused', label: '일시정지', description: 'keeper가 재개 대기 상태로 멈춰 있습니다.' },
  Stopped: { key: 'Stopped', label: '정지', description: '정상 정지된 런타임입니다.' },
  Crashed: { key: 'Crashed', label: '비정상종료', description: 'fiber가 비정상적으로 종료되었습니다.' },
  Restarting: { key: 'Restarting', label: '재시작중', description: '복구를 시도하고 있습니다.' },
  Dead: { key: 'Dead', label: '종료', description: '명시적인 tombstone으로 종료된 상태입니다.' },
  active: { key: 'active', label: '실행중', description: '프로세스는 살아 있지만 state projection이 부족합니다.' },
  busy: { key: 'busy', label: '작업중', description: '프로세스는 살아 있고 현재 작업을 수행 중입니다.' },
  listening: { key: 'listening', label: '대기중', description: '프로세스는 살아 있고 입력을 기다리고 있습니다.' },
  idle: { key: 'idle', label: '대기', description: '프로세스는 살아 있지만 현재 턴 작업은 없습니다.' },
  paused: { key: 'paused', label: '일시정지', description: 'keeper가 재개 대기 상태로 멈춰 있습니다.' },
  stopped: { key: 'stopped', label: '정지', description: '이전에 실행되었지만 현재는 정지 상태입니다.' },
  unbooted: { key: 'unbooted', label: '미기동', description: '등록만 되어 있고 아직 부팅되지 않았습니다.' },
  offline: { key: 'offline', label: '오프라인', description: '런타임 연결을 확인하지 못했습니다.' },
  unknown: UNKNOWN_PHASE_META,
}

// PipelineStage SSOT: `types/core.ts#PipelineStage` (11 values from
// `Keeper_status_runtime.pipeline_stage_of_phase`).
const STAGE_LABELS: Record<string, StageMeta> = {
  idle: { key: 'idle', label: '활동 없음', description: '지금 진행 중인 세부 활동 단계가 없습니다.' },
  compacting: { key: 'compacting', label: '압축', description: '컨텍스트 압축 단계를 수행 중입니다.' },
  handoff: { key: 'handoff', label: '승계', description: '같은 keeper를 새 trace와 새 세대로 이어붙이는 중입니다.' },
  offline: { key: 'offline', label: '오프라인', description: '활동 정보를 확인하지 못했습니다.' },
  failing: { key: 'failing', label: '오류', description: '세부 파이프라인 단계에서 오류를 감지했습니다.' },
  overflowed: { key: 'overflowed', label: '초과', description: '파이프라인이 용량을 초과했습니다.' },
  draining: { key: 'draining', label: '종료', description: '활동 종료를 위해 파이프라인을 비우는 중입니다.' },
  paused: { key: 'paused', label: '일시정지', description: '활동 단계도 함께 정지된 상태입니다.' },
  crashed: { key: 'crashed', label: '중단', description: '파이프라인 실행이 비정상 종료되었습니다.' },
  restarting: { key: 'restarting', label: '재시작', description: '파이프라인을 다시 올리는 중입니다.' },
  unknown: { key: 'unknown', label: '미상', description: '파이프라인 단계 정보가 없습니다.' },
}

const DEFAULT_PHASE_BY_BAND: Partial<Record<RuntimeBand, string>> = {
  active: 'Running',
  paused: 'Paused',
  offline: 'Offline',
  // No transient default: the band intentionally preserves the concrete
  // Compacting / HandingOff / Draining / Restarting phase as evidence.
}

const STAGE_PHASE_EQUIVALENTS: Record<string, string> = {
  compacting: 'Compacting',
  handoff: 'HandingOff',
  failing: 'Failing',
  overflowed: 'Overflowed',
  draining: 'Draining',
  paused: 'Paused',
  crashed: 'Crashed',
  restarting: 'Restarting',
}

const BAND_META: Record<RuntimeBand, RuntimeBandMeta> = {
  active: {
    key: 'active',
    label: '가동중',
    description: '운영자가 보기엔 현재 개입 없이 흐름을 지켜봐도 되는 상태입니다.',
  },
  attention: {
    key: 'attention',
    label: '주의 필요',
    description: '응답 지연, 오류, 복구, 승계 등으로 상태 확인이 필요합니다.',
  },
  paused: {
    key: 'paused',
    label: '일시정지',
    description: '실행은 멈춰 있지만 재개 대상으로 남아 있는 상태입니다.',
  },
  offline: {
    key: 'offline',
    label: '오프라인',
    description: '프로세스나 하트비트를 확인하지 못해 기동이 필요한 상태입니다.',
  },
  transient: {
    key: 'transient',
    label: '전이',
    description: '컨텍스트 압축, 승계, 종료, 재시작 등 단계 전이 중이라 결과 확인 전 입니다.',
  },
}

function phaseMeta(key: string | null | undefined): PhaseMeta {
  if (!key) return UNKNOWN_PHASE_META
  const meta = PHASE_LABELS[key]
  return meta ?? UNKNOWN_PHASE_META
}

function stageMeta(key: string | null | undefined): StageMeta {
  if (!key) return OFFLINE_STAGE_META
  const meta = STAGE_LABELS[key]
  return meta ?? OFFLINE_STAGE_META
}

function normalizeStage(stage: PipelineStage | string | null | undefined): string {
  return stage ? String(stage) : 'offline'
}

// Transient FSM phases — accepted here only after upstream normalization to
// the closed-sum SSOTs (KeeperPhase: `types/core.ts:1083`, PipelineStage:
// `types/core.ts:945`). Raw composite wire spellings such as `handing_off`
// are normalized before this helper sees them.
// These signal an *autonomous* transition (compacting/handoff/restarting)
// rather than steady-state, so they route to the dedicated `transient` band
// instead of `active` (which would silently re-merge them with healthy
// keepers mid-transition) or `attention` (which is reserved for failure/stall
// signals).
//
// `Draining` is intentionally NOT in this set. The prototype `data.jsx:37`
// treats `Draining` as `warn` (paired with `Paused` under the `pause` glyph),
// and `fleet-tone.ts:85` lifts that to the workspace tone SSOT. Including
// Draining here would force the runtime band to `transient` → `busy` rail,
// disagreeing with the workspace tone (`warn` dot/pill) on the same keeper.
// The correct non-offline display band for `Draining` is `paused`, reached
// by a phase-direct branch in `keeperBand()` after typed offline routing.
//
// `satisfies readonly KeeperPhase[]` ties each literal to the closed sum: any
// drift (typo or new transient variant) becomes a compile-time error instead
// of a silent runtime mismatch. `as const` keeps the literal types so the
// `ReadonlySet<string>` derivation stays branch-free.
const TRANSIENT_KEEPER_PHASES = [
  'Compacting',
  'HandingOff',
  'Restarting',
] as const satisfies readonly KeeperPhase[]

const TRANSIENT_PIPELINE_STAGES = [
  'compacting',
  'handoff',
  'restarting',
] as const satisfies readonly PipelineStage[]

const TRANSIENT_PHASE_KEYS: ReadonlySet<string> = new Set<string>([
  ...TRANSIENT_KEEPER_PHASES,
  ...TRANSIENT_PIPELINE_STAGES,
])

export function isTransientPhase(phase: string | null | undefined): boolean {
  if (phase == null) return false
  return TRANSIENT_PHASE_KEYS.has(phase)
}

export function keeperPhaseForDisplay(
  keeper: Keeper,
  composite: KeeperCompositeSnapshot | null = null,
): string | null {
  return deriveKeeperRuntimeProjection({ keeper, composite }).opState.phase
}

function keeperBand(projection: KeeperRuntimeProjection): RuntimeBand {
  // RFC-0135 §13 Goal-1 (audit B1, 2026-05-20): paused / offline / stuck
  // routing collapsed into the typed sum SSOT. The two prior local
  // checks
  //   - `isKeeperPaused(keeper)` (PR-3 canonical predicate)
  //   - `lifecycleKey === 'offline' | 'unbooted' | 'stopped'
  //      || OFFLINE_PHASES.has(phaseKey)` (string-set lifecycle/phase
  //      bypass)
  // were strict subsets of `projection.opState.kind === 'paused'` and
  // `projection.opState.kind === 'offline'`; routing through the runtime
  // projection keeps monitoring aligned with detail live-truth.
  //
  // RFC-0295 §5.2 (pixel-perfect Fleet tone rail): autonomous transient FSM
  // phases (Compacting / HandingOff / Restarting) get their own band so the
  // prototype's busy rail becomes live instead of collapsing into `active`.
  // Routed *before* attention so a mid-compaction blocker check doesn't
  // repaint the row as red — the operator's first scan question is "what is
  // currently moving", not "what is currently failing".
  //
  // RFC-0295 §5.3 (pixel-perfect Fleet tone rail, Draining reconciliation):
  // `Draining` routes to the `paused` band based on phase directly — NOT
  // through `opState.kind === 'paused'`, because the operational state
  // machine distinguishes "operator pause" (kind=paused, can be resumed) from
  // "operator stop via Draining" (kind=running, terminal intent). Folding
  // Draining into the paused variant would silently flip action-panel
  // semantics (canPause/canResume), roster state-note labels (agent-roster
  // line 179), and presence display (line 252) — none of which the
  // prototype calls for. The band is a *presentation* layer derived from
  // phase; the operational kind is an *action* layer derived from
  // pause/resume/operator-intent. The two are deliberately orthogonal here.
  //
  // The prototype `data.jsx:37,49` pairs `Draining` with `Paused` under the
  // `pause` glyph / `warn` rail — that pairing is a display choice, not an
  // action-equivalence claim. `fleet-tone.ts:85` already lifts
  // `PHASE_TONE.draining = 'warn'`; this branch makes the runtime band
  // agree with the workspace tone without letting Draining override typed
  // offline truth.
  if (projection.opState.kind === 'paused') return 'paused'
  if (projection.opState.kind === 'offline') return 'offline'
  if (projection.opState.phase === 'Draining') return 'paused'
  if (isTransientPhase(projection.opState.phase)) return 'transient'
  if (projection.signals.some(signal => signal.contributesToAttention)) {
    return 'attention'
  }
  return 'active'
}

function keeperHint(
  keeper: Keeper,
  projection: KeeperRuntimeProjection,
  band: RuntimeBand,
  stage: StageMeta,
): string | null {
  const signalHint = projection.signals.find(signal => signal.contributesToAttention && signal.hint !== null)?.hint
  if (signalHint) return signalHint
  if (band === 'paused') return '재개 대기 상태입니다. 원인은 차단/오류 근거를 확인하세요.'
  if (band === 'attention') return stage.description
  if (band === 'offline' && keeper.generation === 0 && (keeper.turn_count ?? 0) === 0) {
    return '아직 부팅된 적 없는 등록 런타임입니다.'
  }
  if (stage.key === 'idle' || stage.key === 'offline') return null
  return stage.description
}

export function summarizeKeeperMonitoring(
  keeper: Keeper,
  composite: KeeperCompositeSnapshot | null = null,
): KeeperMonitoringSummary {
  const projection = deriveKeeperRuntimeProjection({ keeper, composite })
  const phaseKey = projection.opState.phase ?? 'unknown'
  const stage = stageMeta(normalizeStage(keeper.pipeline_stage))
  const band = BAND_META[keeperBand(projection)]

  return {
    band,
    phase: phaseMeta(phaseKey),
    stage,
    hint: keeperHint(keeper, projection, band.key, stage),
  }
}

export function summarizeMonitoringEvidence(summary: KeeperMonitoringSummary): MonitoringEvidence {
  const defaultPhase = DEFAULT_PHASE_BY_BAND[summary.band.key]
  const phase =
    summary.phase.key === 'unknown' || summary.phase.key === 'Running' || summary.phase.key === defaultPhase
      ? null
      : summary.phase

  const stageMatchesPhase = STAGE_PHASE_EQUIVALENTS[summary.stage.key] === summary.phase.key
  const stage =
    summary.stage.key === 'idle'
    || summary.stage.key === 'offline'
    || (summary.band.key === 'paused' && summary.stage.key === 'paused')
    || stageMatchesPhase
      ? null
      : summary.stage

  return { phase, stage }
}

function agentBand(status: string | undefined | null): RuntimeBand {
  if (status == null || status.trim() === '') return 'attention'
  const parsed = parseAgentStatus(status)
  if (parsed === 'inactive' || parsed === 'offline') return 'offline'
  if (parsed != null) return 'active'
  // Wire-format tokens outside the declared AgentStatus union
  // (`parseAgentStatus` returned null). The OCaml backend
  // `agent_status` sum (lib/types/types_core.ml:42) emits only
  // Active|Busy|Listening|Inactive, plus `dashboard_mission_agents.ml:206-207`
  // adds `"offline" | "unknown"` via typed-union bypass.
  //
  // Wire-format audit 2026-05-20: `rg -n '"dead"|"left"' lib/` returned
  // zero hits in the `agent.status` slot — `"dead"` belongs to
  // `Fiber_dead`/`KH_dead`/`subsystem_health`, `"left"` belongs to
  // `Span_left` (different axis vocabularies). Defensive arms for
  // those tokens dropped.
  //
  // Unknown token surfaces as `'attention'` (not the prior `'active'`
  // default). `"unknown"` is an emitted backend default
  // (`dashboard_mission_agents.ml:207` `| None -> "unknown"`,
  // `dashboard_execution_builders.ml:209` `~default:"unknown"`), so the
  // previous `'active'` fallback silently absorbed operator-relevant
  // ambiguity into a "running" badge. `'attention'` ("주의 필요 — 응답
  // 지연, 오류, 복구, 승계 등으로 상태 확인이 필요합니다") preserves
  // that signal. Software-development.md §"Unknown → Permissive
  // Default" anti-pattern: unknown input must surface as a distinct
  // state, not collapse into the happy-path default.
  return 'attention'
}

function runtimeBandForAgent(
  agent: Agent,
  keeper?: Keeper | null,
  composite?: KeeperCompositeSnapshot | null,
): RuntimeBand {
  if (keeper) return summarizeKeeperMonitoring(keeper, composite ?? null).band.key
  return agentBand(agent.status)
}

export function runtimeBandMetaForAgent(
  agent: Agent,
  keeper?: Keeper | null,
  composite?: KeeperCompositeSnapshot | null,
): RuntimeBandMeta {
  return BAND_META[runtimeBandForAgent(agent, keeper, composite)]
}

export function runtimeBandMeta(band: RuntimeBand): RuntimeBandMeta {
  return BAND_META[band]
}
