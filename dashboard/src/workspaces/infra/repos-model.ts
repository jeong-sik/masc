/**
 * Infra > Repos: wire decoders and the sentences the tab shows.
 *
 * Everything here is pure. A wire value this build does not know becomes a
 * decode error or an `unreadable` count, never a default that looks healthy.
 */

import { expectRecordElements, expectRequiredStringField } from '../../lib/wire-decode'
import type { InfraRepository } from './types'

// ── Repository status (GET /api/v1/repositories) ────────────────────────

export type RepoStatus =
  | { readonly kind: 'active' }
  | { readonly kind: 'paused' }
  | { readonly kind: 'cloning' }
  /** `message` is null when the server recorded no reason. */
  | { readonly kind: 'error'; readonly message: string | null }
  | { readonly kind: 'unknown'; readonly raw: string }

export function parseRepoStatus(raw: unknown, errorMessage: unknown): RepoStatus {
  const word = typeof raw === 'string' ? raw : ''
  switch (word) {
    case 'active': return { kind: 'active' }
    case 'paused': return { kind: 'paused' }
    case 'cloning': return { kind: 'cloning' }
    case 'error':
      return { kind: 'error', message: typeof errorMessage === 'string' && errorMessage !== '' ? errorMessage : null }
    default: return { kind: 'unknown', raw: word }
  }
}

export type Tone = 'ok' | 'warn' | 'bad' | 'info' | 'neutral'

/** A short wording and how loudly it is drawn. */
export interface Fact {
  readonly text: string
  readonly tone: Tone
}

/** Sorted ascending, the repositories an operator has to act on come first. */
export const REPO_STATUS_RANK: Record<RepoStatus['kind'], number> = {
  error: 0,
  unknown: 1,
  cloning: 2,
  paused: 3,
  active: 4,
}

export function repoStatusLabel(status: RepoStatus): { readonly text: string; readonly tone: Tone } {
  switch (status.kind) {
    case 'active': return { text: '정상', tone: 'neutral' }
    case 'paused': return { text: '일시정지', tone: 'neutral' }
    case 'cloning': return { text: '가져오는 중', tone: 'info' }
    case 'error': return { text: '오류', tone: 'bad' }
    case 'unknown': return { text: status.raw === '' ? '상태 미보고' : status.raw, tone: 'warn' }
  }
}

/** What the sync loop needs to know about one repository. Field names follow
 *  the wire record, so a repository row is one. A null is a field the server
 *  did not send. */
export interface RepoSyncClock {
  readonly status: RepoStatus
  readonly auto_sync: boolean | null
  readonly sync_interval: number | null
  /** Unix seconds of the last status write: sync start while `cloning`,
   *  sync end otherwise. */
  readonly updated_at: number | null
}

export interface SyncStall {
  readonly ageSec: number
  readonly intervalSec: number
}

/**
 * A sync that is still "in progress" after the repository's own sync interval
 * has passed. The server's sync loop skips a repository in `cloning`, so one
 * left there by an interrupted sync is never retried on its own; only a
 * manual sync restarts it. The interval is the repository's declared cadence,
 * not a threshold chosen here.
 */
export function syncStall(clock: RepoSyncClock, nowSec: number): SyncStall | null {
  if (clock.status.kind !== 'cloning' || clock.auto_sync !== true) return null
  if (clock.sync_interval === null || clock.updated_at === null) return null
  const ageSec = nowSec - clock.updated_at
  return ageSec > clock.sync_interval ? { ageSec, intervalSec: clock.sync_interval } : null
}

/**
 * A clone the page keeps following: still `cloning` and younger than the
 * repository's own sync interval. Past the interval it is either reported as
 * stalled or left to a manual refresh, so the page does not poll a status that
 * no longer changes.
 */
export function cloneInProgress(clock: RepoSyncClock, nowSec: number): boolean {
  if (clock.status.kind !== 'cloning') return false
  if (clock.sync_interval === null || clock.updated_at === null) return false
  return nowSec - clock.updated_at <= clock.sync_interval
}

/** "5분", "2시간", "7일": a bare magnitude for "N째" / "N마다". */
export function formatSpan(seconds: number): string {
  const s = Math.max(0, Math.round(seconds))
  if (s < 60) return `${s}초`
  if (s < 3600) return `${Math.round(s / 60)}분`
  if (s < 86400) return `${Math.round(s / 3600)}시간`
  return `${Math.round(s / 86400)}일`
}

/** The time column of the repository table: what `updated_at` means depends on
 *  the status it was written with. Every row reads "N 전 <what>"; a sync that
 *  outlived its interval keeps the wording and turns to the warning colour. */
export function lastSyncFact(clock: RepoSyncClock, nowSec: number): Fact {
  if (clock.updated_at === null) return { text: '기록 없음', tone: 'neutral' }
  const span = formatSpan(nowSec - clock.updated_at)
  switch (clock.status.kind) {
    case 'active': return { text: `${span} 전`, tone: 'neutral' }
    case 'cloning':
      return { text: `${span} 전 시작`, tone: syncStall(clock, nowSec) === null ? 'neutral' : 'warn' }
    case 'error': return { text: `${span} 전 실패`, tone: 'bad' }
    case 'paused': return { text: `${span} 전 멈춤`, tone: 'neutral' }
    case 'unknown': return { text: `${span} 전 기록`, tone: 'neutral' }
  }
}

