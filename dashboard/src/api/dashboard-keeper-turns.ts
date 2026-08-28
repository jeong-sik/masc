// GET /api/v1/keepers/turns — which keepers are mid-turn right now.
//
// The running-turn slot lives in the server's Keeper Owner (process
// memory), not in the keeper snapshots the roster renders from, so the
// "answering now" badge has to ask this projection — same reason the TUI
// polls it. One row per registered keeper; `turn` is null while idle.

import { get, type AbortableRequestOptions } from './core'

export interface KeeperTurnInFlight {
  lane: string
  started_at_unix: number
}

export interface KeeperTurnRow {
  keeper_name: string
  status: 'ok' | 'unavailable'
  turn: KeeperTurnInFlight | null
  detail?: string
}

export interface KeeperTurnsResponse {
  schema: string
  keepers: KeeperTurnRow[]
}

const KEEPER_TURNS_SCHEMA = 'masc.keeper_turns.v1'

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

/** Strict-enough normalization: an unknown schema or a mistyped row is an
 *  error, not a silently defaulted fleet — a badge drawn from a shape we do
 *  not recognize would claim knowledge the poll does not have. */
export function normalizeKeeperTurnsResponse(raw: unknown): KeeperTurnsResponse {
  const record = asRecord(raw)
  if (!record) throw new Error('keeper turns: response is not an object')
  if (record.schema !== KEEPER_TURNS_SCHEMA) {
    throw new Error(`keeper turns: unknown schema ${String(record.schema)}`)
  }
  const rowsRaw = Array.isArray(record.keepers) ? record.keepers : null
  if (!rowsRaw) throw new Error('keeper turns: keepers is not a list')
  const keepers = rowsRaw.map((rowRaw): KeeperTurnRow => {
    const row = asRecord(rowRaw)
    if (!row || typeof row.keeper_name !== 'string') {
      throw new Error('keeper turns: row has no keeper_name')
    }
    const status = row.status
    if (status !== 'ok' && status !== 'unavailable') {
      throw new Error(`keeper turns: unknown row status ${String(status)}`)
    }
    let turn: KeeperTurnInFlight | null = null
    if (row.turn !== null && row.turn !== undefined) {
      const turnRecord = asRecord(row.turn)
      if (
        !turnRecord
        || typeof turnRecord.lane !== 'string'
        || typeof turnRecord.started_at_unix !== 'number'
      ) {
        throw new Error('keeper turns: turn is neither null nor {lane, started_at_unix}')
      }
      turn = { lane: turnRecord.lane, started_at_unix: turnRecord.started_at_unix }
    }
    return {
      keeper_name: row.keeper_name,
      status,
      turn,
      ...(typeof row.detail === 'string' ? { detail: row.detail } : {}),
    }
  })
  return { schema: KEEPER_TURNS_SCHEMA, keepers }
}

export async function fetchKeeperTurns(
  opts?: AbortableRequestOptions,
): Promise<KeeperTurnsResponse> {
  const raw = await get<unknown>('/api/v1/keepers/turns', { signal: opts?.signal })
  return normalizeKeeperTurnsResponse(raw)
}
