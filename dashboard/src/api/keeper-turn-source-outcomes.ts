import { isRecord } from '../components/common/normalize'
import type { TurnIntakeSource } from './keeper-turn-flow'

const schema = 'masc.keeper.turn-source-outcomes/v1'
const receiptKinds = [
  'ack_turn_completed', 'ack_turn_attempt_terminal', 'ack_fusion_terminal',
  'ack_hitl_terminal', 'cancelled', 'transferred',
] as const
export type SourceReceiptKind = typeof receiptKinds[number]
export interface SourceReceipt {
  transitionId: string
  eventId: string
  appliedAt: number
  kind: SourceReceiptKind
}
export interface SourceOutcome {
  stimulusId: string
  snapshotRef: string
  admittedRevision: string
  receipts: SourceReceipt[]
}
export type TurnSourceOutcomes =
  | { state: 'unavailable'; reason: string }
  | { state: 'observed'; observedAt: number; sources: SourceOutcome[]; coverage: {
      state: 'not_needed' | 'read' | 'partial' | 'unavailable'
      rowsInspected: number
      invalidJsonRows: number
      invalidLedgerRows: number
      storageError: boolean
    } }

function text(value: unknown): string {
  if (typeof value !== 'string' || value.trim() === '') throw new Error('문자열 참조 누락')
  return value
}
function number(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error('유효한 관측 시각 누락')
  return value
}
function count(value: unknown): number {
  const parsed = number(value)
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error('유효한 행 수 누락')
  return parsed
}
function identity(source: Pick<TurnIntakeSource, 'stimulusId' | 'snapshotRef' | 'admittedRevision'>): string {
  return JSON.stringify([source.stimulusId, source.snapshotRef, source.admittedRevision])
}

/** Decode independently from intake: a damaged outcome never hides the input.
 * Every returned source must match the exact selection, including incarnation. */
export function decodeTurnSourceOutcomes(raw: unknown, selected: TurnIntakeSource[]): TurnSourceOutcomes {
  if (raw === undefined) return { state: 'unavailable', reason: '이 서버에는 자극 처리 관측이 기록되지 않았습니다' }
  try {
    if (!isRecord(raw) || raw.schema !== schema) throw new Error('처리 관측 형식 미확인')
    if (raw.state === 'unavailable') {
      const reasons: Record<string, string> = {
        exact_turn_required: '정확한 턴 선택이 필요합니다',
        ambiguous_turn_start: '시작 기록이 여러 개라 처리 결과를 한 시도에 연결할 수 없습니다',
        incomplete_manifest: '턴 시작 기록을 온전히 확인하지 못했습니다',
        missing_turn_start: '선택한 턴의 시작 기록이 없습니다',
        intake_not_recorded: '턴 시작에 자극 참조가 기록되지 않았습니다',
        invalid_intake_sources: '턴 시작의 자극 참조를 해석할 수 없습니다',
      }
      const reason = text(raw.reason)
      if (!Object.hasOwn(reasons, reason)) throw new Error('알 수 없는 처리 관측 상태')
      return { state: 'unavailable', reason: reasons[reason]! }
    }
    if (raw.state !== 'observed' || !Array.isArray(raw.sources) || !isRecord(raw.coverage)) {
      throw new Error('처리 관측이나 원장 조회 범위 누락')
    }
    const coverage = raw.coverage
    const coverageState = coverage.state
    if (coverageState !== 'not_needed' && coverageState !== 'read'
      && coverageState !== 'partial' && coverageState !== 'unavailable') throw new Error('원장 조회 상태 미확인')
    const rowsInspected = count(coverage.rows_inspected)
    const invalidJsonRows = count(coverage.invalid_json_rows)
    const invalidLedgerRows = count(coverage.invalid_ledger_rows)
    if (typeof coverage.storage_error !== 'boolean') throw new Error('저장소 조회 상태 누락')
    const storageError = coverage.storage_error
    const damaged = invalidJsonRows + invalidLedgerRows
    if (rowsInspected < damaged
      || (coverageState === 'read' && (storageError || damaged > 0))
      || (coverageState === 'partial' && !storageError && damaged === 0)
      || (coverageState === 'unavailable' && (!storageError || rowsInspected !== 0))
      || (coverageState === 'not_needed' && (selected.length !== 0 || rowsInspected !== 0 || storageError))) {
      throw new Error('원장 조회 범위와 진단이 일치하지 않습니다')
    }
    const expected = new Set(selected.map(identity))
    if (expected.size !== selected.length || raw.sources.length !== expected.size) throw new Error('선택한 자극 목록과 처리 관측이 다릅니다')
    const seen = new Set<string>()
    const sources = raw.sources.map((row): SourceOutcome => {
      if (!isRecord(row) || !Array.isArray(row.receipts)) throw new Error('자극 처리 참조 누락')
      const source = { stimulusId: text(row.stimulus_id), snapshotRef: text(row.source_snapshot_ref),
        admittedRevision: text(row.admitted_revision) }
      const key = identity(source)
      if (!expected.has(key) || seen.has(key)) throw new Error('다른 자극·원본·등록 차수의 처리 관측입니다')
      seen.add(key)
      const receipts = row.receipts.map((receipt): SourceReceipt => {
        if (!isRecord(receipt) || !receiptKinds.includes(receipt.kind as SourceReceiptKind)) throw new Error('처리 영수증 종류 미확인')
        return { transitionId: text(receipt.transition_id), eventId: text(receipt.event_id),
          appliedAt: number(receipt.applied_at), kind: receipt.kind as SourceReceiptKind }
      })
      if ((coverageState === 'unavailable' || coverageState === 'not_needed') && receipts.length > 0) {
        throw new Error('읽지 못한 원장에 처리 영수증이 있습니다')
      }
      return { ...source, receipts }
    })
    return { state: 'observed', observedAt: number(raw.observed_at), sources,
      coverage: { state: coverageState, rowsInspected, invalidJsonRows, invalidLedgerRows, storageError } }
  } catch (error) {
    return { state: 'unavailable', reason: `자극 처리 관측 확인 실패: ${error instanceof Error ? error.message : String(error)}` }
  }
}
