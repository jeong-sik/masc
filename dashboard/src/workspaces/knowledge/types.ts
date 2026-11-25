/**
 * Knowledge Workspace (`3 Knowledge`) — Shared Props, Wire Types, Decoders & Helpers.
 *
 * Covers:
 * - Board: Signal-only classifier, Succession Chain folding, Zero-count emoji reaction collapse (`#29` V2).
 * - Librarian Wiki: V2Envelope types + sanitized Markdown (`marked` + `dompurify`) + CAS 409 diff helper (`diff`).
 * - Lean Artifacts: Strict HTML (`sandbox=""`) & Markdown types — ZERO Office/HWP/PDF/Yjs bloat.
 * - World Memory & Librarian: Handles both MVCC DB & legacy ledger shapes (`#36`), enforces `scope=world`
 *   on `/api/v1/memory/diff`, Memory Flow `uPlot` series builder, and all 5 Librarian Recovery Acts.
 */

import type { ComponentChildren } from 'preact'
import { diffLines } from 'diff'
import type { TimeWindow } from '../../core/time-window'
import { err, ok, type Result } from '../../lib/result'

export interface WorkspaceInspectPayload {
  title: string
  subtitle?: string
  kind: string
  data?: unknown
  render?: () => ComponentChildren
}

export interface WorkspaceViewProps {
  subroute: string
  entityId?: string
  entityTab?: string
  onNavigate: (path: string) => void
  onInspect: (payload: WorkspaceInspectPayload) => void
}

export type KnowledgeSubroute = 'board' | 'wiki' | 'artifacts' | 'memory'

export function normalizeKnowledgeSubroute(raw: string): KnowledgeSubroute {
  const s = raw.trim().toLowerCase()
  if (s === 'wiki' || s === 'artifacts' || s === 'memory' || s === 'board') return s
  return 'board'
}

// ── Safe Guards & Formatters ──────────────────────────────────────────────

export function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

export function asNonEmptyString(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const t = v.trim()
  return t.length > 0 ? t : null
}

export function asString(v: unknown, fallback = ''): string {
  return typeof v === 'string' ? v : fallback
}

export function asFiniteNumber(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

export function asSafeInt(v: unknown): number | null {
  return typeof v === 'number' && Number.isSafeInteger(v) ? v : null
}

export function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return []
  return v.filter((x): x is string => typeof x === 'string' && x.trim().length > 0)
}

export function formatRelativeTime(tsInput: number | string | null | undefined, nowMs = Date.now()): string {
  if (tsInput === null || tsInput === undefined || tsInput === '') return '없음'
  let ms: number
  if (typeof tsInput === 'number') {
    if (!Number.isFinite(tsInput)) return '없음'
    ms = tsInput < 1_000_000_000_000 ? tsInput * 1000 : tsInput
  } else {
    const parsed = Date.parse(tsInput)
    if (Number.isNaN(parsed)) return tsInput
    ms = parsed
  }
  const diffSec = Math.round((nowMs - ms) / 1000)
  if (diffSec < 45) return '방금 전'
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}분 전`
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}시간 전`
  return `${Math.floor(diffSec / 86400)}일 전`
}

