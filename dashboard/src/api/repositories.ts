import { del, get, post, type GetOptions } from './core'

export type RepoStatus = 'active' | 'paused' | 'error' | 'unknown'

export type RepositoryGitStatus =
  | {
      state: 'available'
      source: string
      dirty: boolean
      changed_files: number
      staged_files: number
      unstaged_files: number
      untracked_files: number
      conflicted_files: number
    }
  | {
      state: 'unavailable'
      source: string
      error: string
    }

export interface Repository {
  id: string
  name: string
  url: string
  local_path: string
  default_branch: string
  status: RepoStatus
  auto_sync: boolean
  sync_interval: number
  created_at: string | number | null
  updated_at: string | number | null
  git_status?: RepositoryGitStatus | null
}

export function normalizeRepoStatus(raw: string | undefined): RepoStatus {
  // Anti-pattern §2 escape: previously the `default` arm coerced unknown
  // statuses to `'active'`, silently hiding malformed wire data. Map only
  // recognized strings to first-class statuses; anything else surfaces as
  // `'unknown'` so the UI can render an explicit warning state instead of
  // pretending the repo is healthy.
  switch (raw?.toLowerCase()) {
    case 'active': return 'active'
    case 'paused': return 'paused'
    case 'cloning': return 'active' // intermediate state, treated as active
    case 'error': return 'error'
    default: return 'unknown'
  }
}

export function repositoryRows(raw: unknown): unknown[] {
  if (Array.isArray(raw)) return raw
  if (raw && typeof raw === 'object') {
    const record = raw as Record<string, unknown>
    if (Array.isArray(record.repositories)) return record.repositories
    if (record.ok === true && Array.isArray(record.data)) return record.data
  }
  return []
}

function isRecord(raw: unknown): raw is Record<string, unknown> {
  return raw !== null && typeof raw === 'object' && !Array.isArray(raw)
}

function finiteNumber(raw: unknown): number | null {
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : null
}

export function normalizeRepositoryGitStatus(raw: unknown): RepositoryGitStatus | null {
  if (!isRecord(raw)) return null
  const source = typeof raw.source === 'string' ? raw.source : ''
  const state = typeof raw.state === 'string' ? raw.state : ''
  if (state === 'available') {
    const changed_files = finiteNumber(raw.changed_files)
    const staged_files = finiteNumber(raw.staged_files)
    const unstaged_files = finiteNumber(raw.unstaged_files)
    const untracked_files = finiteNumber(raw.untracked_files)
    const conflicted_files = finiteNumber(raw.conflicted_files)
    if (
      typeof raw.dirty === 'boolean'
      && changed_files !== null
      && staged_files !== null
      && unstaged_files !== null
      && untracked_files !== null
      && conflicted_files !== null
    ) {
      return {
        state: 'available',
        source,
        dirty: raw.dirty,
        changed_files,
        staged_files,
        unstaged_files,
        untracked_files,
        conflicted_files,
      }
    }
    return {
      state: 'unavailable',
      source,
      error: 'malformed repository git_status payload',
    }
  }
  if (state === 'unavailable') {
    return {
      state: 'unavailable',
      source,
      error: typeof raw.error === 'string' ? raw.error : 'repository git status unavailable',
    }
  }
  return {
    state: 'unavailable',
    source,
    error: 'unknown repository git_status state',
  }
}

export function normalizeRepository(raw: unknown): Repository | null {
  if (!raw || typeof raw !== 'object') return null
  const r = raw as Record<string, unknown>
  const id = typeof r.id === 'string' ? r.id : ''
  const name = typeof r.name === 'string' ? r.name : ''
  if (!id || !name) return null
  return {
    id,
    name,
    url: typeof r.url === 'string' ? r.url : '',
    local_path: typeof r.local_path === 'string' ? r.local_path : '',
    default_branch: typeof r.default_branch === 'string' ? r.default_branch : 'main',
    status: normalizeRepoStatus(typeof r.status === 'string' ? r.status : undefined),
    auto_sync: r.auto_sync === true,
    sync_interval: typeof r.sync_interval === 'number' ? r.sync_interval : 300,
    created_at: typeof r.created_at === 'string' || typeof r.created_at === 'number' ? r.created_at : null,
    updated_at: typeof r.updated_at === 'string' || typeof r.updated_at === 'number' ? r.updated_at : null,
    git_status: normalizeRepositoryGitStatus(r.git_status),
  }
}

export async function fetchRepositoriesList(opts: GetOptions = {}): Promise<Repository[]> {
  const raw = await get<unknown>('/api/v1/repositories', opts)
  return repositoryRows(raw).map(normalizeRepository).filter((r): r is Repository => r !== null)
}

export async function discoverRepositories(): Promise<Repository[]> {
  const raw = await post<unknown>('/api/v1/repositories/discover', {})
  return repositoryRows(raw).map(normalizeRepository).filter((r): r is Repository => r !== null)
}

export interface AddRepositoryPayload {
  name: string
  url: string
  default_branch: string
  auto_sync: boolean
  sync_interval: number
  local_path?: string
}

export async function addRepository(payload: AddRepositoryPayload): Promise<void> {
  await post<unknown>('/api/v1/repositories', payload)
}

export async function removeRepository(id: string): Promise<void> {
  await del<unknown>(`/api/v1/repositories/${encodeURIComponent(id)}`)
}
