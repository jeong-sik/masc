/**
 * Infra > Repos: the GitHub pull request snapshot
 * (GET /api/v1/repositories/pulls) and the words its states are shown with.
 */

import { count, isRecord, type Fact } from './repos-model'

export type PullChecks = 'passing' | 'failing' | 'running' | 'none'
export type PullReview = 'approved' | 'changes_requested' | 'waiting' | 'none'
export type PullMergeable = 'mergeable' | 'conflicting' | 'unknown'
export type PullHeadReview = 'reviewed_on_head' | 'not_reviewed_on_head' | 'review_history_incomplete' | 'unknown'

export interface RepoPull {
  readonly number: number
  readonly draft: boolean
  readonly checks: PullChecks
  readonly review: PullReview
  readonly mergeable: PullMergeable
  readonly headReview: PullHeadReview
  readonly author: string | null
  readonly keeper: string | null
  readonly title: string | null
}

export type PullFailure =
  | { readonly kind: 'repository_not_visible' }
  | { readonly kind: 'token_rejected' }
  | { readonly kind: 'rate_limited'; readonly resetAt: number | null }
  | { readonly kind: 'forbidden'; readonly status: number }
  | { readonly kind: 'http_status'; readonly status: number }
  | { readonly kind: 'graphql_errors'; readonly messages: readonly string[] }
  | { readonly kind: 'transport_failed'; readonly message: string }
  | { readonly kind: 'response_unreadable'; readonly message: string }

export type RepoPullsState =
  | { readonly kind: 'not_read' }
  | { readonly kind: 'not_github' }
  | { readonly kind: 'read'; readonly observedAt: number; readonly pulls: readonly RepoPull[]; readonly unreadable: number }
  | { readonly kind: 'failed'; readonly observedAt: number; readonly failure: PullFailure }

export type PullReader =
  | { readonly kind: 'not_declared' }
  | { readonly kind: 'declaration_invalid'; readonly reason: string }
  | { readonly kind: 'keeper_missing'; readonly keeper: string }
  | { readonly kind: 'token_unavailable'; readonly keeper: string; readonly reason: string }
  | { readonly kind: 'ready'; readonly keeper: string }

export interface RepoPullsEntry {
  readonly slug: string | null
  readonly pulls: RepoPullsState
}

/** Whether the server could match pull request authors to Keepers. When it
 *  could not, every author shows as a GitHub login. */
export type PullKeepers =
  | { readonly kind: 'not_listed' }
  | { readonly kind: 'listed' }
  | { readonly kind: 'list_failed'; readonly reason: string }

export interface PullsSnapshot {
  readonly reader: PullReader
  readonly keepers: PullKeepers
  readonly repositoriesError: string | null
  readonly byRepo: ReadonlyMap<string, RepoPullsEntry>
}

const CHECKS: readonly PullChecks[] = ['passing', 'failing', 'running', 'none']
const REVIEWS: readonly PullReview[] = ['approved', 'changes_requested', 'waiting', 'none']
const MERGEABLE: readonly PullMergeable[] = ['mergeable', 'conflicting', 'unknown']
const HEAD_REVIEWS: readonly PullHeadReview[] = ['reviewed_on_head', 'not_reviewed_on_head', 'review_history_incomplete', 'unknown']

function oneOf<T extends string>(words: readonly T[], raw: unknown): T | null {
  return typeof raw === 'string' && (words as readonly string[]).includes(raw) ? (raw as T) : null
}

function stringOrNull(raw: unknown): string | null {
  return typeof raw === 'string' && raw !== '' ? raw : null
}

/** `null` when a field is missing or carries a word this build does not know. */
function parsePull(raw: unknown): RepoPull | null {
  if (!isRecord(raw)) return null
  const number = count(raw.number)
  const checks = oneOf(CHECKS, raw.checks)
  const review = oneOf(REVIEWS, raw.review)
  const mergeable = oneOf(MERGEABLE, raw.mergeable)
  const headReview = oneOf(HEAD_REVIEWS, raw.head_review)
  if (number === null || typeof raw.draft !== 'boolean' || !checks || !review || !mergeable || !headReview) return null
  return {
    number,
    draft: raw.draft,
    checks,
    review,
    mergeable,
    headReview,
    author: stringOrNull(raw.author),
    keeper: stringOrNull(raw.keeper),
    title: stringOrNull(raw.title),
  }
}