// ── Shared by the tab's decoders and wordings ───────────────────────────

export function isRecord(raw: unknown): raw is Record<string, unknown> {
  return raw !== null && typeof raw === 'object' && !Array.isArray(raw)
}

const REPO_LIST_READ = 'GET /api/v1/repositories'

function decodeRepoRow(raw: Record<string, unknown>, index: number): InfraRepository {
  const where = `${REPO_LIST_READ} repositories[${index}]`
  const id = expectRequiredStringField(raw, 'id', where).trim()
  const name = expectRequiredStringField(raw, 'name', where).trim()
  if (id === '' || name === '') {
    throw new Error(`${where}: "id"와 "name" 필드는 비어 있을 수 없습니다.`)
  }
  return {
    id,
    name,
    // `local_path` is the stored declaration and may be relative; only the
    // server knows the base it resolves against.
    local_path: typeof raw.resolved_local_path === 'string'
      ? raw.resolved_local_path
      : typeof raw.local_path === 'string' ? raw.local_path : null,
    status: parseRepoStatus(raw.status, raw.error_message),
    auto_sync: typeof raw.auto_sync === 'boolean' ? raw.auto_sync : null,
    sync_interval: typeof raw.sync_interval === 'number' && raw.sync_interval > 0 ? raw.sync_interval : null,
    updated_at: typeof raw.updated_at === 'number' && raw.updated_at > 0 ? raw.updated_at : null,
  }
}

/**
 * `GET /api/v1/repositories` answers `{ "repositories": [...] }` and nothing
 * else (server_routes_http_routes_repositories.ml). An answer of any other
 * shape is a read that failed: it must not pass for "no repository". A row
 * that is not an object, or has no id or name, fails the read too and the
 * error names the row: a list short without saying so reads as the whole of it.
 */
export function decodeRepoList(raw: unknown): readonly InfraRepository[] {
  if (!isRecord(raw) || !Array.isArray(raw.repositories)) {
    throw new Error(`${REPO_LIST_READ}: the answer has no \`repositories\` list`)
  }
  const rows = expectRecordElements<Record<string, unknown>>(raw.repositories, 'repositories', REPO_LIST_READ)
  return rows.map(decodeRepoRow)
}

export function count(raw: unknown): number | null {
  return typeof raw === 'number' && Number.isSafeInteger(raw) && raw >= 0 ? raw : null
}

const NUMBER_KO = new Intl.NumberFormat('ko-KR')

export function formatCount(value: number): string {
  return NUMBER_KO.format(value)
}

/** The parent directory with its trailing slash (null at the repository root)
 *  and the last path segment. git reports an untracked directory as `dir/`;
 *  that slash stays on the name. */
export function splitDir(path: string): { readonly dir: string | null; readonly name: string } {
  const cut = path.lastIndexOf('/', path.length - 2)
  return cut === -1 ? { dir: null, name: path } : { dir: path.slice(0, cut + 1), name: path.slice(cut + 1) }
}

// ── Keeper file writes (GET /api/v1/ide/repository-activity) ────────────

export interface FileWrites<W> {
  readonly path: string
  /** Newest first. */
  readonly writes: readonly W[]
  readonly lastAt: number
  /** Who wrote the file, most recent writer first. */
  readonly keepers: readonly string[]
  readonly failed: number
}

/** One line per file instead of one per write: a Keeper that rewrites a file
 *  thirty times in a turn is one row with a count. Files are ordered by their
 *  latest write, newest first. */
export function groupWritesByFile<W extends { readonly at: number; readonly keeper: string; readonly succeeded: boolean }>(
  writes: readonly W[],
  pathOf: (write: W) => string,
): readonly FileWrites<W>[] {
  const byPath = new Map<string, W[]>()
  for (const write of writes) {
    const path = pathOf(write)
    const group = byPath.get(path)
    if (group) group.push(write)
    else byPath.set(path, [write])
  }
  return [...byPath]
    .map(([path, group]) => {
      const ordered = [...group].sort((a, b) => b.at - a.at)
      return {
        path,
        writes: ordered,
        lastAt: ordered[0]!.at,
        keepers: [...new Set(ordered.map((write) => write.keeper))],
        failed: ordered.filter((write) => !write.succeeded).length,
      }
    })
    .sort((a, b) => b.lastAt - a.lastAt || (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
}

// ── Default selection ───────────────────────────────────────────────────

const NAME_ORDER = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })

/** The row a name-sorted table shows first: digits compare as numbers and
 *  case is ignored, like the table's own ordering. */
export function firstByName<R extends { readonly name: string }>(rows: readonly R[]): R | null {
  let first: R | null = null
  for (const row of rows) {
    if (first === null || NAME_ORDER.compare(row.name, first.name) < 0) first = row
  }
  return first
}
