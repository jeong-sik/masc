/**
 * Infra > Repos: the working tree of one clone
 * (GET /api/v1/git/status?repo_id=<id>) and the words it is shown with.
 *
 * Pure. A payload this build cannot read is a decode error, never a clean tree.
 */

import { count, formatCount, isRecord, splitDir, type Fact } from './repos-model'

export type GitHead =
  | { readonly kind: 'branch'; readonly name: string }
  | { readonly kind: 'detached' }

export type GitUpstream =
  | { readonly kind: 'none' }
  | { readonly kind: 'gone'; readonly name: string }
  | { readonly kind: 'tracking'; readonly name: string; readonly ahead: number; readonly behind: number }

export interface GitChange {
  readonly path: string
  readonly staged: boolean
  readonly unstaged: boolean
  readonly untracked: boolean
  readonly conflicted: boolean
}

export interface RepoGitState {
  readonly head: GitHead
  readonly upstream: GitUpstream
  readonly changes: readonly GitChange[]
}

function parseUpstream(raw: unknown): GitUpstream {
  if (raw === null) return { kind: 'none' }
  if (!isRecord(raw) || typeof raw.name !== 'string') throw new Error('git status: upstream is not an object with a name')
  if (raw.ahead === null && raw.behind === null) return { kind: 'gone', name: raw.name }
  const ahead = count(raw.ahead)
  const behind = count(raw.behind)
  if (ahead === null || behind === null) throw new Error('git status: upstream ahead/behind are not counts')
  return { kind: 'tracking', name: raw.name, ahead, behind }
}

function parseChange(raw: unknown): GitChange {
  if (!isRecord(raw) || typeof raw.path !== 'string') throw new Error('git status: a change has no path')
  const flag = (key: string): boolean => {
    const value = raw[key]
    if (typeof value !== 'boolean') throw new Error(`git status: change.${key} is not a boolean`)
    return value
  }
  return {
    path: raw.path,
    staged: flag('staged'),
    unstaged: flag('unstaged'),
    untracked: flag('untracked'),
    conflicted: flag('conflicted'),
  }
}

/** Throws on a payload this build cannot read, so the transport reports
 *  `schema_drift` instead of the tab showing a clean tree. */
export function decodeGitStatus(raw: unknown): RepoGitState {
  if (!isRecord(raw) || !isRecord(raw.branch) || !Array.isArray(raw.changes)) {
    throw new Error('git status: missing branch or changes')
  }
  const headRaw = raw.branch.head
  if (headRaw !== null && typeof headRaw !== 'string') throw new Error('git status: head is neither a name nor null')
  return {
    head: headRaw === null ? { kind: 'detached' } : { kind: 'branch', name: headRaw },
    upstream: parseUpstream(raw.branch.upstream),
    changes: raw.changes.map(parseChange),
  }
}

export interface GitChangeCounts {
  readonly total: number
  readonly staged: number
  readonly unstaged: number
  readonly untracked: number
  readonly conflicted: number
}

export function countChanges(changes: readonly GitChange[]): GitChangeCounts {
  let staged = 0
  let unstaged = 0
  let untracked = 0
  let conflicted = 0
  for (const change of changes) {
    if (change.staged) staged += 1
    if (change.unstaged) unstaged += 1
    if (change.untracked) untracked += 1
    if (change.conflicted) conflicted += 1
  }
  return { total: changes.length, staged, unstaged, untracked, conflicted }
}

export function headFact(head: GitHead): Fact {
  return head.kind === 'branch'
    ? { text: head.name, tone: 'neutral' }
    : { text: 'detached HEAD', tone: 'warn' }
}

/** The distance only; {@link upstreamRef} names what it is measured against. */
export function upstreamFact(upstream: GitUpstream): Fact {
  switch (upstream.kind) {
    case 'none': return { text: '추적 브랜치 없음', tone: 'neutral' }
    case 'gone': return { text: '원격 브랜치 삭제됨', tone: 'warn' }
    case 'tracking': {
      const { ahead, behind } = upstream
      if (ahead === 0 && behind === 0) return { text: '같음', tone: 'ok' }
      const parts: string[] = []
      if (behind > 0) parts.push(`${formatCount(behind)}커밋 뒤`)
      if (ahead > 0) parts.push(`${formatCount(ahead)}커밋 앞`)
      return { text: parts.join(' · '), tone: behind > 0 ? 'warn' : 'info' }
    }
  }
}

export function upstreamRef(upstream: GitUpstream): string | null {
  return upstream.kind === 'none' ? null : upstream.name
}

export function workingTreeFact(counts: GitChangeCounts): Fact {
  if (counts.total === 0) return { text: '깨끗함', tone: 'ok' }
  if (counts.conflicted > 0) {
    return { text: `충돌 ${formatCount(counts.conflicted)} · ${formatCount(counts.total)}파일`, tone: 'bad' }
  }
  // Uncommitted files are the ordinary state of a clone Keepers work in.
  return { text: `${formatCount(counts.total)}파일`, tone: 'neutral' }
}

/** "staged 1 · 수정 107 · 새 파일 18", or null for a clean tree. */
export function workingTreeBreakdown(counts: GitChangeCounts): string | null {
  const parts: string[] = []
  if (counts.staged > 0) parts.push(`staged ${formatCount(counts.staged)}`)
  if (counts.unstaged > 0) parts.push(`수정 ${formatCount(counts.unstaged)}`)
  if (counts.untracked > 0) parts.push(`새 파일 ${formatCount(counts.untracked)}`)
  return parts.length > 0 ? parts.join(' · ') : null
}

export type ChangeKind = '충돌' | '새 파일' | 'staged' | '수정'

/** One group per file: a conflict outranks everything, and a file with both
 *  staged and unstaged edits counts as staged. */
function changeKind(change: GitChange): ChangeKind {
  if (change.conflicted) return '충돌'
  if (change.untracked) return '새 파일'
  if (change.staged) return 'staged'
  return '수정'
}

const CHANGE_KIND_ORDER: readonly ChangeKind[] = ['충돌', 'staged', '수정', '새 파일']

export interface ChangeGroup {
  readonly kind: ChangeKind
  readonly paths: readonly string[]
}

export function groupChangesByKind(changes: readonly GitChange[]): readonly ChangeGroup[] {
  const byKind = new Map<ChangeKind, string[]>()
  for (const change of changes) {
    const kind = changeKind(change)
    const paths = byKind.get(kind)
    if (paths) paths.push(change.path)
    else byKind.set(kind, [change.path])
  }
  return CHANGE_KIND_ORDER.flatMap((kind) => {
    const paths = byKind.get(kind)
    return paths ? [{ kind, paths }] : []
  })
}

export interface DirGroup {
  /** Parent directory with its trailing slash; `./` for the repository root. */
  readonly dir: string
  readonly names: readonly string[]
}

/** Files under their parent directory, largest directory first, so a hundred
 *  files of one kind read as one line. */
export function groupByDirectory(paths: readonly string[]): readonly DirGroup[] {
  const byDir = new Map<string, string[]>()
  for (const path of paths) {
    const { dir, name } = splitDir(path)
    const names = byDir.get(dir ?? './')
    if (names) names.push(name)
    else byDir.set(dir ?? './', [name])
  }
  return [...byDir]
    .map(([dir, names]) => ({ dir, names }))
    .sort((a, b) => b.names.length - a.names.length || (a.dir < b.dir ? -1 : a.dir > b.dir ? 1 : 0))
}
