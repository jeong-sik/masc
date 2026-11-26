import { describe, expect, it } from 'vitest'
import {
  countChanges,
  decodeGitStatus,
  groupByDirectory,
  groupChangesByKind,
  upstreamFact,
  workingTreeBreakdown,
  workingTreeFact,
} from './repos-git-model'
import {
  cloneInProgress,
  decodeRepoList,
  firstByName,
  formatSpan,
  groupWritesByFile,
  lastSyncFact,
  parseRepoStatus,
  repoStatusLabel,
  syncStall,
  type RepoSyncClock,
} from './repos-model'

const change = (path: string, flags: Partial<Record<'staged' | 'unstaged' | 'untracked' | 'conflicted', boolean>> = {}) => ({
  path,
  staged: false,
  unstaged: false,
  untracked: false,
  conflicted: false,
  ...flags,
})

describe('workspaces/infra repos-model', () => {
  it('reads the repository list only from the shape the server sends', () => {
    const row = { id: 'masc', name: 'masc', local_path: 'repos/masc', resolved_local_path: '/srv/repos/masc', status: 'active', auto_sync: true, sync_interval: 300, updated_at: 100 }
    expect(decodeRepoList({ repositories: [row] })).toEqual([
      { id: 'masc', name: 'masc', local_path: '/srv/repos/masc', status: { kind: 'active' }, auto_sync: true, sync_interval: 300, updated_at: 100 },
    ])
    // No repository is an answer too.
    expect(decodeRepoList({ repositories: [] })).toEqual([])
  })

  it('refuses a list answer of another shape instead of reading it as no repository', () => {
    for (const answer of [{}, { repositories: null }, { error: 'store unreadable' }, 'ok', null, [], { ok: true, data: [] }]) {
      expect(() => decodeRepoList(answer)).toThrow('no `repositories` list')
    }
  })

  it('refuses a list with a row it cannot read, and names the row', () => {
    const good = { id: 'masc', name: 'masc', status: 'active' }
    for (const bad of [{ name: 'no-id', status: 'active' }, { id: 'no-name', status: 'active' }, { id: '', name: '' }, 'not a row', null]) {
      expect(() => decodeRepoList({ repositories: [good, bad] })).toThrow('repositories[1]')
    }
  })

  describe('decodeGitStatus', () => {
    it('reads a branch that tracks its remote', () => {
      const state = decodeGitStatus({
        scope: { kind: 'repository', repository_id: 'masc' },
        branch: { head: 'main', upstream: { name: 'origin/main', ahead: 0, behind: 2246 } },
        changes: [change('lib/a.ml', { unstaged: true }), change('notes.txt', { untracked: true })],
        total: 2,
      })
      expect(state.head).toEqual({ kind: 'branch', name: 'main' })
      expect(state.upstream).toEqual({ kind: 'tracking', name: 'origin/main', ahead: 0, behind: 2246 })
      expect(countChanges(state.changes)).toEqual({ total: 2, staged: 0, unstaged: 1, untracked: 1, conflicted: 0 })
    })

    it('keeps detached HEAD, no upstream, and a deleted upstream apart', () => {
      expect(decodeGitStatus({ branch: { head: null, upstream: null }, changes: [] }).head).toEqual({ kind: 'detached' })
      expect(decodeGitStatus({ branch: { head: 'topic', upstream: null }, changes: [] }).upstream).toEqual({ kind: 'none' })
      expect(decodeGitStatus({
        branch: { head: 'topic', upstream: { name: 'origin/topic', ahead: null, behind: null } },
        changes: [],
      }).upstream).toEqual({ kind: 'gone', name: 'origin/topic' })
    })

    it('refuses a payload it cannot read instead of reporting a clean tree', () => {
      expect(() => decodeGitStatus({ branch: { head: 'main', upstream: null } })).toThrow()
      expect(() => decodeGitStatus({ branch: { head: 'main', upstream: { name: 'origin/main', ahead: 1, behind: null } }, changes: [] })).toThrow()
      expect(() => decodeGitStatus({ branch: { head: 'main', upstream: null }, changes: [{ path: 'a', staged: true }] })).toThrow()
    })
  })

  describe('facts', () => {
    it('words the distance from the remote without hiding either direction', () => {
      expect(upstreamFact({ kind: 'tracking', name: 'origin/main', ahead: 0, behind: 0 })).toEqual({ text: '같음', tone: 'ok' })
      expect(upstreamFact({ kind: 'tracking', name: 'origin/main', ahead: 0, behind: 2246 })).toEqual({ text: '2,246커밋 뒤', tone: 'warn' })
      expect(upstreamFact({ kind: 'tracking', name: 'origin/main', ahead: 3, behind: 0 })).toEqual({ text: '3커밋 앞', tone: 'info' })
      expect(upstreamFact({ kind: 'tracking', name: 'origin/main', ahead: 3, behind: 2 }).text).toBe('2커밋 뒤 · 3커밋 앞')
      expect(upstreamFact({ kind: 'gone', name: 'origin/topic' }).tone).toBe('warn')
    })

    it('groups uncommitted files by kind, conflicts first, each file once', () => {
      const changes = [
        change('new.txt', { untracked: true }),
        change('both.ml', { staged: true, unstaged: true }),
        change('edit.ml', { unstaged: true }),
        change('clash.ml', { conflicted: true, unstaged: true }),
      ]
      expect(groupChangesByKind(changes)).toEqual([
        { kind: '충돌', paths: ['clash.ml'] },
        { kind: 'staged', paths: ['both.ml'] },
        { kind: '수정', paths: ['edit.ml'] },
        { kind: '새 파일', paths: ['new.txt'] },
      ])
      expect(workingTreeBreakdown(countChanges(changes))).toBe('staged 1 · 수정 3 · 새 파일 1')
      expect(workingTreeBreakdown(countChanges([]))).toBeNull()
    })

    it('rolls files up under their directory, largest first', () => {
      expect(groupByDirectory(['test/stanzas/a.inc', 'README.md', 'test/stanzas/b.inc', 'lib/keeper/k.ml', 'docs/new/'])).toEqual([
        { dir: 'test/stanzas/', names: ['a.inc', 'b.inc'] },
        { dir: './', names: ['README.md'] },
        { dir: 'docs/', names: ['new/'] },
        { dir: 'lib/keeper/', names: ['k.ml'] },
      ])
    })

    it('colours a conflict, not an ordinary uncommitted file', () => {
      expect(workingTreeFact(countChanges([]))).toEqual({ text: '깨끗함', tone: 'ok' })
      expect(workingTreeFact(countChanges([change('a', { unstaged: true })]))).toEqual({ text: '1파일', tone: 'neutral' })
      expect(workingTreeFact(countChanges([change('a', { conflicted: true }), change('b', { staged: true })])).tone).toBe('bad')
    })

    it('shows an unknown repository status as itself, not as healthy', () => {
      expect(repoStatusLabel(parseRepoStatus('active', undefined))).toEqual({ text: '정상', tone: 'neutral' })
      expect(repoStatusLabel(parseRepoStatus('cloning', undefined)).text).toBe('가져오는 중')
      expect(parseRepoStatus('error', 'fetch failed')).toEqual({ kind: 'error', message: 'fetch failed' })
      expect(parseRepoStatus('error', undefined)).toEqual({ kind: 'error', message: null })
      expect(repoStatusLabel(parseRepoStatus('archived', undefined))).toEqual({ text: 'archived', tone: 'warn' })
      expect(repoStatusLabel(parseRepoStatus(undefined, undefined)).text).toBe('상태 미보고')
    })
  })

  describe('sync clock', () => {
    const NOW = 1_795_600_000
    const clock = (over: Partial<RepoSyncClock> = {}): RepoSyncClock => ({
      status: { kind: 'cloning' },
      auto_sync: true,
      sync_interval: 300,
      updated_at: NOW - 7 * 86400,
      ...over,
    })

    it('calls a sync stalled only past the repository\'s own interval', () => {
      expect(syncStall(clock(), NOW)).toEqual({ ageSec: 7 * 86400, intervalSec: 300 })
      expect(syncStall(clock({ updated_at: NOW - 120 }), NOW)).toBeNull()
      expect(syncStall(clock({ status: { kind: 'active' } }), NOW)).toBeNull()
    })

    it('does not guess a cadence the server did not send', () => {
      expect(syncStall(clock({ auto_sync: false }), NOW)).toBeNull()
      expect(syncStall(clock({ auto_sync: null }), NOW)).toBeNull()
      expect(syncStall(clock({ sync_interval: null }), NOW)).toBeNull()
      expect(syncStall(clock({ updated_at: null }), NOW)).toBeNull()
    })

    it('words the time by what the status says it was', () => {
      expect(lastSyncFact(clock(), NOW)).toEqual({ text: '7일 전 시작', tone: 'warn' })
      expect(lastSyncFact(clock({ updated_at: NOW - 120 }), NOW)).toEqual({ text: '2분 전 시작', tone: 'neutral' })
      expect(lastSyncFact(clock({ status: { kind: 'active' }, updated_at: NOW - 180 }), NOW)).toEqual({ text: '3분 전', tone: 'neutral' })
      expect(lastSyncFact(clock({ status: { kind: 'error', message: 'x' }, updated_at: NOW - 7200 }), NOW)).toEqual({ text: '2시간 전 실패', tone: 'bad' })
      expect(lastSyncFact(clock({ updated_at: null }), NOW).text).toBe('기록 없음')
    })

    it('follows a clone only inside the repository\'s own interval', () => {
      expect(cloneInProgress(clock({ updated_at: NOW - 120 }), NOW)).toBe(true)
      expect(cloneInProgress(clock({ updated_at: NOW - 120, auto_sync: false }), NOW)).toBe(true)
      expect(cloneInProgress(clock(), NOW)).toBe(false)
      expect(cloneInProgress(clock({ updated_at: NOW - 120, sync_interval: null }), NOW)).toBe(false)
      expect(cloneInProgress(clock({ status: { kind: 'active' }, updated_at: NOW - 120 }), NOW)).toBe(false)
    })

    it('formats a span as one bare unit', () => {
      expect([formatSpan(0), formatSpan(59), formatSpan(300), formatSpan(7200), formatSpan(7 * 86400)])
        .toEqual(['0초', '59초', '5분', '2시간', '7일'])
    })
  })

  describe('Keeper file writes', () => {
    const write = (path: string, at: number, keeper: string, succeeded = true) => ({ path, at, keeper, succeeded })

    it('folds repeated writes into one line per file, newest file first', () => {
      const files = groupWritesByFile([
        write('lib/a.ml', 100, 'ocaml-dev'),
        write('docs/b.md', 300, 'leader'),
        write('lib/a.ml', 250, 'reviewer', false),
        write('lib/a.ml', 200, 'ocaml-dev'),
      ], (entry) => entry.path)

      expect(files.map((file) => [file.path, file.writes.length, file.lastAt])).toEqual([
        ['docs/b.md', 1, 300],
        ['lib/a.ml', 3, 250],
      ])
      const a = files[1]!
      expect(a.writes.map((entry) => entry.at)).toEqual([250, 200, 100])
      expect(a.keepers).toEqual(['reviewer', 'ocaml-dev'])
      expect(a.failed).toBe(1)
    })

    it('has no line when nothing was written', () => {
      expect(groupWritesByFile([], () => 'x')).toEqual([])
    })
  })

  describe('default selection', () => {
    it('picks the row a name-sorted table shows first', () => {
      const names = (list: string[]) => firstByName(list.map((name) => ({ name })))?.name ?? null
      expect(names(['beta', 'Alpha', 'gamma'])).toBe('Alpha')
      expect(names(['repo10', 'repo2'])).toBe('repo2')
      expect(names([])).toBeNull()
    })
  })
})
