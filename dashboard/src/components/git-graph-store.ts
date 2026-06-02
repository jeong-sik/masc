import { createManagedAsyncResource } from '../lib/async-state'
import { fetchGitGraph, type GitGraphResponse } from '../api/git-graph'

export const gitGraphResource = createManagedAsyncResource<GitGraphResponse | null>(null)

export function refreshGitGraph(repoId?: string | null) {
  return gitGraphResource.load((signal) => fetchGitGraph({ limit: 160, repoId, signal }))
}

export function cancelGitGraphRefresh(): void {
  gitGraphResource.cancel()
}
