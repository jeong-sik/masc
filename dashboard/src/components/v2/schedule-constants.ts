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
  Pending_approval: { lbl: '승인 대기', cls: 'warn', glyph: '◷' },
  Scheduled: { lbl: '예약됨', cls: 'info', glyph: '◈' },
  Due: { lbl: 'due', cls: 'warn', glyph: '◉' },
  Running: { lbl: '실행 중', cls: 'ok', glyph: '▶' },
  Succeeded: { lbl: '완료', cls: 'ok', glyph: '✓' },
  Failed: { lbl: '실패', cls: 'bad', glyph: '✕' },
  Rejected: { lbl: '거부됨', cls: 'bad', glyph: '⊘' },
  Cancelled: { lbl: '취소됨', cls: 'dim', glyph: '◌' },
  Expired: { lbl: '만료', cls: 'dim', glyph: '⊗' },
}

export const SCHED_TERMINAL: readonly string[] = ['Succeeded', 'Failed', 'Rejected', 'Cancelled', 'Expired']

export const SCHED_RISK: Readonly<Record<string, { lbl: string; cls: string }>> = {
  Reminder_only: { lbl: 'reminder', cls: 'dim' },
  Read_only: { lbl: 'read-only', cls: 'ok' },
  Workspace_write: { lbl: 'workspace-write', cls: 'info' },
  External_write: { lbl: 'external-write', cls: 'warn' },
  Destructive: { lbl: 'destructive', cls: 'bad' },
  Cost_bearing: { lbl: 'cost-bearing', cls: 'volt' },
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