export function formatBytes(bytes: number | null | undefined): string {
  if (bytes === null || bytes === undefined || !Number.isFinite(bytes)) return '없음'
  if (bytes < 1024) return `${Math.trunc(bytes)} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
}

// ── 1. Board Types, Signal Classifier, Succession Folding & Emoji Collapse ─

export interface BoardReactionSummary {
  readonly emoji: string
  readonly count: number
  readonly reacted: boolean
}

export interface BoardPostCloseState {
  readonly closedBy: string
  readonly closedAt: string
  readonly successorId: string | null
  readonly summary: string | null
}

export type BoardAudience =
  | { readonly kind: 'targets'; readonly targets: readonly string[] }
  | { readonly kind: 'broadcast' }
  | { readonly kind: 'thread_participants' }
  | { readonly kind: 'discoverable' }

export interface BoardCommentPageInfo {
  readonly offset: number
  readonly returned: number
  readonly total: number
  readonly nextOffset: number | null
}

export interface BoardPostItem {
  readonly id: string
  readonly title: string
  readonly body: string
  readonly author: string
  readonly hearth: string | null
  readonly postKind: 'direct' | 'automation' | 'system' | null
  readonly visibility: string | null
  readonly audience?: BoardAudience | null
  readonly pinned: boolean
  readonly votes: number
  readonly currentVote: 'up' | 'down' | null
  readonly commentCount: number
  readonly createdAt: string
  readonly updatedAt: string
  readonly tags: readonly string[]
  readonly reactions: readonly BoardReactionSummary[]
  readonly supportedReactionEmojis: readonly string[]
  readonly closed: BoardPostCloseState | null
  readonly isSignal: boolean
}

export interface BoardCommentItem {
  readonly id: string
  readonly postId: string
  readonly parentId: string | null
  readonly author: string
  readonly content: string
  readonly createdAt: string
  readonly votes: number
  readonly currentVote: 'up' | 'down' | null
  readonly reactions: readonly BoardReactionSummary[]
  readonly audience?: BoardAudience | null
}

export interface BoardHearthItem {
  readonly name: string
  readonly count: number
}

export interface SubBoardItem {
  readonly id: string
  readonly slug: string
  readonly name: string
  readonly description: string
  readonly access: 'open' | 'members_only' | 'owner_only'
  readonly postCount: number
}

export const DEFAULT_REACTION_EMOJIS: readonly string[] = ['👍', '🔥', '👀', '🎉', '❤️', '🤔']

/**
 * Defense-in-depth signal classifier matching TUI `#6` (`wire_knowledge.mli:99-108`).
 */
export function isSignalBoardPost(input: {
  readonly postKind: 'direct' | 'automation' | 'system' | null
  readonly hearth: string | null
  readonly title: string
  readonly body: string
  readonly serverIsSignal?: boolean
}): boolean {
  if (typeof input.serverIsSignal === 'boolean') return input.serverIsSignal
  if (input.postKind === 'system') return false
  if (input.hearth?.toLowerCase() === 'verification') return false
  const t = input.title.trim()
  if (
    t.startsWith('Verify:')
    || t.startsWith('[verify]')
    || t.startsWith('Approved task')
    || t.startsWith('Rejected task')
  ) {
    return false
  }
  return true
}

/**
 * Partitions reactions into visible non-zero pills (`count > 0`) vs zero-count
 * emojis collapsed behind a single `[+☺]` trigger (`#29` V2!).
 */
export function partitionReactions(
  reactions: readonly BoardReactionSummary[],
  supportedEmojis: readonly string[],
): {
  readonly active: readonly BoardReactionSummary[]
  readonly collapsedZero: readonly string[]
} {
  const byEmoji = new Map<string, BoardReactionSummary>()
  for (const r of reactions) {
    byEmoji.set(r.emoji, r)
  }
  const active: BoardReactionSummary[] = []
  const collapsedZero: string[] = []
  const seen = new Set<string>()

  for (const r of reactions) {
    seen.add(r.emoji)
    if (r.count > 0) active.push(r)
    else collapsedZero.push(r.emoji)
  }
  const catalog = supportedEmojis.length > 0 ? supportedEmojis : DEFAULT_REACTION_EMOJIS
  for (const emoji of catalog) {
    if (seen.has(emoji)) continue
    seen.add(emoji)
    const found = byEmoji.get(emoji)
    if (!found || found.count <= 0) {
      collapsedZero.push(emoji)
    }
  }
  return { active, collapsedZero }
}

export interface FoldedBoardEntry {
  readonly head: BoardPostItem
  readonly predecessors: readonly BoardPostItem[]
}

/**
 * Folds Succession Chains: if post A is closed with `closed.successor_id === B.id`,
 * A is folded under the chain head B (walking transitively, guarding cycles).
 */
export function foldSuccessionChains(posts: readonly BoardPostItem[]): readonly FoldedBoardEntry[] {
  const byId = new Map<string, BoardPostItem>()
  for (const p of posts) byId.set(p.id, p)

  const resolveHeadId = (startId: string): string => {
    const visited = new Set<string>([startId])
    let cur = startId
    while (true) {
      const post = byId.get(cur)
      const next = post?.closed?.successorId
      if (!next || !byId.has(next) || visited.has(next)) return cur
      visited.add(next)
      cur = next
    }
  }

  const predecessorsByHead = new Map<string, BoardPostItem[]>()
  const foldedIds = new Set<string>()

  for (const p of posts) {
    const headId = resolveHeadId(p.id)
    if (headId !== p.id) {
      foldedIds.add(p.id)
      const list = predecessorsByHead.get(headId) ?? []
      list.push(p)
      predecessorsByHead.set(headId, list)
    }
  }

  const out: FoldedBoardEntry[] = []
  for (const p of posts) {
    if (foldedIds.has(p.id)) continue
    out.push({
      head: p,
      predecessors: predecessorsByHead.get(p.id) ?? [],
    })
  }
  return out
}

export function decodeBoardAudience(raw: unknown): BoardAudience | null {
  if (!isRecord(raw)) return null
  const kind = asNonEmptyString(raw.kind)?.toLowerCase()
  if (kind === 'targets') {
    const targets = asStringArray(raw.targets)
    return { kind: 'targets', targets }
  }
  if (kind === 'broadcast') return { kind: 'broadcast' }
  if (kind === 'thread_participants') return { kind: 'thread_participants' }
  if (kind === 'discoverable') return { kind: 'discoverable' }
  return null
}

export function decodeBoardPost(raw: unknown): BoardPostItem | null {
  if (!isRecord(raw)) return null
  const id = asNonEmptyString(raw.id)
  const author = asNonEmptyString(raw.author)
  if (!id || !author) return null
  const body = asString(raw.body, asString(raw.content, ''))
  const title = asNonEmptyString(raw.title) ?? (body.split('\n')[0]?.trim().slice(0, 80) || '제목 없음')
  const rawKind = asString(raw.post_kind, '').toLowerCase()
  const postKind =
    rawKind === 'human' || rawKind === 'direct' ? 'direct'
    : rawKind === 'automation' ? 'automation'
    : rawKind === 'system' ? 'system'
    : null
  const hearth = asNonEmptyString(raw.hearth)
  const votesUp = asFiniteNumber(raw.votes_up) ?? 0
  const votesDown = asFiniteNumber(raw.votes_down) ?? 0
  const votes = asFiniteNumber(raw.votes) ?? (votesUp - votesDown)
  const currentVote = raw.current_vote === 'up' || raw.current_vote === 'down' ? raw.current_vote : null

  const reactions: BoardReactionSummary[] = []
  if (Array.isArray(raw.reactions)) {
    for (const r of raw.reactions) {
      if (!isRecord(r)) continue
      const emoji = asNonEmptyString(r.emoji)
      if (!emoji) continue
      reactions.push({
        emoji,
        count: asFiniteNumber(r.count) ?? 0,
        reacted: r.reacted === true,
      })
    }
  }

  let closed: BoardPostCloseState | null = null
  if (isRecord(raw.closed) && asNonEmptyString(raw.closed.closed_by)) {
    closed = {
      closedBy: asString(raw.closed.closed_by, ''),
      closedAt: String(raw.closed.closed_at ?? ''),
      successorId: asNonEmptyString(raw.closed.successor_id),
      summary: asNonEmptyString(raw.closed.summary),
    }
  }

  const createdRaw = raw.created_at_iso ?? raw.created_at
  const updatedRaw = raw.updated_at_iso ?? raw.updated_at ?? createdRaw
  const toIso = (val: unknown): string => {
    if (typeof val === 'string') return val
    if (typeof val === 'number' && Number.isFinite(val)) {
      const ms = val < 1_000_000_000_000 ? val * 1000 : val
      return new Date(ms).toISOString()
    }
    return ''
  }

  return {
    id,
    title,
    body,
    author,
    hearth,
    postKind,
    visibility: asNonEmptyString(raw.visibility),
    audience: decodeBoardAudience(raw.audience),
    pinned: raw.pinned === true,
    votes,
    currentVote,
    commentCount: asFiniteNumber(raw.comment_count) ?? asFiniteNumber(raw.reply_count) ?? 0,
    createdAt: toIso(createdRaw),
    updatedAt: toIso(updatedRaw),
    tags: asStringArray(raw.tags),
    reactions,
    supportedReactionEmojis: asStringArray(raw.supported_reaction_emojis),
    closed,
    isSignal: isSignalBoardPost({
      postKind,
      hearth,
      title,
      body,
      serverIsSignal: typeof raw.is_signal === 'boolean' ? raw.is_signal : undefined,
    }),
  }
}

export function decodeBoardComment(raw: unknown): BoardCommentItem | null {
  if (!isRecord(raw)) return null
  const id = asNonEmptyString(raw.id)
  const author = asNonEmptyString(raw.author)
  if (!id || !author) return null
  const votesUp = asFiniteNumber(raw.votes_up) ?? 0
  const votesDown = asFiniteNumber(raw.votes_down) ?? 0
  const votes = asFiniteNumber(raw.votes) ?? asFiniteNumber(raw.score) ?? (votesUp - votesDown)
  const reactions: BoardReactionSummary[] = []
  if (Array.isArray(raw.reactions)) {
    for (const r of raw.reactions) {
      if (!isRecord(r)) continue
      const emoji = asNonEmptyString(r.emoji)
      if (!emoji) continue
      reactions.push({
        emoji,
        count: asFiniteNumber(r.count) ?? 0,
        reacted: r.reacted === true,
      })
    }
  }
  const createdRaw = raw.created_at
  const createdAt = typeof createdRaw === 'string'
    ? createdRaw
    : typeof createdRaw === 'number' && Number.isFinite(createdRaw)
      ? new Date(createdRaw < 1_000_000_000_000 ? createdRaw * 1000 : createdRaw).toISOString()
      : ''
  return {
    id,
    postId: asString(raw.post_id, ''),
    parentId: asNonEmptyString(raw.parent_id),
    author,
    content: asString(raw.content, asString(raw.body, '')),
    createdAt,
    votes,
    currentVote: raw.current_vote === 'up' || raw.current_vote === 'down' ? raw.current_vote : null,
    reactions,
    audience: decodeBoardAudience(raw.audience),
  }
}

// ── 2. Librarian Wiki Types (`#36`, V2Envelope) & CAS Conflict Diff ───────

export type WikiSource = 'direct_experience' | 'research' | 'experiment' | 'observation'

export const WIKI_SOURCES: readonly WikiSource[] = [
  'direct_experience',
  'research',
  'experiment',
  'observation',
] as const

export interface WikiLintFinding {
  readonly kind: string
  readonly subject: string
  readonly page?: string
  readonly line?: number
  readonly target?: string
  readonly form?: string
  readonly file?: string
  readonly reason?: string
}

export interface WikiDuplicateCandidate {
  readonly page_a: string
  readonly title_a: string
  readonly page_b: string
  readonly title_b: string
  readonly reason: string
}

export interface WikiPageSummary {
  readonly slug: string
  readonly file: string
  readonly title: string
  readonly summary: string
  readonly source: WikiSource
  readonly author: string
  readonly created: string
  readonly updated: string
  readonly revision: number
  readonly tags: readonly string[]
  readonly backlink_count: number
  readonly outgoing_link_count: number
  readonly sources_count: number
  readonly hearsay_count: number
  readonly sha256: string
}

export interface WikiIndexData {
  readonly pages_total: number
  readonly pages_readable: number
  readonly pages_unreadable: number
  readonly pages: readonly WikiPageSummary[]
  readonly unreadable_pages: readonly { readonly file: string; readonly reason: string }[]
  readonly tags: readonly { readonly tag: string; readonly count: number }[]
  readonly sources: Readonly<Record<string, number>>
  readonly lint: {
    readonly total_findings: number
    readonly counts: Readonly<Record<string, number>>
    readonly log_hole_suppressed: boolean
    readonly orphans: readonly string[]
    readonly duplicate_title_candidates: readonly WikiDuplicateCandidate[]
    readonly findings: readonly WikiLintFinding[]
  }
}

export interface WikiPageData {
  readonly page: string
  readonly slug: string
  readonly file: string
  readonly frontmatter: {
    readonly title: string
    readonly summary: string
    readonly source: WikiSource
    readonly author: string
    readonly created: string
    readonly updated: string
    readonly revision: number
    readonly tags: readonly string[]
  }
  readonly sha256: string
  readonly body_markdown: string
  readonly outgoing_links: readonly {
    readonly text: string
    readonly kind: string
    readonly target: string
    readonly raw: string
    readonly line: number
    readonly exists: boolean | null
  }[]
  readonly backlinks: readonly string[]
  readonly lint_findings: readonly WikiLintFinding[]
}

export interface WikiLintData {
  readonly pages_total: number
  readonly pages_unreadable: number
  readonly log_hole_suppressed: boolean
  readonly log_unknown_action: number
  readonly log_unreadable_line: number
  readonly counts: Readonly<Record<string, number>>
  readonly duplicate_title_candidates: readonly WikiDuplicateCandidate[]
  readonly findings: readonly WikiLintFinding[]
}

export interface WikiLogEntry {
  readonly idx: number
  readonly written_at_unix: number
  readonly action: string
  readonly revision: number
  readonly page: string
  readonly author: string | null
  readonly note: string | null
}

export interface WikiLogData {
  readonly total_lines: number
  readonly unknown_action: number
  readonly unreadable_line: number
  readonly limit: number
  readonly entries: readonly WikiLogEntry[]
}

export interface WikiSearchResultItem {
  readonly slug: string
  readonly title: string
  readonly summary: string
  readonly source: string
  readonly updated: string
  readonly revision: number
  readonly tags: readonly string[]
  readonly score: number
  readonly match_tier: 'whole_query' | 'every_term'
  readonly snippets: readonly { readonly line: number; readonly text: string }[]
}

export interface WikiSearchData {
  readonly query: string
  readonly count: number
  readonly limit: number
  readonly results: readonly WikiSearchResultItem[]
}

export interface WikiPutRespData {
  readonly action: 'created' | 'updated'
  readonly slug: string
  readonly revision: number
  readonly sha256: string
  readonly warnings: readonly string[]
}

export interface LineDiffChunk {
  readonly kind: 'equal' | 'added' | 'removed'
  readonly text: string
}

/**
 * Computes line-by-line diff between server's latest Wiki markdown and operator's
 * local draft for explicit `409 conflict_cas` reload-and-diff recovery.
 */
export function computeMarkdownLineDiff(serverText: string, localText: string): readonly LineDiffChunk[] {
  return diffLines(serverText, localText).map((part) => ({
    kind: part.added ? 'added' : part.removed ? 'removed' : 'equal',
    text: part.value,
  }))
}

// ── 3. Lean Artifacts Types (HTML & Markdown ONLY — Zero Office/HWP/PDF) ──

export interface PublishedArtifactItem {
  readonly id: string
  readonly revision: number
  readonly title: string
  readonly summary: string
  readonly format: 'markdown' | 'html'
  readonly author: string
  readonly createdAt: string
  readonly sha256: string
  readonly bytes: number | null
  readonly taskId: string | null
  readonly goalId: string | null
}

export interface ArtifactDocumentData {
  readonly artifact: PublishedArtifactItem
  readonly content: string
  readonly revisions: readonly {
    readonly revision: number
    readonly title: string
    readonly createdAt: string
    readonly sha256: string
  }[]
}

export function decodePublishedArtifactItem(raw: unknown): PublishedArtifactItem | null {
  if (!isRecord(raw)) return null
  const id = asNonEmptyString(raw.id)
  const title = asNonEmptyString(raw.title)
  if (!id || !title) return null
  const format = raw.format === 'html' ? 'html' : 'markdown'
  const bodyObj = isRecord(raw.body) ? raw.body : null
  const blobObj = bodyObj && isRecord(bodyObj._blob) ? bodyObj._blob : bodyObj
  const sha256 = (blobObj ? asNonEmptyString(blobObj.sha256) : null) ?? asString(raw.sha256, '')
  const bytes = blobObj ? asSafeInt(blobObj.bytes) : asSafeInt(raw.bytes)
  return {
    id,
    revision: asSafeInt(raw.revision) ?? 1,
    title,
    summary: asString(raw.summary, ''),
    format,
    author: asString(raw.author, 'unknown'),
    createdAt: asString(raw.created_at, ''),
    sha256,
    bytes,
    taskId: asNonEmptyString(raw.task_id),
    goalId: asNonEmptyString(raw.goal_id),
  }
}

// ── 4. World Memory & Librarian Recovery Types (`#36`) ────────────────────

export interface WorldClaimRow {
  readonly claimId: string
  readonly claim: string
  readonly stage: string
  readonly supportingKeepers: readonly string[]
  readonly supportCount: number
  readonly hasSourceBound: boolean
  readonly category: string | null
  readonly scope: string | null
  readonly facets: readonly string[]
  readonly revision: number | null
}

export interface CompetingClaimItem {
  readonly storeKind: string
  readonly keeperId: string
  readonly path: string | null
  readonly claimSha256: string
  readonly resolved: boolean
  readonly claim: string | null
  readonly category: string | null
  readonly origin: string | null
}

export interface MemoryConflictRow {
  readonly conflictId: string
  readonly description: string
  readonly memberCount: number
  readonly competingClaims: readonly CompetingClaimItem[]
}

export interface LibrarianWriterRow {
  readonly keeper: string
  readonly state: string
  readonly stopReason: string | null
  readonly availableActs: readonly string[]
  readonly snapshotSha: string | null
  readonly snapshotBytes: number | null
  readonly snapshotFault: string | null
}

export interface WorldMvccSummary {
  readonly digestRevision: number | null
  readonly digestSha256: string | null
  readonly edgesCount: number
  readonly indexCount: number
  readonly canonicalCount: number
  readonly wikiCount: number
  readonly artifactCount: number
  readonly resourceCount: number
}

export interface WorldMemoryViewModel {
  readonly sourceKind: 'world_memory_db' | 'legacy_ledger' | 'workspace_inventory_fallback'
  readonly ledgerState: 'available' | 'missing'
  readonly ledgerSha256: string | null
  readonly claimsCount: number
  readonly factsCount: number
  readonly classifiedCount: number | null
  readonly conflictsCount: number
  readonly excludedCount: number
  readonly worldMvcc: WorldMvccSummary | null
  readonly claims: readonly WorldClaimRow[]
  readonly activeConflicts: readonly MemoryConflictRow[]
  readonly briefing: {
    readonly status: string
    readonly text: string | null
    readonly sourceIdsCount: number
    readonly error: string | null
    readonly buildingTarget: number | null
    readonly buildingRemaining: number | null
  }
  readonly writersMode: 'none_in_process' | 'running'
  readonly writersErrorCount: number
  readonly writersWarnCount: number
  readonly writers: readonly LibrarianWriterRow[]
}

export function decodeWorldMemory(raw: unknown): Result<WorldMemoryViewModel, string> {
  if (!isRecord(raw)) return err('World Memory 응답이 JSON 객체가 아닙니다.')

  const ledgerState = raw.ledger_state === 'missing' ? 'missing' : raw.ledger_state === 'available' ? 'available' : null
  if (!ledgerState) return err(`알 수 없는 World Memory ledger_state: ${String(raw.ledger_state)}`)

  const sourceKind = raw.source === 'world_memory_db' ? 'world_memory_db' : 'legacy_ledger'
  const inv = isRecord(raw.inventory) ? raw.inventory : {}

  let worldMvcc: WorldMvccSummary | null = null
  if (isRecord(raw.world_mvcc)) {
    const m = raw.world_mvcc
    worldMvcc = {
      digestRevision: asSafeInt(m.digest_revision),
      digestSha256: asNonEmptyString(m.digest_sha256),
      edgesCount: asSafeInt(m.edges_count) ?? 0,
      indexCount: asSafeInt(m.index_count) ?? 0,
      canonicalCount: asSafeInt(m.canonical_count) ?? 0,
      wikiCount: asSafeInt(m.wiki_count) ?? 0,
      artifactCount: asSafeInt(m.artifact_count) ?? 0,
      resourceCount: asSafeInt(m.resource_count) ?? 0,
    }
  }

  const claims: WorldClaimRow[] = []
  if (Array.isArray(raw.claims)) {
    for (const c of raw.claims) {
      if (!isRecord(c)) continue
      const claimId = asNonEmptyString(c.claim_id)
      if (!claimId) continue
      claims.push({
        claimId,
        claim: asString(c.claim, ''),
        stage: asString(c.stage, 'unknown'),
        supportingKeepers: asStringArray(c.supporting_keepers),
        supportCount: asSafeInt(c.support_count) ?? 0,
        hasSourceBound: c.has_source_bound === true,
        category: asNonEmptyString(c.category),
        scope: asNonEmptyString(c.scope),
        facets: asStringArray(c.facets),
        revision: asSafeInt(c.revision),
      })
    }
  }

  const activeConflicts: MemoryConflictRow[] = []
  if (Array.isArray(raw.active_conflicts)) {
    for (const cf of raw.active_conflicts) {
      if (!isRecord(cf)) continue
      const conflictId = asNonEmptyString(cf.conflict_id)
      if (!conflictId) continue
      const competing: CompetingClaimItem[] = []
      if (Array.isArray(cf.competing_claims)) {
        for (const cc of cf.competing_claims) {
          if (!isRecord(cc)) continue
          competing.push({
            storeKind: asString(cc.store_kind, 'ordinary'),
            keeperId: asString(cc.keeper_id, 'unknown'),
            path: asNonEmptyString(cc.path),
            claimSha256: asString(cc.claim_sha256, ''),
            resolved: cc.resolved === true,
            claim: asNonEmptyString(cc.claim),
            category: asNonEmptyString(cc.category),
            origin: asNonEmptyString(cc.origin),
          })
        }
      }
      activeConflicts.push({
        conflictId,
        description: asString(cf.description, ''),
        memberCount: asSafeInt(cf.member_count) ?? competing.length,
        competingClaims: competing,
      })
    }
  }

  const br = isRecord(raw.briefing) ? raw.briefing : {}
  const bp = isRecord(br.building_pass) ? br.building_pass : null

  const lw = isRecord(raw.librarian_writers) ? raw.librarian_writers : {}
  const writersMode = lw.writers === 'running' ? 'running' : 'none_in_process'
  const writers: LibrarianWriterRow[] = []
  if (writersMode === 'running' && Array.isArray(lw.keepers)) {
    for (const k of lw.keepers) {
      if (!isRecord(k)) continue
      const keeper = asNonEmptyString(k.keeper)
      const row = isRecord(k.row) ? k.row : k
      if (!keeper) continue
      const sf = isRecord(row.snapshot_file) ? row.snapshot_file : null
      writers.push({
        keeper,
        state: asString(row.state, 'unknown'),
        stopReason: asNonEmptyString(row.stop) ?? asNonEmptyString(row.stop_reason) ?? asNonEmptyString(row.stopped),
        availableActs: asStringArray(row.available_acts),
        snapshotSha: sf ? asNonEmptyString(sf.sha) : null,
        snapshotBytes: sf ? asSafeInt(sf.bytes) : null,
        snapshotFault: sf ? asNonEmptyString(sf.fault) : null,
      })
    }
  }

  return ok({
    sourceKind,
    ledgerState,
    ledgerSha256: asNonEmptyString(inv.ledger_sha256),
    claimsCount: asSafeInt(inv.claims_count) ?? claims.length,
    factsCount: asSafeInt(inv.facts_count) ?? 0,
    classifiedCount: asSafeInt(inv.classified_count),
    conflictsCount: asSafeInt(inv.conflicts_count) ?? activeConflicts.length,
    excludedCount: asSafeInt(inv.excluded_count) ?? 0,
    worldMvcc,
    claims,
    activeConflicts,
    briefing: {
      status: asString(br.status, 'missing'),
      text: asNonEmptyString(br.text),
      sourceIdsCount: asSafeInt(br.source_ids_count) ?? 0,
      error: asNonEmptyString(br.error),
      buildingTarget: bp ? asSafeInt(bp.target) : null,
      buildingRemaining: bp ? asSafeInt(bp.remaining) : null,
    },
    writersMode,
    writersErrorCount: asSafeInt(lw.error) ?? 0,
    writersWarnCount: asSafeInt(lw.warn) ?? 0,
    writers,
  })
}

export function decodeWorkspaceInventoryFallback(raw: unknown): Result<WorldMemoryViewModel, string> {
  if (!isRecord(raw)) return err('workspace-memory-inventory 응답이 객체가 아닙니다.')
  const status = asString(raw.status, 'missing').toLowerCase()
  const ledgerState = status === 'available' ? 'available' : 'missing'
  const oa = isRecord(raw.ordinary_absence) ? raw.ordinary_absence : {}
  const br = isRecord(raw.briefing) ? raw.briefing : {}
  const bp = isRecord(br.building) ? br.building : null
  return ok({
    sourceKind: 'workspace_inventory_fallback',
    ledgerState,
    ledgerSha256: asNonEmptyString(raw.ledger_sha256),
    claimsCount: asSafeInt(raw.claim_count) ?? 0,
    factsCount: asSafeInt(oa.facts) ?? 0,
    classifiedCount: null,
    conflictsCount: asSafeInt(raw.conflict_count) ?? 0,
    excludedCount: asSafeInt(raw.excluded_count) ?? 0,
    worldMvcc: null,
    claims: [],
    activeConflicts: [],
    briefing: {
      status: asString(br.status, 'missing'),
      text: null,
      sourceIdsCount: asSafeInt(raw.claim_count) ?? 0,
      error: null,
      buildingTarget: bp ? asSafeInt(bp.target) : null,
      buildingRemaining: bp ? asSafeInt(bp.remaining) : null,
    },
    writersMode: 'none_in_process',
    writersErrorCount: 0,
    writersWarnCount: 0,
    writers: [],
  })
}

export interface WorldDiffViewModel {
  readonly window: string | null
  readonly counts: {
    readonly totalClaimsNow: number
    readonly added: number
    readonly updated: number
    readonly retracted: number
    readonly incompleteBatches: number
    readonly abortedBatches: number
  }
  readonly retrievalHeat: {
    readonly hot: number
    readonly warm: number
    readonly cold: number
    readonly neverRetrieved: number
    readonly totalEvents: number
  }
  readonly revisions: readonly {
    readonly rev: number
    readonly batchId: string
    readonly factId: string
    readonly recordedAt: string
    readonly op: string
  }[]
  readonly added: readonly unknown[]
  readonly updated: readonly unknown[]
  readonly retracted: readonly unknown[]
}

/**
 * ALWAYS includes `scope=world` per `#36` (`?window=24h` alone returns 400!).
 */
export function buildWorldMemoryDiffUrl(win: TimeWindow): string {
  const params = new URLSearchParams({ scope: 'world', window: win })
  return `/api/v1/memory/diff?${params.toString()}`
}

export function decodeWorldDiff(raw: unknown): Result<WorldDiffViewModel, string> {
  if (!isRecord(raw)) return err('World Diff 응답이 JSON 객체가 아닙니다.')
  const range = isRecord(raw.range) ? raw.range : {}
  const counts = isRecord(raw.counts) ? raw.counts : {}
  const heat = isRecord(raw.retrieval_heat) ? raw.retrieval_heat : {}
  const revisionsRaw = Array.isArray(raw.revisions) ? raw.revisions : []
  const revisions: WorldDiffViewModel['revisions'][number][] = []
  for (const r of revisionsRaw) {
    if (!isRecord(r)) continue
    revisions.push({
      rev: asSafeInt(r.rev) ?? 0,
      batchId: asString(r.batch_id, ''),
      factId: asString(r.fact_id, ''),
      recordedAt: asString(r.recorded_at, ''),
      op: asString(r.op, 'added'),
    })
  }
  return ok({
    window: asNonEmptyString(range.window),
    counts: {
      totalClaimsNow: asSafeInt(counts.total_claims_now) ?? 0,
      added: asSafeInt(counts.added) ?? 0,
      updated: asSafeInt(counts.updated) ?? 0,
      retracted: asSafeInt(counts.retracted) ?? 0,
      incompleteBatches: asSafeInt(counts.incomplete_batches) ?? 0,
      abortedBatches: asSafeInt(counts.aborted_batches) ?? 0,
    },
    retrievalHeat: {
      hot: asSafeInt(heat.hot) ?? 0,
      warm: asSafeInt(heat.warm) ?? 0,
      cold: asSafeInt(heat.cold) ?? 0,
      neverRetrieved: asSafeInt(heat.never_retrieved) ?? 0,
      totalEvents: asSafeInt(heat.total_events) ?? 0,
    },
    revisions,
    added: Array.isArray(raw.added) ? raw.added : [],
    updated: Array.isArray(raw.updated) ? raw.updated : [],
    retracted: Array.isArray(raw.retracted) ? raw.retracted : [],
  })
}

export interface MemoryFlowSeries {
  readonly timestamps: number[]
  readonly added: number[]
  readonly retracted: number[]
  readonly netTotal: number[]
}

/**
 * Aggregates world diff revision ticks into chronological buckets for `UPlotChart`
 * (`Added ▲`, `Retracted ▼` as negative values, and `Net Total` trajectory).
 */
export function buildMemoryFlowSeries(diff: WorldDiffViewModel): MemoryFlowSeries {
  if (diff.revisions.length === 0) {
    return { timestamps: [], added: [], retracted: [], netTotal: [] }
  }
  const parsed = diff.revisions
    .map((r) => ({
      ts: Math.floor((Date.parse(r.recordedAt) || 0) / 1000),
      op: r.op.toLowerCase(),
      rev: r.rev,
    }))
    .filter((p) => p.ts > 0)
    .sort((a, b) => a.ts - b.ts || a.rev - b.rev)

  if (parsed.length === 0) {
    return { timestamps: [], added: [], retracted: [], netTotal: [] }
  }

  // Group into 6-hour (>3d), 1-hour (>=2h), or 1-minute buckets
  const spanSec = parsed[parsed.length - 1]!.ts - parsed[0]!.ts
  const bucketSize = spanSec > 3 * 86_400 ? 21_600 : spanSec >= 7200 ? 3600 : 60

  const RETRACT_OPS = new Set(['retracted', 'retract', 'removed', 'remove', 'deleted', 'delete'])
  const ADD_OPS = new Set(['added', 'add', 'created', 'create', 'inserted', 'insert'])
  const buckets = new Map<number, { added: number; retracted: number }>()
  for (const p of parsed) {
    const key = Math.floor(p.ts / bucketSize) * bucketSize
    const cur = buckets.get(key) ?? { added: 0, retracted: 0 }
    if (RETRACT_OPS.has(p.op)) {
      cur.retracted += 1
    } else if (ADD_OPS.has(p.op)) {
      cur.added += 1
    }
    buckets.set(key, cur)
  }

  const keys = [...buckets.keys()].sort((a, b) => a - b)
  const timestamps: number[] = []
  const added: number[] = []
  const retracted: number[] = []
  const netDelta: number[] = []

  let totalNetDelta = 0
  for (const k of keys) {
    const b = buckets.get(k)!
    timestamps.push(k)
    added.push(b.added)
    retracted.push(b.retracted === 0 ? 0 : -b.retracted)
    totalNetDelta += b.added - b.retracted
    netDelta.push(totalNetDelta)
  }

  // Anchor final bucket to `counts.totalClaimsNow` so Net Total ends accurately at current total
  const startBase = Math.max(0, diff.counts.totalClaimsNow - totalNetDelta)
  const netTotal = netDelta.map((d) => Math.max(0, startBase + d))

  return { timestamps, added, retracted, netTotal }
}

export type MemoryRecoveryActPayload =
  | { readonly action: 'resume' }
  | { readonly action: 'adopt'; readonly observed: string }
  | { readonly action: 'restart_reading'; readonly observed: string }
  | {
      readonly action: 'skip_item'
      readonly target:
        | { readonly kind: 'head_item'; readonly turn_log: string; readonly line: number; readonly store: string; readonly at: number }
        | { readonly kind: 'unreadable_unit'; readonly turn_log: string; readonly line: number }
    }
  | { readonly action: 'skip_line'; readonly offset: number }

export function buildMemoryRecoveryPayload(input: {
  action: 'resume' | 'adopt' | 'restart_reading' | 'skip_item' | 'skip_line'
  observed?: string
  turnLog?: string
  line?: number
  store?: string
  at?: number
  offset?: number
}): Result<MemoryRecoveryActPayload, string> {
  switch (input.action) {
    case 'resume':
      return ok({ action: 'resume' })
    case 'adopt': {
      const obs = input.observed?.trim() ?? ''
      if (!obs) return err('adopt 실행에는 snapshot SHA-256(observed) 값이 필요합니다.')
      return ok({ action: 'adopt', observed: obs })
    }
    case 'restart_reading': {
      const obs = input.observed?.trim() ?? ''
      if (!obs) return err('restart_reading 실행에는 turn log ID(observed)가 필요합니다.')
      return ok({ action: 'restart_reading', observed: obs })
    }
    case 'skip_item': {
      const turnLog = input.turnLog?.trim() ?? ''
      const line = input.line
      if (!turnLog || line === undefined || !Number.isSafeInteger(line) || line < 0) {
        return err('skip_item 실행에는 turn_log와 0 이상의 line 오프셋이 필요합니다.')
      }
      const store = input.store?.trim() ?? ''
      if (store && input.at !== undefined && Number.isSafeInteger(input.at) && input.at >= 0) {
        return ok({
          action: 'skip_item',
          target: { kind: 'head_item', turn_log: turnLog, line, store, at: input.at },
        })
      }
      return ok({
        action: 'skip_item',
        target: { kind: 'unreadable_unit', turn_log: turnLog, line },
      })
    }
    case 'skip_line': {
      const offset = input.offset
      if (offset === undefined || !Number.isSafeInteger(offset) || offset < 0) {
        return err('skip_line 실행에는 0 이상의 바이트 offset이 필요합니다.')
      }
      return ok({ action: 'skip_line', offset })
    }
  }
}
