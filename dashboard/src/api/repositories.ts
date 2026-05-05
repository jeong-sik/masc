import { get, type GetOptions } from './core'

export type RepoStatus = 'active' | 'paused' | 'error'

export interface Repository {
  id: string
  name: string
  url: string
  local_path: string
  default_branch: string
  status: RepoStatus
  auto_sync: boolean
  sync_interval: number
  credential_id: string | null
  created_at: string | number | null
  updated_at: string | number | null
}

export function normalizeRepoStatus(raw: string | undefined): RepoStatus {
  switch (raw?.toLowerCase()) {
    case 'active': return 'active'
    case 'paused': return 'paused'
    case 'cloning': return 'active'
    case 'error': return 'error'
    default: return 'active'
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
    credential_id: typeof r.credential_id === 'string' ? r.credential_id : null,
    created_at: typeof r.created_at === 'string' || typeof r.created_at === 'number' ? r.created_at : null,
    updated_at: typeof r.updated_at === 'string' || typeof r.updated_at === 'number' ? r.updated_at : null,
  }
}

export async function fetchRepositoriesList(opts: GetOptions = {}): Promise<Repository[]> {
  const raw = await get<unknown>('/api/v1/repositories', opts)
  return repositoryRows(raw).map(normalizeRepository).filter((r): r is Repository => r !== null)
}