function parseFailure(raw: unknown): PullFailure {
  if (!isRecord(raw)) throw new Error('pulls: failure is not an object')
  const status = (): number => {
    const value = count(raw.status)
    if (value === null) throw new Error('pulls: failure.status is not a number')
    return value
  }
  const message = (): string => {
    if (typeof raw.message !== 'string') throw new Error('pulls: failure.message is not a string')
    return raw.message
  }
  switch (raw.kind) {
    case 'repository_not_visible': return { kind: 'repository_not_visible' }
    case 'token_rejected': return { kind: 'token_rejected' }
    case 'rate_limited':
      return { kind: 'rate_limited', resetAt: typeof raw.reset_at === 'number' ? raw.reset_at : null }
    case 'forbidden': return { kind: 'forbidden', status: status() }
    case 'http_status': return { kind: 'http_status', status: status() }
    case 'graphql_errors':
      if (!Array.isArray(raw.messages) || !raw.messages.every((m): m is string => typeof m === 'string')) {
        throw new Error('pulls: failure.messages is not a list of strings')
      }
      return { kind: 'graphql_errors', messages: raw.messages }
    case 'transport_failed': return { kind: 'transport_failed', message: message() }
    case 'response_unreadable': return { kind: 'response_unreadable', message: message() }
    default: throw new Error('pulls: unknown failure kind')
  }
}

function parseRepoPulls(raw: unknown): RepoPullsState {
  if (!isRecord(raw)) throw new Error('pulls: repository entry has no pulls state')
  const observedAt = (): number => {
    if (typeof raw.observed_at !== 'number') throw new Error('pulls: observed_at is not a number')
    return raw.observed_at
  }
  switch (raw.state) {
    case 'not_read': return { kind: 'not_read' }
    case 'not_github': return { kind: 'not_github' }
    case 'read': {
      if (!Array.isArray(raw.pulls)) throw new Error('pulls: read state has no pulls list')
      const parsed = raw.pulls.map(parsePull)
      const pulls = parsed.filter((pull): pull is RepoPull => pull !== null)
      const serverUnreadable = count(raw.undecodable)
      if (serverUnreadable === null) throw new Error('pulls: undecodable is not a count')
      return {
        kind: 'read',
        observedAt: observedAt(),
        pulls,
        unreadable: serverUnreadable + (parsed.length - pulls.length),
      }
    }
    case 'failed': return { kind: 'failed', observedAt: observedAt(), failure: parseFailure(raw.failure) }
    default: throw new Error('pulls: unknown pulls state')
  }
}

function parseReader(raw: unknown): PullReader {
  if (!isRecord(raw)) throw new Error('pulls: reader is not an object')
  const text = (key: string): string => {
    const value = raw[key]
    if (typeof value !== 'string') throw new Error(`pulls: reader.${key} is not a string`)
    return value
  }
  switch (raw.state) {
    case 'not_declared': return { kind: 'not_declared' }
    case 'declaration_invalid': return { kind: 'declaration_invalid', reason: text('reason') }
    case 'keeper_missing': return { kind: 'keeper_missing', keeper: text('keeper') }
    case 'token_unavailable': return { kind: 'token_unavailable', keeper: text('keeper'), reason: text('reason') }
    case 'ready': return { kind: 'ready', keeper: text('keeper') }
    default: throw new Error('pulls: unknown reader state')
  }
}

function parseKeepers(raw: unknown): PullKeepers {
  if (!isRecord(raw)) throw new Error('pulls: keepers is not an object')
  switch (raw.state) {
    case 'not_listed': return { kind: 'not_listed' }
    case 'listed': return { kind: 'listed' }
    case 'list_failed':
      if (typeof raw.reason !== 'string') throw new Error('pulls: keepers.reason is not a string')
      return { kind: 'list_failed', reason: raw.reason }
    default: throw new Error('pulls: unknown keepers state')
  }
}

export function decodePullsSnapshot(raw: unknown): PullsSnapshot {
  if (!isRecord(raw) || !Array.isArray(raw.repositories)) throw new Error('pulls: missing repositories')
  const byRepo = new Map<string, RepoPullsEntry>()
  for (const entry of raw.repositories) {
    if (!isRecord(entry) || typeof entry.repository_id !== 'string') throw new Error('pulls: entry has no repository_id')
    byRepo.set(entry.repository_id, { slug: stringOrNull(entry.slug), pulls: parseRepoPulls(entry.pulls) })
  }
  return {
    reader: parseReader(raw.reader),
    keepers: parseKeepers(raw.keepers),
    repositoriesError: stringOrNull(raw.repositories_error),
    byRepo,
  }
}

