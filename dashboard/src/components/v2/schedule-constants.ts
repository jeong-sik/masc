// MASC v2 — schedule domain display constants (ported from prototype
// schedule-data.jsx; mirrors lib/schedule Schedule_domain). Status/risk/payload
// → label + tone class + glyph for the `.sch-pill` / `.sch-risk` / `.sch-kind`
// prototype markup. Pure data; the live schedule surface maps its API records
// onto these keys.

export interface SchedStatusSpec {
  readonly lbl: string
  readonly cls: string
  readonly glyph: string
}

export const SCHED_STATUS: Readonly<Record<string, SchedStatusSpec>> = {
  pending_approval: { lbl: '승인 대기', cls: 'warn', glyph: '◷' },
  scheduled: { lbl: '예약됨', cls: 'info', glyph: '●' },
  due: { lbl: 'due', cls: 'warn', glyph: '●' },
  running: { lbl: '실행 중', cls: 'ok', glyph: '▶' },
  succeeded: { lbl: '완료', cls: 'ok', glyph: '✓' },
  failed: { lbl: '실패', cls: 'bad', glyph: '✕' },
  rejected: { lbl: '거부됨', cls: 'bad', glyph: '⊘' },
  cancelled: { lbl: '취소됨', cls: 'dim', glyph: '◌' },
  expired: { lbl: '만료', cls: 'dim', glyph: '⊗' },
}

export const SCHED_TERMINAL: readonly string[] = ['succeeded', 'failed', 'rejected', 'cancelled', 'expired']

export const SCHED_RISK: Readonly<Record<string, { lbl: string; cls: string }>> = {
  reminder_only: { lbl: 'reminder', cls: 'dim' },
  read_only: { lbl: 'read-only', cls: 'ok' },
  workspace_write: { lbl: 'workspace-write', cls: 'info' },
  external_write: { lbl: 'external-write', cls: 'warn' },
  destructive: { lbl: 'destructive', cls: 'bad' },
  cost_bearing: { lbl: 'cost-bearing', cls: 'volt' },
}

export const SCHED_PAYLOAD: Readonly<Record<string, { glyph: string; lbl: string }>> = {
  'keeper.start': { glyph: '◇', lbl: 'keeper 기동' },
  'compact.sweep': { glyph: '◉', lbl: '컴팩션 스윕' },
  'index.reindex': { glyph: '▤', lbl: '재색인' },
  'report.generate': { glyph: '▦', lbl: '리포트 생성' },
  'trace.export': { glyph: '▥', lbl: 'trace 내보내기' },
  'gate.recheck': { glyph: '◬', lbl: '게이트 재점검' },
  'broadcast.send': { glyph: '◈', lbl: '브로드캐스트' },
  'archive.purge': { glyph: '⊗', lbl: '아카이브 정리' },
}

export function schedStatusSpec(status: string | null | undefined): SchedStatusSpec {
  if (!status) return { lbl: '알 수 없음', cls: 'dim', glyph: '◌' }
  const normalized = status.replace(/_/g, '').toLowerCase()
  const key = Object.keys(SCHED_STATUS).find(k => k.replace(/_/g, '').toLowerCase() === normalized)
  return (key && SCHED_STATUS[key]) || { lbl: status, cls: 'dim', glyph: '◌' }
}

export function schedRiskSpec(risk: string | null | undefined): { lbl: string; cls: string } {
  if (!risk) return { lbl: '미상', cls: 'dim' }
  const normalized = risk.replace(/_/g, '').toLowerCase()
  const key = Object.keys(SCHED_RISK).find(k => k.replace(/_/g, '').toLowerCase() === normalized)
  return (key && SCHED_RISK[key]) || { lbl: risk, cls: 'dim' }
}

export function schedPayloadSpec(kind: string | null | undefined): { glyph: string; lbl: string } {
  return (kind && SCHED_PAYLOAD[kind]) || { glyph: '▢', lbl: kind || '작업' }
}

// ── cadence (예약 종류) ──────────────────────────────────────────────
// The single axis operators reason about: is a schedule a one-off, a polling
// loop, or a fixed time-scheduled job? Derived from the backend recurrence kind
// (Schedule_domain.recurrence → one_shot | interval | daily | cron). The backend
// set is closed, so an unrecognized wire value means projection/version skew and
// is surfaced as `null` rather than silently bucketed into a permissive default.

export type RecurrenceKind = 'one_shot' | 'interval' | 'daily' | 'cron'

const RECURRENCE_KINDS: readonly RecurrenceKind[] = ['one_shot', 'interval', 'daily', 'cron']

/** Parse a wire recurrence kind into the closed backend set, or `null` if it is
 * not one of them (Unknown → explicit, never Unknown → permissive default). */
export function parseRecurrenceKind(raw: string | null | undefined): RecurrenceKind | null {
  const value = raw?.trim().toLowerCase() ?? ''
  return (RECURRENCE_KINDS as readonly string[]).includes(value) ? (value as RecurrenceKind) : null
}

export type Cadence = 'scheduled' | 'interval' | 'oneshot'

function assertNeverRecurrenceKind(value: never): never {
  throw new Error(`unhandled recurrence kind: ${String(value)}`)
}

/** Total, exhaustive map from the closed recurrence set to the operator cadence
 * axis. `daily` and `cron` are both fixed time-scheduled jobs → `scheduled`. A
 * new RecurrenceKind fails to compile here rather than falling through. */
export function cadenceOfRecurrenceKind(kind: RecurrenceKind): Cadence {
  switch (kind) {
    case 'one_shot':
      return 'oneshot'
    case 'interval':
      return 'interval'
    case 'daily':
    case 'cron':
      return 'scheduled'
    default:
      return assertNeverRecurrenceKind(kind)
  }
}

export interface SchedCadenceSpec {
  readonly key: Cadence
  readonly lbl: string
  readonly short: string
  readonly glyph: string
  readonly cls: string
  readonly hint: string
}

export const SCHED_CADENCE: Readonly<Record<Cadence, SchedCadenceSpec>> = {
  scheduled: {
    key: 'scheduled',
    lbl: '정기 · 시각',
    short: '정기',
    glyph: '',
    cls: 'ok',
    hint: '지정 시각에 반복되는 정기 잡 (daily · cron)',
  },
  interval: {
    key: 'interval',
    lbl: '폴링 · 주기',
    short: '폴링',
    glyph: '↻',
    cls: 'volt',
    hint: '고정 간격마다 반복 — 특정 시각이 아니라 계속 도는 상시 폴링 루프',
  },
  oneshot: {
    key: 'oneshot',
    lbl: '1회 · ad-hoc',
    short: '1회',
    glyph: '•',
    cls: 'info',
    hint: '한 번 실행하고 종료 — keeper가 상황에 맞춰 건 단발성 예약',
  },
}

/** Display order for the cadence filter strip (정기 → 폴링 → 1회). */
export const SCHED_CADENCE_ORDER: readonly Cadence[] = ['scheduled', 'interval', 'oneshot']

/** Terminal statuses normalized to the lowercase form the live API emits, so
 * non-terminal filters share one source with {@link SCHED_TERMINAL}. */
export const SCHED_TERMINAL_NORMALIZED: ReadonlySet<string> = new Set(
  SCHED_TERMINAL.map(status => status.toLowerCase()),
)
