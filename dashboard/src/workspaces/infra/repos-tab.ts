/**
 * Infra L1 Tab 2: Repos
 *
 * The registered repositories as a table, and below it the one that is
 * selected: its clone, its open pull requests, and what Keepers wrote in it.
 * The reads are in `repos-reads.ts`; the selected repository is `RepoDetail`.
 *
 * - POST /api/v1/repositories        register
 * - POST /api/v1/repositories/<id>/sync
 */

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { decodeRepositoryAdvance } from '../../api/repositories'
import { repositoryAdvanceSummary } from '../../components/repo-sidebar'
import { apiMutate, authSession, currentSessionEpoch, isEpochCurrent, resourceCache } from '../../core'
import { pushShellToast } from '../../shell/shell-state'
import { RepoDetail, type UnfinishedSync } from './repos-detail'
import { RepoAddForm, RepoTable } from './repos-list'
import { cloneInProgress, firstByName, type Fact } from './repos-model'
import type { PullsSnapshot } from './repos-pulls-model'
import {
  PULLS_KEY,
  REPOS_KEY,
  activityKey,
  canAdminRepos,
  canReadRepos,
  gitKey,
  loadActivity,
  loadGit,
  loadPulls,
  loadRepos,
  useRefetchWhenStale,
} from './repos-reads'
import { Ago, FailLine, WaitLine } from './repos-sections'
import type { InfraRepository, WorkspaceViewProps } from './types'
import './infra.css'
import './repos-lists.css'

const MS_PER_SECOND = 1000
/** How often the list is read again while a clone is in progress. The server
 *  sends no event when one ends, and the list read runs no git subprocess. */
const CLONING_POLL_MS = 5_000

/** When the oldest reading on screen was taken. One refresh re-reads them all. */
function OldestRead(props: { readonly keys: readonly string[] }) {
  let oldestMs: number | null = null
  for (const key of props.keys) {
    const observed = resourceCache.observe<unknown>(key).value
    if (observed.kind === 'value' && (oldestMs === null || observed.updatedAt < oldestMs)) oldestMs = observed.updatedAt
  }
  return oldestMs === null ? null : html`<${Ago} atSec=${oldestMs / MS_PER_SECOND} what="조회" />`
}