export function pullReaderSentence(reader: PullReader): string | null {
  switch (reader.kind) {
    case 'ready': return null
    case 'not_declared': return 'PR을 읽을 Keeper가 정해져 있지 않습니다.'
    case 'declaration_invalid': return `PR을 읽을 Keeper 설정을 읽지 못했습니다: ${reader.reason}`
    case 'keeper_missing': return `PR을 읽기로 한 Keeper(${reader.keeper})가 없습니다.`
    case 'token_unavailable': return `Keeper(${reader.keeper})의 GitHub 토큰을 쓸 수 없습니다: ${reader.reason}`
  }
}

export function pullFailureSentence(failure: PullFailure): string {
  switch (failure.kind) {
    case 'repository_not_visible': return '이 토큰으로는 저장소가 보이지 않습니다.'
    case 'token_rejected': return 'GitHub가 토큰을 거절했습니다.'
    case 'rate_limited': return 'GitHub 요청 한도에 걸렸습니다.'
    case 'forbidden': return `GitHub가 요청을 막았습니다(HTTP ${failure.status}).`
    case 'http_status': return `GitHub가 HTTP ${failure.status} 응답을 보냈습니다.`
    case 'graphql_errors': return `GitHub가 오류로 답했습니다: ${failure.messages.join(' / ')}`
    case 'transport_failed': return `GitHub에 연결하지 못했습니다: ${failure.message}`
    case 'response_unreadable': return `GitHub 응답을 읽지 못했습니다: ${failure.message}`
  }
}

// Only a state someone has to act on (`warn`, `bad`) is drawn as a chip. `ok`
// is coloured text, and the expected or still-moving states are plain text.
export const CHECKS_LABEL: Record<PullChecks, Fact> = {
  passing: { text: '통과', tone: 'neutral' },
  failing: { text: '실패', tone: 'bad' },
  running: { text: '도는 중', tone: 'info' },
  none: { text: '없음', tone: 'neutral' },
}

export const REVIEW_LABEL: Record<PullReview, Fact> = {
  approved: { text: '승인', tone: 'ok' },
  changes_requested: { text: '변경 요청', tone: 'warn' },
  waiting: { text: '대기', tone: 'neutral' },
  none: { text: '요청 없음', tone: 'neutral' },
}

export const MERGEABLE_LABEL: Record<PullMergeable, Fact> = {
  mergeable: { text: '가능', tone: 'neutral' },
  conflicting: { text: '충돌', tone: 'bad' },
  unknown: { text: '미확인', tone: 'neutral' },
}

// Sort ranks put the rows an operator has to act on first when a status
// column is sorted ascending.
export const CHECKS_RANK: Record<PullChecks, number> = { failing: 0, running: 1, none: 2, passing: 3 }
export const REVIEW_RANK: Record<PullReview, number> = { changes_requested: 0, waiting: 1, none: 2, approved: 3 }
export const MERGEABLE_RANK: Record<PullMergeable, number> = { conflicting: 0, unknown: 1, mergeable: 2 }

export interface PullSummary {
  readonly total: number
  readonly conflicting: number
  readonly checksFailing: number
  readonly changesRequested: number
  readonly ready: number
}

/** Nothing left on GitHub's side: not a draft, checks passing, approved, and
 *  mergeable. */
function isReadyToMerge(pull: RepoPull): boolean {
  return !pull.draft && pull.checks === 'passing' && pull.review === 'approved' && pull.mergeable === 'mergeable'
}

export function summarizePulls(pulls: readonly RepoPull[]): PullSummary {
  let conflicting = 0
  let checksFailing = 0
  let changesRequested = 0
  let ready = 0
  for (const pull of pulls) {
    if (pull.mergeable === 'conflicting') conflicting += 1
    if (pull.checks === 'failing') checksFailing += 1
    if (pull.review === 'changes_requested') changesRequested += 1
    if (isReadyToMerge(pull)) ready += 1
  }
  return { total: pulls.length, conflicting, checksFailing, changesRequested, ready }
}

export type PullFilter = 'all' | 'conflicting' | 'checksFailing' | 'changesRequested' | 'ready'

/** The same predicates {@link summarizePulls} counts with. */
export function filterPulls(pulls: readonly RepoPull[], filter: PullFilter): readonly RepoPull[] {
  switch (filter) {
    case 'all': return pulls
    case 'conflicting': return pulls.filter((pull) => pull.mergeable === 'conflicting')
    case 'checksFailing': return pulls.filter((pull) => pull.checks === 'failing')
    case 'changesRequested': return pulls.filter((pull) => pull.review === 'changes_requested')
    case 'ready': return pulls.filter(isReadyToMerge)
  }
}

export function pullUrl(slug: string, number: number): string {
  return `https://github.com/${slug}/pull/${number}`
}
