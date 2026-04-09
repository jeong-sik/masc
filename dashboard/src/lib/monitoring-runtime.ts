import type { Agent, Keeper, KeeperPhase, PipelineStage } from '../types'
import { keeperDisplayStatus } from './keeper-runtime-display'

export type RuntimeBand = 'active' | 'attention' | 'paused' | 'offline'

export interface RuntimeBandMeta {
  key: RuntimeBand
  label: string
  description: string
}

export interface PhaseMeta {
  key: string
  label: string
  description: string
}

export interface StageMeta {
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

const HEARTBEAT_STALE_MS = 5 * 60 * 1000
const CONTEXT_ATTENTION_RATIO = 0.85

const CANONICAL_PHASE_KEYS = new Set([
  'Offline',
  'Running',
  'Failing',
  'Compacting',
  'HandingOff',
  'Draining',
  'Paused',
  'Stopped',
  'Crashed',
  'Restarting',
  'Dead',
])

const OFFLINE_PHASES = new Set<string>(['Offline', 'Stopped', 'Dead'])
const ATTENTION_PHASES = new Set<string>(['Failing', 'Compacting', 'HandingOff', 'Draining', 'Crashed', 'Restarting'])

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
  Failing: { key: 'Failing', label: '오류중', description: '최근 턴 또는 heartbeat/reconcile 과정에서 실패를 감지했습니다.' },
  Compacting: { key: 'Compacting', label: '압축중', description: '컨텍스트 정리를 위해 compaction을 수행 중입니다.' },
  HandingOff: { key: 'HandingOff', label: '승계중', description: '새 세대로 handoff를 진행하고 있습니다.' },
  Draining: { key: 'Draining', label: '종료중', description: '현재 턴을 비우고 정지 상태로 이동하는 중입니다.' },
  Paused: { key: 'Paused', label: '일시정지', description: '운영자가 keeper를 일시정지했습니다.' },
  Stopped: { key: 'Stopped', label: '정지', description: '정상 정지된 런타임입니다.' },
  Crashed: { key: 'Crashed', label: '비정상종료', description: 'fiber가 비정상적으로 종료되었습니다.' },
  Restarting: { key: 'Restarting', label: '재시작중', description: 'supervisor가 복구를 시도하고 있습니다.' },
  Dead: { key: 'Dead', label: '종료', description: '재시도 budget이 소진된 종료 상태입니다.' },
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
  idle: { key: 'idle', label: '대기', description: '현재 턴에서 진행 중인 세부 단계가 없습니다.' },
  thinking: { key: 'thinking', label: '사고', description: '응답이나 다음 액션을 결정하는 중입니다.' },
  tool_use: { key: 'tool_use', label: '도구', description: '도구를 호출하거나 결과를 소비하는 중입니다.' },
  compacting: { key: 'compacting', label: '압축', description: '컨텍스트 압축 단계를 수행 중입니다.' },
  handoff: { key: 'handoff', label: '승계', description: '다음 세대로 이어붙이는 중입니다.' },
  scheduled_autonomous: { key: 'scheduled_autonomous', label: '자율', description: '예약된 자율 턴을 수행 중입니다.' },
  failing: { key: 'failing', label: '오류', description: '세부 파이프라인 단계에서 오류를 감지했습니다.' },
  draining: { key: 'draining', label: '종료', description: '활동 종료를 위해 파이프라인을 비우는 중입니다.' },
  paused: { key: 'paused', label: '일시정지', description: '활동 단계도 함께 정지된 상태입니다.' },
  crashed: { key: 'crashed', label: '중단', description: '파이프라인 실행이 비정상 종료되었습니다.' },
  restarting: { key: 'restarting', label: '재시작', description: '파이프라인을 다시 올리는 중입니다.' },
  offline: OFFLINE_STAGE_META,
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
    description: '실패, 복구, 승계, 드레이닝, blocker, stale heartbeat 등으로 확인이 필요한 상태입니다.',
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

function normalizePhase(phase: KeeperPhase | string | null | undefined): string | null {
  if (!phase) return null
  if (CANONICAL_PHASE_KEYS.has(phase)) return phase
  const normalized = String(phase).trim().toLowerCase()
  if (!normalized) return null
  const lookup: Record<string, string> = {
    offline: 'Offline',
    running: 'Running',
    failing: 'Failing',
    compacting: 'Compacting',
    handing_off: 'HandingOff',
    handingoff: 'HandingOff',
    draining: 'Draining',
    paused: 'Paused',
    stopped: 'Stopped',
    crashed: 'Crashed',
    restarting: 'Restarting',
    dead: 'Dead',
  }
  return lookup[normalized] ?? null
}

function normalizeStage(stage: PipelineStage | string | null | undefined): string {
  return stage ? String(stage) : 'offline'
}

export function keeperPhaseForDisplay(keeper: Keeper): string | null {
  const lifecycleKey = keeperDisplayStatus(keeper)
  const lifecyclePhase = normalizePhase(lifecycleKey)
  if (
    lifecyclePhase === 'Paused'
    || lifecyclePhase === 'Stopped'
    || lifecyclePhase === 'Offline'
    || lifecyclePhase === 'Dead'
  ) {
    return lifecyclePhase
  }
  return normalizePhase(keeper.phase) ?? lifecyclePhase
}

function isHeartbeatStale(keeper: Keeper): boolean {
  if (!keeper.last_heartbeat) return false
  const ts = Date.parse(keeper.last_heartbeat)
  if (Number.isNaN(ts)) return false
  return Date.now() - ts > HEARTBEAT_STALE_MS
}

function keeperBand(keeper: Keeper, phaseKey: string, lifecycleKey: string): RuntimeBand {
  if (keeper.paused || phaseKey === 'Paused' || lifecycleKey === 'paused') return 'paused'
  if (
    lifecycleKey === 'offline'
    || lifecycleKey === 'inactive'
    || lifecycleKey === 'unbooted'
    || lifecycleKey === 'stopped'
    || OFFLINE_PHASES.has(phaseKey)
  ) {
    return 'offline'
  }
  if (
    ATTENTION_PHASES.has(phaseKey)
    || Boolean(keeper.last_blocker?.trim())
    || isHeartbeatStale(keeper)
    || (typeof keeper.context_ratio === 'number' && keeper.context_ratio >= CONTEXT_ATTENTION_RATIO)
  ) {
    return 'attention'
  }
  return 'active'
}

function keeperHint(keeper: Keeper, band: RuntimeBand, stage: StageMeta): string | null {
  const blocker = keeper.last_blocker?.trim()
  if (blocker) return blocker
  if (band === 'paused') return '운영자가 멈춰 둔 상태입니다.'
  if (isHeartbeatStale(keeper)) return '하트비트가 오래되어 실제 프로세스 확인이 필요합니다.'
  if (typeof keeper.context_ratio === 'number' && keeper.context_ratio >= CONTEXT_ATTENTION_RATIO) {
    return `컨텍스트 사용량 ${Math.round(keeper.context_ratio * 100)}%`
  }
  if (band === 'attention') return stage.description
  if (band === 'offline' && keeper.generation === 0 && (keeper.turn_count ?? 0) === 0) {
    return '아직 부팅된 적 없는 등록 런타임입니다.'
  }
  return stage.key === 'idle' ? '현재 활동 단계는 비어 있습니다.' : stage.description
}

export function summarizeKeeperMonitoring(keeper: Keeper): KeeperMonitoringSummary {
  const lifecycleKey = keeperDisplayStatus(keeper)
  const phaseKey = keeperPhaseForDisplay(keeper) ?? 'unknown'
  const stage = stageMeta(normalizeStage(keeper.pipeline_stage))
  const band = BAND_META[keeperBand(keeper, phaseKey, lifecycleKey)]

  return {
    band,
    phase: phaseMeta(phaseKey),
    stage,
    hint: keeperHint(keeper, band.key, stage),
  }
}

function agentBand(status: string | undefined | null): RuntimeBand {
  const normalized = (status ?? '').trim().toLowerCase()
  if (!normalized) return 'attention'
  if (normalized === 'inactive' || normalized === 'offline' || normalized === 'dead' || normalized === 'left') {
    return 'offline'
  }
  return 'active'
}

export function runtimeBandForAgent(agent: Agent, keeper?: Keeper | null): RuntimeBand {
  if (keeper) return summarizeKeeperMonitoring(keeper).band.key
  return agentBand(agent.status)
}

export function runtimeBandMetaForAgent(agent: Agent, keeper?: Keeper | null): RuntimeBandMeta {
  return BAND_META[runtimeBandForAgent(agent, keeper)]
}

export function runtimeBandMeta(band: RuntimeBand): RuntimeBandMeta {
  return BAND_META[band]
}
