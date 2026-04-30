import { get } from './core'
import {
  parseGitGraphResponse,
  type GitGraphResponse,
} from './schemas/git-graph'

export type {
  GitGraphAgent,
  GitGraphEdge,
  GitGraphNode,
  GitGraphRepo,
  GitGraphResponse,
  GitGraphStats,
} from './schemas/git-graph'

export { GitGraphSchemaDriftError } from './schemas/git-graph'

export async function fetchGitGraph(opts?: {
  limit?: number
  signal?: AbortSignal
}): Promise<GitGraphResponse> {
  const params = new URLSearchParams()
  if (opts?.limit) params.set('n', String(opts.limit))
  const raw = await get<unknown>(
    `/api/v1/git/graph${params.size > 0 ? `?${params.toString()}` : ''}`,
    { signal: opts?.signal },
  )
  return parseGitGraphResponse(raw)
}
