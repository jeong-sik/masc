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
  scheduled: { lbl: '예약됨', cls: 'info', glyph: '◈' },
  due: { lbl: 'due', cls: 'warn', glyph: '◉' },
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
  return (status && SCHED_STATUS[status]) || { lbl: status || '알 수 없음', cls: 'dim', glyph: '◌' }
}

export function schedRiskSpec(risk: string | null | undefined): { lbl: string; cls: string } {
  return (risk && SCHED_RISK[risk]) || { lbl: risk || '미상', cls: 'dim' }
}

export function schedPayloadSpec(kind: string | null | undefined): { glyph: string; lbl: string } {
  return (kind && SCHED_PAYLOAD[kind]) || { glyph: '▢', lbl: kind || '작업' }
}