export function ReposTab(props: WorkspaceViewProps) {
  const session = authSession.value
  const readable = canReadRepos(session)
  const admin = canAdminRepos(session)
  const reposObs = resourceCache.observe<readonly InfraRepository[]>(REPOS_KEY).value
  const pullsObs = resourceCache.observe<PullsSnapshot>(PULLS_KEY).value
  const [selectedRepoId, setSelectedRepoId] = useState<string | null>(null)
  const [showAddForm, setShowAddForm] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [syncing, setSyncing] = useState<ReadonlySet<string>>(new Set())
  const [unfinishedSyncs, setUnfinishedSyncs] = useState<Readonly<Record<string, UnfinishedSync>>>({})
  // The app mounts a workspace anew for each session (`app.ts` keys it on the
  // session epoch), so an answer that arrives after the tab is gone, or for a
  // session that ended, has nothing here to tell.
  const mountedRef = useRef(true)
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const repos = reposObs.kind === 'value' ? reposObs.data : []
  const selectedRepo = repos.find((repo) => repo.id === selectedRepoId) ?? firstByName(repos)
  // The default is pinned once it is shown, so a repository that later sorts
  // ahead of it does not take the detail away.
  if (selectedRepo !== null && selectedRepo.id !== selectedRepoId) setSelectedRepoId(selectedRepo.id)

  // The loaders send nothing for a session that may not read.
  useEffect(() => {
    void loadRepos('mount')
    void loadPulls('mount')
  }, [readable])

  useRefetchWhenStale(reposObs, () => void loadRepos('mount'))
  useRefetchWhenStale(pullsObs, () => void loadPulls('mount'))

  // Each poll re-renders the tab, so this is judged again every time.
  const followingClone = repos.some((repo) => cloneInProgress(repo, Date.now() / MS_PER_SECOND))
  useEffect(() => {
    if (!followingClone) return undefined
    const timer = setInterval(() => void loadRepos('manual'), CLONING_POLL_MS)
    return () => clearInterval(timer)
  }, [followingClone])

  const refreshAll = async () => {
    setRefreshing(true)
    await Promise.all([
      loadRepos('manual'),
      loadPulls('manual'),
      ...(selectedRepo !== null ? [loadGit(selectedRepo.id, 'manual'), loadActivity(selectedRepo.id, 'manual')] : []),
    ])
    setRefreshing(false)
  }

  const handleAdded = async (name: string) => {
    const startEpoch = currentSessionEpoch()
    pushShellToast(`저장소 '${name}' 등록 완료.`, 'success')
    setShowAddForm(false)
    void loadPulls('manual')
    const list = await loadRepos('manual')
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    const created = list.kind === 'value' ? list.data.find((repo) => repo.name === name) : undefined
    if (created) setSelectedRepoId(created.id)
  }

  const handleSync = async (repo: InfraRepository) => {
    if (!canAdminRepos(authSession.peek())) return
    const startEpoch = currentSessionEpoch()
    setSyncing((prev) => new Set(prev).add(repo.id))
    const res = await apiMutate(
      'POST',
      `/api/v1/repositories/${encodeURIComponent(repo.id)}/sync`,
      {},
      { decode: (raw: unknown) => decodeRepositoryAdvance(raw, repo.id) },
    )
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    const atSec = Date.now() / MS_PER_SECOND
    // A sync that did what was asked says so in a toast and leaves the page as
    // it is. One that left the working tree alone, or failed, stays beside the
    // repository until its next sync answers.
    let done: string | null = null
    let unfinished: Fact | null = null
    if (!res.ok) {
      unfinished = { text: `동기화 실패: ${res.error.message}`, tone: 'bad' }
    } else {
      const summary = repositoryAdvanceSummary(res.value)
      if (summary.tone === 'success') done = `${repo.name} 동기화 완료. ${summary.message}`
      else unfinished = { text: summary.message, tone: 'warn' }
    }
    // The row is read before the result shows, so the result and the status
    // the sync left behind appear together.
    await loadRepos('manual')
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setSyncing((prev) => {
      const next = new Set(prev)
      next.delete(repo.id)
      return next
    })
    setUnfinishedSyncs(({ [repo.id]: _previous, ...rest }) => (
      unfinished === null ? rest : { ...rest, [repo.id]: { fact: unfinished, atSec } }
    ))
    if (done !== null) pushShellToast(done, 'success')
    // What was read about the clone before the sync is out of date, whether or
    // not this repository is the one on screen.
    resourceCache.invalidateKey(gitKey(repo.id))
    resourceCache.invalidateKey(activityKey(repo.id))
  }

  const readKeys = [
    REPOS_KEY,
    PULLS_KEY,
    ...(selectedRepo !== null ? [gitKey(selectedRepo.id)] : []),
    ...(selectedRepo !== null && admin ? [activityKey(selectedRepo.id)] : []),
  ]

  const title = html`
    <div>
      <span class="ov-eyebrow">6 INFRA · REPOS</span>
      <h1>저장소</h1>
    </div>
  `

  if (!readable) {
    return html`
      <div class="ov" data-testid="infra-repos-tab">
        <header class="ov-head">${title}</header>
        <div class="rp-empty" data-testid="infra-repos-mode-notice" role="status">
          저장소 목록과 Keeper 파일 기록(<span class="mono">/api/v1/repositories</span>, <span class="mono">/api/v1/ide/repository-activity</span>)은 single_user 모드 전용입니다.
        </div>
      </div>
    `
  }

  return html`
    <div class="ov" data-testid="infra-repos-tab">
      <header class="ov-head">
        ${title}
        <div class="rp-head-actions">
          <${OldestRead} keys=${readKeys} />
          <button type="button" class="btn-ghost" disabled=${refreshing} onClick=${() => void refreshAll()}>
            ${refreshing ? '새로고침 중…' : '새로고침'}
          </button>
          ${admin && html`
            <button type="button" class="btn-ghost" aria-expanded=${showAddForm} onClick=${() => setShowAddForm((v) => !v)}>
              ${showAddForm ? '추가 취소' : '저장소 추가'}
            </button>
          `}
        </div>
      </header>

      ${admin && showAddForm && html`<${RepoAddForm} onAdded=${(name: string) => void handleAdded(name)} />`}

      ${reposObs.kind === 'loading' && html`<${WaitLine} what="저장소 목록" />`}
      ${reposObs.kind === 'failed' && html`
        <${FailLine} what="저장소 목록" message=${reposObs.error.message} onRetry=${() => void loadRepos('manual')} />
      `}
      ${(reposObs.kind === 'absent' || reposObs.kind === 'unreported') && html`
        <div class="rp-empty">서버가 저장소 목록을 보내지 않았습니다.</div>
      `}
      ${reposObs.kind === 'value' && repos.length === 0 && html`
        <div class="rp-empty">등록된 저장소가 없습니다.</div>
      `}

      ${repos.length > 0 && html`
        <${RepoTable} repos=${repos} pulls=${pullsObs} selectedId=${selectedRepo?.id ?? null} onSelect=${setSelectedRepoId} />
      `}

      ${selectedRepo !== null && html`
        <${RepoDetail}
          key=${selectedRepo.id}
          repo=${selectedRepo}
          pulls=${pullsObs}
          canAdmin=${admin}
          syncing=${syncing.has(selectedRepo.id)}
          unfinishedSync=${unfinishedSyncs[selectedRepo.id]}
          onSync=${() => void handleSync(selectedRepo)}
          onInspect=${props.onInspect}
        />
      `}
    </div>
  `
}
