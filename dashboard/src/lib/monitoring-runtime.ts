import type { Agent, Keeper, PipelineStage } from '../types'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import { keeperRuntimeBlockerHint } from './keeper-runtime-display'
import { ATTENTION_PHASES } from './keeper-predicates'
import { parseAgentStatus } from './agent-status'
import { deriveKeeperOperationalState, type KeeperOperationalState } from './keeper-operational-state'

export type RuntimeBand = 'active' | 'attention' | 'paused' | 'offline'

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

// 5-minute threshold for the monitoring band "attention" gate — distinct
// from config/constants.HEARTBEAT_STALE_MS (120s) which is the SSE
// connection liveness check. This longer window avoids false "attention"
// badges during brief heartbeat gaps that the SSE reconnect handles.
const MONITORING_BAND_STALE_MS = 5 * 60 * 1000
const DEFAULT_CONTEXT_ATTENTION_RATIO = 0.95

const UNKNOWN_PHASE_META: PhaseMeta = {
  key: 'unknown',
  label: '확인 필요',
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
  Paused: { key: 'Paused', label: '일시정지', description: '운영자가 keeper를 일시정지했습니다.' },
  Stopped: { key: 'Stopped', label: '정지', description: '정상 정지된 런타임입니다.' },
  Crashed: { key: 'Crashed', label: '비정상종료', description: 'fiber가 비정상적으로 종료되었습니다.' },
  Restarting: { key: 'Restarting', label: '재시작중', description: '복구를 시도하고 있습니다.' },
  Dead: { key: 'Dead', label: '종료', description: '재시도 budget이 소진된 종료 상태입니다.' },
  Zombie: { key: 'Zombie', label: '좀비', description: 'fiber는 종료되었으나 런타임이 아직 정리하지 않은 상태입니다.' },
  active: { key: 'active', label: '실행중', description: '프로세스는 살아 있지만 state projection이 부족합니다.' },
  busy: { key: 'busy', label: '작업중', description: '프로세스는 살아 있고 현재 작업을 수행 중입니다.' },
  listening: { key: 'listening', label: '대기중', description: '프로세스는 살아 있고 입력을 기다리고 있습니다.' },
  idle: { key: 'idle', label: '대기', description: '프로세스는 살아 있지만 현재 턴 작업은 없습니다.' },
  paused: { key: 'paused', label: '일시정지', description: '운영자가 keeper를 일시정지했습니다.' },
  stopped: { key: 'stopped', label: '정지', description: '이전에 실행되었지만 현재는 정지 상태입니다.' },
  unbooted: { key: 'unbooted', label: '미기동', description: '등록만 되어 있고 아직 부팅되지 않았습니다.' },
  offline: { key: 'offline', label: '오프라인', description: '런타임 연결을 확인하지 못했습니다.' },
  unknown: UNKNOWN_PHASE_META,
}

const STAGE_LABELS: Record<string, StageMeta> = {
  idle: { key: 'idle', label: '활동 없음', description: '지금 진행 중인 세부 활동 단계가 없습니다.' },
  thinking: { key: 'thinking', label: '사고', description: '응답이나 다음 액션을 결정하는 중입니다.' },
  tool_use: { key: 'tool_use', label: '도구', description: '도구를 호출하거나 결과를 소비하는 중입니다.' },
  compacting: { key: 'compacting', label: '압축', description: '컨텍스트 압축 단계를 수행 중입니다.' },
  handoff: { key: 'handoff', label: '승계', description: '같은 keeper를 새 trace와 새 세대로 이어붙이는 중입니다.' },
  scheduled_autonomous: { key: 'scheduled_autonomous', label: '자율', description: '예약된 자율 턴을 수행 중입니다.' },
  failing: { key: 'failing', label: '오류', description: '세부 파이프라인 단계에서 오류를 감지했습니다.' },
  draining: { key: 'draining', label: '종료', description: '활동 종료를 위해 파이프라인을 비우는 중입니다.' },
  paused: { key: 'paused', label: '일시정지', description: '활동 단계도 함께 정지된 상태입니다.' },
  crashed: { key: 'crashed', label: '중단', description: '파이프라인 실행이 비정상 종료되었습니다.' },
  restarting: { key: 'restarting', label: '재시작', description: '파이프라인을 다시 올리는 중입니다.' },
  offline: OFFLINE_STAGE_META,
}

const DEFAULT_PHASE_BY_BAND: Partial<Record<RuntimeBand, string>> = {
  active: 'Running',
  paused: 'Paused',
  offline: 'Offline',
}

