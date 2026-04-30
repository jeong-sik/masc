// Git graph schema — schema-at-boundary for GET /api/v1/git/graph.

import {
  array,
  boolean,
  nullable,
  number,
  object,
  safeParse,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

const RepoInfoSchema = object({
  id: string(),
  root: string(),
  label: string(),
  current_branch: nullable(string()),
  head: nullable(string()),
  dirty: boolean(),
  conflict_count: number(),
  branch_count: number(),
  commit_count: number(),
  worktree_count: number(),
})

const AgentLaneSchema = object({
  id: string(),
  label: string(),
  branch: nullable(string()),
  worktree_path: string(),
  color: string(),
})

const GraphNodeSchema = object({
  id: string(),
  kind: string(),
  label: string(),
  repo_id: string(),
  agent_id: nullable(string()),
  color: nullable(string()),
  status: string(),
  conflict: boolean(),
  sha: nullable(string()),
  branch: nullable(string()),
  detail: nullable(string()),
})

const GraphEdgeSchema = object({
  id: string(),
  source: string(),
  target: string(),
  kind: string(),
  label: nullable(string()),
})

const StatsSchema = object({
  repo_count: number(),
  agent_count: number(),
  branch_count: number(),
  commit_count: number(),
  conflict_count: number(),
  dirty_count: number(),
})

const GitGraphResponseSchema = object({
  generated_at: string(),
  repos: array(RepoInfoSchema),
  agents: array(AgentLaneSchema),
  nodes: array(GraphNodeSchema),
  edges: array(GraphEdgeSchema),
  stats: StatsSchema,
  warnings: array(string()),
})

export type GitGraphRepo = InferOutput<typeof RepoInfoSchema>
export type GitGraphAgent = InferOutput<typeof AgentLaneSchema>
export type GitGraphNode = InferOutput<typeof GraphNodeSchema>
export type GitGraphEdge = InferOutput<typeof GraphEdgeSchema>
export type GitGraphStats = InferOutput<typeof StatsSchema>
export type GitGraphResponse = InferOutput<typeof GitGraphResponseSchema>

export class GitGraphSchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]

  constructor(issues: readonly BaseIssue<unknown>[]) {
    const summary = issues
      .map(issue => {
        const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
        return `${path}: ${issue.message}`
      })
      .join('; ')
    super(`git-graph schema drift: ${summary}`)
    this.name = GitGraphSchemaDriftError.name
    this.issues = issues
  }
}

export function parseGitGraphResponse(data: unknown): GitGraphResponse {
  const result = safeParse(GitGraphResponseSchema, data, { abortEarly: true })
  if (!result.success) {
    throw new GitGraphSchemaDriftError(result.issues)
  }
  return result.output
}
