/**
 * Infra > Repos: the four reads of the tab, each a resource-cache entry.
 *
 * - GET /api/v1/repositories                    list (no git subprocess)
 * - GET /api/v1/repositories/pulls              GitHub PR snapshot for every repository
 * - GET /api/v1/git/status?repo_id=<id>         working tree of one repository
 * - GET /api/v1/ide/repository-activity         Keeper file writes (OkData envelope)
 */

import { useEffect } from 'preact/hooks'
import { apiGet, apiRequest, authSession, resourceCache, type AuthSession, type Observed } from '../../core'
import { expectOptionalRecordArrayField, expectWireRecord } from '../../lib/wire-decode'
import { isAdminLockedForSession } from '../../routes/router'
import { decodeGitStatus, type RepoGitState } from './repos-git-model'
import { decodeRepoList } from './repos-model'
import { decodePullsSnapshot, type PullsSnapshot } from './repos-pulls-model'
import type { InfraRepository, RepoActivityChange, RepoActivityData } from './types'

export const REPOS_KEY = 'infra:repositories'
export const PULLS_KEY = 'infra:repository-pulls'
export const gitKey = (repoId: string): string => `infra:repo-git:${repoId}`
export const activityKey = (repoId: string): string => `infra:repo-activity:${repoId}`

const LIST_TTL_MS = 20_000
const PULLS_TTL_MS = 30_000

/** `manual` reads again even when the cached answer is still fresh. */
export type Reason = 'mount' | 'manual'

/** The repository routes are served in single_user mode only; a multi_account
 *  server answers them 404. The list, the pull requests and the git status
 *  are `Public_read` there. */
export function canReadRepos(session: AuthSession): boolean {
  return session.kind === 'single_user_local'
}

/** Registering, syncing and the Keeper write record are `CanAdmin` routes. */
export function canAdminRepos(session: AuthSession): boolean {
  return canReadRepos(session) && !isAdminLockedForSession('admin', session)
}

/** What the cache holds for a key this session may not read: no request goes
 *  out, and the entry stays as it was. */
function unread<T>(key: string): Promise<Observed<T>> {
  return Promise.resolve(resourceCache.observe<T>(key).peek())
}

/** `changes` left out reads as none; `changes` that is not a list of objects
 *  fails the read. */
function decodeRepoActivityData(raw: unknown): RepoActivityData {
  const ctx = 'GET /api/v1/ide/repository-activity'
  const rec = expectWireRecord(raw, ctx)
  const changes = expectOptionalRecordArrayField<RepoActivityChange>(rec, 'changes', ctx)
  return {
    repo_id: typeof rec.repo_id === 'string' ? rec.repo_id : '',
    window_hours: typeof rec.window_hours === 'number' ? rec.window_hours : 24,
    incomplete: typeof rec.incomplete === 'number' ? rec.incomplete : 0,
    unattributed: typeof rec.unattributed === 'number' ? rec.unattributed : 0,
    changes,
  }
}

export function loadRepos(reason: Reason): Promise<Observed<readonly InfraRepository[]>> {
  if (!canReadRepos(authSession.peek())) return unread(REPOS_KEY)
  return resourceCache.fetch<readonly InfraRepository[]>(
    REPOS_KEY,
    (signal) => apiGet<readonly InfraRepository[]>('/api/v1/repositories', { signal, decode: decodeRepoList }),
    { ttlMs: LIST_TTL_MS, topics: ['repositories'], reason },
  )
}

export function loadPulls(reason: Reason): Promise<Observed<PullsSnapshot>> {
  if (!canReadRepos(authSession.peek())) return unread(PULLS_KEY)
  return resourceCache.fetch<PullsSnapshot>(
    PULLS_KEY,
    (signal) => apiGet<PullsSnapshot>('/api/v1/repositories/pulls', { signal, decode: decodePullsSnapshot }),
    { ttlMs: PULLS_TTL_MS, topics: ['repositories'], reason },
  )
}

export function loadGit(repoId: string, reason: Reason): Promise<Observed<RepoGitState>> {
  if (!canReadRepos(authSession.peek())) return unread(gitKey(repoId))
  return resourceCache.fetch<RepoGitState>(
    gitKey(repoId),
    (signal) => apiGet<RepoGitState>(
      `/api/v1/git/status?repo_id=${encodeURIComponent(repoId)}`,
      { signal, decode: decodeGitStatus },
    ),
    { ttlMs: LIST_TTL_MS, topics: ['repositories'], reason },
  )
}

export function loadActivity(repoId: string, reason: Reason): Promise<Observed<RepoActivityData>> {
  if (!canAdminRepos(authSession.peek())) return unread(activityKey(repoId))
  return resourceCache.fetch<RepoActivityData>(
    activityKey(repoId),
    (signal) => apiRequest<RepoActivityData>({
      method: 'GET',
      path: `/api/v1/ide/repository-activity?repo_id=${encodeURIComponent(repoId)}&window_hours=24`,
      envelope: 'ok_data',
      decode: decodeRepoActivityData,
      signal,
    }),
    { ttlMs: LIST_TTL_MS, topics: ['repository_activity'], reason },
  )
}

/** A topic event marks an entry stale without fetching; the mounted view is
 *  what reads it again. An answer outdated while it was in flight arrives
 *  already stale, so this follows every cache state, not only the flag
 *  turning on. A fetch in flight for the current state absorbs the call. */
export function useRefetchWhenStale(observed: Observed<unknown>, refetch: () => void): void {
  useEffect(() => {
    if (observed.kind === 'value' && observed.stale) refetch()
  }, [observed])
}
