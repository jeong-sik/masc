import { Schema } from 'effect'
import { post, postControlPlane } from './core'

const text = Schema.NonEmptyString
const count = Schema.Number.pipe(Schema.filter(value => Number.isSafeInteger(value) && value >= 0))
const finite = Schema.Number.pipe(Schema.filter(Number.isFinite))
const incarnation = text.pipe(Schema.filter(value => /^(0|[1-9][0-9]*)$/.test(value)
  && BigInt(value) <= 9223372036854775807n))
const sourceRef = text.pipe(Schema.filter(value => /^[0-9a-f]{64}$/.test(value)))
const rowSchema = Schema.Struct({
  keeper_name: text, source_ref: sourceRef, source_incarnation: incarnation,
  source: text, state: Schema.Literal('pending'), source_arrived_at: finite,
  first_admitted_at: Schema.NullOr(finite),
})
const counts = Schema.Record({ key: text, value: count })
const previewSchema = Schema.Struct({
  schema: Schema.Literal('keeper_event_queue.bulk.result.v2'), ok: Schema.Literal(true),
  action: Schema.Literal('preview'), workspace_root: text, would_cancel: count,
  keeper_counts: counts, source_counts: counts, oldest_age_seconds: Schema.NullOr(finite),
  rows: Schema.Array(rowSchema),
})
const receipt = Schema.Struct({ status: Schema.Literal('applied', 'already_applied'), transition_id: text })
const incompleteReceipt = Schema.Struct({
  status: Schema.Literal('committed_followup_failed'), transition_id: text,
  stage: Schema.Literal('checkpoint', 'wal_compaction', 'projection'), detail: Schema.String,
})
const rowResult = Schema.Union(
  Schema.Struct({ row: rowSchema, status: Schema.Literal('cancelled'), result: receipt }),
  Schema.Struct({ row: rowSchema, status: Schema.Literal('committed_followup_failed'), result: incompleteReceipt }),
  Schema.Struct({ row: rowSchema, status: Schema.Literal('failed'), error: text }),
)
const cancelSchema = Schema.Struct({
  schema: Schema.Literal('keeper_event_queue.bulk.result.v2'), ok: Schema.Literal(true),
  action: Schema.Literal('cancel'), workspace_root: text, operation_id: text, backup_path: text,
  requested: count, cancelled: count, committed_followup_failed: count, failed: count,
  results: Schema.Array(rowResult),
})
export type KeeperQueueRow = Schema.Schema.Type<typeof rowSchema>
export type KeeperQueuePreview = Schema.Schema.Type<typeof previewSchema>
export type KeeperQueueCancellation = Schema.Schema.Type<typeof cancelSchema>
export type KeeperQueueFilter = { keepers?: readonly string[]; sources?: readonly string[] }

export function queueRowKey(row: Pick<KeeperQueueRow, 'keeper_name' | 'source_ref' | 'source_incarnation'>): string {
  return JSON.stringify([row.keeper_name, row.source_ref, row.source_incarnation])
}

export function queueCounts(rows: readonly KeeperQueueRow[], key: 'keeper_name' | 'source'): Record<string, number> {
  const groups = new Map<string, number>()
  for (const row of rows) groups.set(row[key], (groups.get(row[key]) ?? 0) + 1)
  return Object.fromEntries(groups)
}
function sameCounts(actual: Readonly<Record<string, number>>, expected: Readonly<Record<string, number>>): boolean {
  return Object.keys(actual).length === Object.keys(expected).length
    && Object.entries(actual).every(([key, value]) => value === expected[key])
}
function matches(row: KeeperQueueRow, filter: KeeperQueueFilter): boolean {
  return (filter.keepers === undefined || filter.keepers.includes(row.keeper_name))
    && (filter.sources === undefined || filter.sources.includes(row.source))
}

export function parseKeeperQueuePreview(value: unknown, workspace: string, filter: KeeperQueueFilter): KeeperQueuePreview {
  const preview = Schema.decodeUnknownSync(previewSchema, { onExcessProperty: 'error' })(value)
  if (preview.workspace_root !== workspace || preview.would_cancel !== preview.rows.length
    || new Set(preview.rows.map(queueRowKey)).size !== preview.rows.length
    || !preview.rows.every(row => matches(row, filter))
    || !sameCounts(preview.keeper_counts, queueCounts(preview.rows, 'keeper_name'))
    || !sameCounts(preview.source_counts, queueCounts(preview.rows, 'source'))
    || (preview.oldest_age_seconds !== null && preview.oldest_age_seconds < 0)) {
    throw new Error('대기열 응답의 작업 공간·대상·집계가 일치하지 않습니다. 다시 조회하세요.')
  }
  return preview
}

export function parseKeeperQueueCancellation(value: unknown, workspace: string, selected: readonly KeeperQueueRow[]): KeeperQueueCancellation {
  const report = Schema.decodeUnknownSync(cancelSchema, { onExcessProperty: 'error' })(value)
  const targets = new Map(selected.map(row => [queueRowKey(row), row.source]))
  const returned = new Set(report.results.map(result => queueRowKey(result.row)))
  if (report.workspace_root !== workspace || targets.size !== selected.length
    || report.requested !== selected.length || report.results.length !== selected.length
    || returned.size !== selected.length
    || !report.results.every(result => targets.get(queueRowKey(result.row)) === result.row.source)
    || report.cancelled !== report.results.filter(result => result.status === 'cancelled').length
    || report.committed_followup_failed !== report.results.filter(result => result.status === 'committed_followup_failed').length
    || report.failed !== report.results.filter(result => result.status === 'failed').length) {
    throw new Error('취소 응답이 확인한 대상과 일치하지 않습니다. 대기열을 다시 조회해 확인하세요.')
  }
  return report
}

function path(workspace: string): string {
  return `/api/v1/keepers_bulk/event-queue?expected_workspace=${encodeURIComponent(workspace)}`
}

export async function previewKeeperQueue(workspace: string, filter: KeeperQueueFilter, signal?: AbortSignal): Promise<KeeperQueuePreview> {
  const value = await post<unknown>(path(workspace), {
    schema: 'keeper_event_queue.bulk.request.v2', action: 'preview', filter,
  }, undefined, undefined, signal, true)
  return parseKeeperQueuePreview(value, workspace, filter)
}

// No automatic replay or wall-clock deadline: an unavailable response does
// not prove that the durable cancellation failed. Read pending state again.
export async function cancelKeeperQueue(workspace: string, filter: KeeperQueueFilter,
  selected: readonly KeeperQueueRow[], reason: string, signal?: AbortSignal): Promise<KeeperQueueCancellation> {
  if (selected.length === 0 || reason.trim() === '') throw new Error('대상과 취소 사유를 확인하세요.')
  for (const row of selected) Schema.decodeUnknownSync(rowSchema, { onExcessProperty: 'error' })(row)
  if (new Set(selected.map(queueRowKey)).size !== selected.length || !selected.every(row => matches(row, filter))) {
    throw new Error('선택한 대기 항목이 중복되거나 필터와 일치하지 않습니다.')
  }
  const value = await postControlPlane<unknown>(path(workspace), {
    schema: 'keeper_event_queue.bulk.request.v2', action: 'cancel', filter, reason: reason.trim(),
    selections: selected.map(({ keeper_name, source_ref, source_incarnation }) => ({ keeper_name, source_ref, source_incarnation })),
  }, undefined, { signal })
  return parseKeeperQueueCancellation(value, workspace, selected)
}