const STAGE_PHASE_EQUIVALENTS: Record<string, string> = {
  compacting: 'Compacting',
  handoff: 'HandingOff',
  failing: 'Failing',
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
    description: '운영자가 의도적으로 멈춰 둔 상태입니다.',
  },
  offline: {
    key: 'offline',
    label: '오프라인',
    description: '프로세스가 내려갔거나 아직 부팅되지 않았습니다.',
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

export function keeperPhaseForDisplay(
  keeper: Keeper,
  composite: KeeperCompositeSnapshot | null = null,
): string | null {
  return deriveKeeperOperationalState({ keeper, composite }).phase
}

function isHeartbeatStale(keeper: Keeper): boolean {
  if (!keeper.last_heartbeat) return false
  const ts = Date.parse(keeper.last_heartbeat)
  if (Number.isNaN(ts)) return false
  return Date.now() - ts > MONITORING_BAND_STALE_MS
}

function contextAttentionRatio(keeper: Keeper): number {
  const value = keeper.runtime_warning_ctx_ratio
  return typeof value === 'number' && Number.isFinite(value)
    ? value
    : DEFAULT_CONTEXT_ATTENTION_RATIO
}

function keeperBand(
  keeper: Keeper,
  opState: KeeperOperationalState,
  phaseKey: string,
): RuntimeBand {
  // RFC-0135 §13 Goal-1 (audit B1, 2026-05-20): paused / offline / stuck
  // routing collapsed into the typed sum SSOT. The two prior local
  // checks
  //   - `isKeeperPaused(keeper)` (PR-3 canonical predicate)
  //   - `lifecycleKey === 'offline' | 'unbooted' | 'stopped'
  //      || OFFLINE_PHASES.has(phaseKey)` (string-set lifecycle/phase
  //      bypass)
  // were strict subsets of `opState.kind === 'paused'` and
  // `opState.kind === 'offline'`; routing via `deriveKeeperOperational
  // State` removes the parallel derivation entirely.
  if (opState.kind === 'paused') return 'paused'
  if (opState.kind === 'offline') return 'offline'
  // RFC-0135 PR-12: live blocker → typed state's `stuck` variant.
  // RFC-0135 §13 Goal-2: `opState.attention !== 'clean'` is the
  // typed-axis form of the previously-external `runtime_attention`
  // OR-合流 (composite.runtime_attention.{blocked, needs_attention}).
  // Both are SSOT-internal axes — `keeperBand` no longer derives them.
  const blockerOrBackendAttention =
    opState.kind === 'stuck' || opState.attention !== 'clean'
  // The remaining axes (KSM phase `ATTENTION_PHASES`, heartbeat
  // staleness, context-ratio breach, social model recognition) are
  // **external** to the typed SSOT today — RFC-0135 §13 lists them as
  // axis-extension candidates (`phase`, `heartbeatStale`,
  // `contextBreach`, `socialModelRecognized`). Until those land, this
  // OR remains, but each axis is now an explicit standalone gate so a
  // future PR can lift them one-by-one without touching the typed-sum
  // arms.
  const ksmPhaseAttention = ATTENTION_PHASES.has(phaseKey)
  const externalSignal =
    keeper.social_model_recognized === false
    || isHeartbeatStale(keeper)
    || (typeof keeper.context_ratio === 'number'
        && keeper.context_ratio >= contextAttentionRatio(keeper))
  if (blockerOrBackendAttention || ksmPhaseAttention || externalSignal) {
    return 'attention'
  }
  return 'active'
}

function keeperHint(keeper: Keeper, band: RuntimeBand, stage: StageMeta): string | null {
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  if (runtimeBlocker) return runtimeBlocker
  if (keeper.social_model_recognized === false) {
    return '미인식 대화 모델 설정이 감지됐습니다.'
  }
  if (band === 'paused') return '운영자가 멈춰 둔 상태입니다.'
  if (isHeartbeatStale(keeper)) return '오래 응답이 없어 실제 상태 확인이 필요합니다.'
  if (typeof keeper.context_ratio === 'number' && keeper.context_ratio >= contextAttentionRatio(keeper)) {
    return `컨텍스트 사용량이 ${Math.round(keeper.context_ratio * 100)}%입니다.`
  }
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
  const opState = deriveKeeperOperationalState({ keeper, composite })
  const phaseKey = opState.phase ?? 'unknown'
  const stage = stageMeta(normalizeStage(keeper.pipeline_stage))
  const band = BAND_META[keeperBand(keeper, opState, phaseKey)]

  return {
    band,
    phase: phaseMeta(phaseKey),
    stage,
    hint: keeperHint(keeper, band.key, stage),
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
