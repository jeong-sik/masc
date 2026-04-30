import type { Agent, BoardPost, Task } from './types'

export type CollabMvpStackId =
  | 'yjs-document'
  | 'y-websocket-transport'
  | 'codemirror-editor'
  | 'cytoscape-git-graph'
  | 'todo-claim'
  | 'turn-queue'
  | 'otel-events'

export type CollabMvpStackStatus = 'contract' | 'installed' | 'observed'

export interface CollabMvpStackItem {
  id: CollabMvpStackId
  label: string
  packageName?: string
  status: CollabMvpStackStatus
  owner: 'masc'
}

export const COLLAB_MVP_STACK: CollabMvpStackItem[] = [
  {
    id: 'yjs-document',
    label: 'Yjs document model',
    packageName: 'yjs',
    status: 'contract',
    owner: 'masc',
  },
  {
    id: 'y-websocket-transport',
    label: 'y-websocket sync lane',
    packageName: 'y-websocket',
    status: 'contract',
    owner: 'masc',
  },
  {
    id: 'codemirror-editor',
    label: 'CodeMirror 6 editor binding',
    packageName: '@codemirror/view',
    status: 'contract',
    owner: 'masc',
  },
  {
    id: 'cytoscape-git-graph',
    label: 'cytoscape Git graph',
    packageName: 'cytoscape',
    status: 'installed',
    owner: 'masc',
  },
  {
    id: 'todo-claim',
    label: 'TODO Claim protocol',
    status: 'observed',
    owner: 'masc',
  },
  {
    id: 'turn-queue',
    label: 'Turn Queue',
    status: 'observed',
    owner: 'masc',
  },
  {
    id: 'otel-events',
    label: 'OpenTelemetry event semantics',
    status: 'contract',
    owner: 'masc',
  },
]

export type CollabMvpEventName =
  | 'masc.collab.doc.sync'
  | 'masc.collab.todo.claim'
  | 'masc.collab.turn.queue'
  | 'masc.collab.git.graph'

export interface CollabMvpEventSemantic {
  name: CollabMvpEventName
  source: 'dashboard' | 'keeper_coordination' | 'git_projection' | 'crdt_transport'
  attributes: string[]
}

export type CollabPerformanceBudgetMetricId =
  | 'sync_latency_p95_ms'
  | 'ws_connect_p95_ms'
  | 'checks_rate'
  | 'keystroke_latency_ms'
  | 'fps'
  | 'lcp_ms'
  | 'inp_ms'
  | 'document_size_bytes'
  | 'merge_12_docs_ms'
  | 'ops_per_sec'

export type CollabPerformanceBudgetComparator = 'lt' | 'lte' | 'gt' | 'gte'
export type CollabPerformanceBudgetUnit = 'ms' | 'ratio' | 'fps' | 'bytes' | 'ops/sec'

export interface CollabPerformanceBudgetMetric {
  id: CollabPerformanceBudgetMetricId
  label: string
  unit: CollabPerformanceBudgetUnit
  target: number
  comparator: CollabPerformanceBudgetComparator
  sourceSection: 'multiagent-ide-deep-analysis.md#8'
  owner: 'masc'
}

export interface CollabPerformanceBudgetResult {
  id: CollabPerformanceBudgetMetricId
  value: number
  target: number
  comparator: CollabPerformanceBudgetComparator
  pass: boolean
}

export const COLLAB_TRACK8_PERFORMANCE_BUDGET: CollabPerformanceBudgetMetric[] = [
  {
    id: 'sync_latency_p95_ms',
    label: 'Sync latency p95',
    unit: 'ms',
    target: 100,
    comparator: 'lt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'ws_connect_p95_ms',
    label: 'WebSocket connect p95',
    unit: 'ms',
    target: 500,
    comparator: 'lt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'checks_rate',
    label: 'Checks pass rate',
    unit: 'ratio',
    target: 0.99,
    comparator: 'gt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'keystroke_latency_ms',
    label: 'Keystroke latency',
    unit: 'ms',
    target: 16,
    comparator: 'lt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'fps',
    label: 'Frame rate',
    unit: 'fps',
    target: 55,
    comparator: 'gte',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'lcp_ms',
    label: 'Largest Contentful Paint',
    unit: 'ms',
    target: 2500,
    comparator: 'lt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'inp_ms',
    label: 'Interaction to Next Paint',
    unit: 'ms',
    target: 200,
    comparator: 'lt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'document_size_bytes',
    label: 'Document size',
    unit: 'bytes',
    target: 10 * 1024 * 1024,
    comparator: 'lt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'merge_12_docs_ms',
    label: 'Merge 12 docs',
    unit: 'ms',
    target: 100,
    comparator: 'lt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
  {
    id: 'ops_per_sec',
    label: 'CRDT throughput',
    unit: 'ops/sec',
    target: 1000,
    comparator: 'gt',
    sourceSection: 'multiagent-ide-deep-analysis.md#8',
    owner: 'masc',
  },
]

export const COLLAB_MVP_EVENT_SEMANTICS: CollabMvpEventSemantic[] = [
  {
    name: 'masc.collab.doc.sync',
    source: 'crdt_transport',
    attributes: [
      'masc.workspace_id',
      'masc.doc_id',
      'masc.agent_id',
      'masc.crdt.provider',
      'masc.sync.bytes',
      'masc.sync.latency_ms',
    ],
  },
  {
    name: 'masc.collab.todo.claim',
    source: 'keeper_coordination',
    attributes: [
      'masc.task_id',
      'masc.claimant',
      'masc.claim.state',
      'masc.claim.scope',
      'masc.goal_id',
    ],
  },
  {
    name: 'masc.collab.turn.queue',
    source: 'keeper_coordination',
    attributes: [
      'masc.agent_id',
      'masc.turn.rank',
      'masc.turn.state',
      'masc.current_task_id',
      'masc.queue.depth',
    ],
  },
  {
    name: 'masc.collab.git.graph',
    source: 'git_projection',
    attributes: [
      'masc.repo_name',
      'masc.git.branch',
      'masc.git.worktree_path',
      'masc.task_id',
      'masc.agent_id',
    ],
  },
]

function passesPerformanceBudget(
  value: number,
  target: number,
  comparator: CollabPerformanceBudgetComparator,
): boolean {
  switch (comparator) {
    case 'lt':
      return value < target
    case 'lte':
      return value <= target
    case 'gt':
      return value > target
    case 'gte':
      return value >= target
  }
}

export function evaluateCollabPerformanceBudget(
  samples: Partial<Record<CollabPerformanceBudgetMetricId, number>>,
): CollabPerformanceBudgetResult[] {
  return COLLAB_TRACK8_PERFORMANCE_BUDGET.flatMap(metric => {
    const value = samples[metric.id]
    if (value === undefined) return []
    return [{
      id: metric.id,
      value,
      target: metric.target,
      comparator: metric.comparator,
      pass: Number.isFinite(value) && passesPerformanceBudget(value, metric.target, metric.comparator),
    }]
  })
}

export type TodoClaimState = 'unclaimed' | 'claimed' | 'running' | 'verification' | 'terminal'

export interface CollabTodoClaim {
  taskId: string
  title: string
  priority: number
  state: TodoClaimState
  claimant: string | null
  goalId: string | null
  branch: string | null
  repoName: string | null
}

export type TurnQueueState = 'running' | 'waiting' | 'idle'

export interface CollabTurnQueueEntry {
  agentName: string
  rank: number
  state: TurnQueueState
  currentTaskId: string | null
  observedAt: string | null
}

export type CollabGitGraphNodeType = 'repo' | 'main' | 'branch' | 'task'
export type CollabGitGraphSource = 'worktree' | 'coordination_fallback'

export interface CollabGitGraphNode {
  id: string
  label: string
  type: CollabGitGraphNodeType
  parent?: string
  source: CollabGitGraphSource
}

export interface CollabGitGraphEdge {
  id: string
  source: string
  target: string
  label?: string
}

export interface CollabGitGraphSpec {
  nodes: CollabGitGraphNode[]
  edges: CollabGitGraphEdge[]
  source: CollabGitGraphSource
}

export interface CollabMvpProjection {
  generatedAt: string
  summary: {
    activeAgents: number
    openClaims: number
    unclaimedTasks: number
    worktreeBackedBranches: number
    boardObservations: number
  }
  todoClaims: CollabTodoClaim[]
  turnQueue: CollabTurnQueueEntry[]
  gitGraph: CollabGitGraphSpec
}

export interface BuildCollabMvpProjectionArgs {
  agents: readonly Agent[]
  tasks: readonly Task[]
  boardPosts: readonly BoardPost[]
  nowIso?: string
}

const ACTIVE_TASK_STATUSES = new Set(['claimed', 'in_progress', 'awaiting_verification'])
const OPEN_CLAIM_STATES = new Set<TodoClaimState>(['unclaimed', 'claimed', 'running', 'verification'])

function fallbackNowIso(): string {
  try {
    return new Date().toISOString()
  } catch {
    return ''
  }
}

function statusOf(task: Task): string {
  return task.status ?? 'todo'
}

function claimStateOf(task: Task): TodoClaimState {
  switch (statusOf(task)) {
    case 'todo':
      return 'unclaimed'
    case 'claimed':
      return 'claimed'
    case 'in_progress':
      return 'running'
    case 'awaiting_verification':
      return 'verification'
    default:
      return 'terminal'
  }
}

function branchForTask(task: Task): string | null {
  if (task.worktree?.branch) return task.worktree.branch
  if (task.assignee && ACTIVE_TASK_STATUSES.has(statusOf(task))) return `${task.assignee}/${task.id}`
  return null
}

function repoNameForTask(task: Task): string | null {
  return task.worktree?.repo_name || null
}

function taskClaimant(task: Task): string | null {
  return task.assignee ?? null
}

function compareClaims(a: CollabTodoClaim, b: CollabTodoClaim): number {
  if (a.state === 'terminal' && b.state !== 'terminal') return 1
  if (b.state === 'terminal' && a.state !== 'terminal') return -1
  if (a.priority !== b.priority) return a.priority - b.priority
  return a.taskId.localeCompare(b.taskId)
}

function makeTodoClaims(tasks: readonly Task[]): CollabTodoClaim[] {
  return tasks
    .map(task => ({
      taskId: task.id,
      title: task.title,
      priority: task.priority ?? 3,
      state: claimStateOf(task),
      claimant: taskClaimant(task),
      goalId: task.goal_id ?? null,
      branch: branchForTask(task),
      repoName: repoNameForTask(task),
    }))
    .sort(compareClaims)
}

function makeTurnQueue(agents: readonly Agent[], tasks: readonly Task[]): CollabTurnQueueEntry[] {
  const seen = new Set<string>()
  const activeTaskByAgent = new Map<string, string>()
  for (const task of tasks) {
    if (task.assignee && ACTIVE_TASK_STATUSES.has(statusOf(task))) {
      activeTaskByAgent.set(task.assignee, task.id)
    }
  }

  const entries: CollabTurnQueueEntry[] = agents.map(agent => {
    seen.add(agent.name)
    const currentTaskId = agent.current_task ?? activeTaskByAgent.get(agent.name) ?? null
    return {
      agentName: agent.name,
      rank: 0,
      state: currentTaskId ? 'running' : agent.status === 'idle' ? 'idle' : 'waiting',
      currentTaskId,
      observedAt: agent.last_seen ?? null,
    }
  })

  for (const [agentName, taskId] of activeTaskByAgent.entries()) {
    if (seen.has(agentName)) continue
    entries.push({
      agentName,
      rank: 0,
      state: 'running',
      currentTaskId: taskId,
      observedAt: null,
    })
  }

  return entries
    .sort((a, b) => {
      const stateRank = (entry: CollabTurnQueueEntry) =>
        entry.state === 'running' ? 0 : entry.state === 'waiting' ? 1 : 2
      const stateDelta = stateRank(a) - stateRank(b)
      if (stateDelta !== 0) return stateDelta
      return a.agentName.localeCompare(b.agentName)
    })
    .map((entry, index) => ({ ...entry, rank: index + 1 }))
}

function graphId(...parts: string[]): string {
  return parts
    .join(':')
    .replace(/[^a-zA-Z0-9:_./-]+/g, '-')
    .replace(/-+/g, '-')
}

function makeGitGraph(claims: readonly CollabTodoClaim[]): CollabGitGraphSpec {
  const nodes = new Map<string, CollabGitGraphNode>()
  const edges = new Map<string, CollabGitGraphEdge>()
  let hasWorktree = false

  const addNode = (node: CollabGitGraphNode) => {
    if (!nodes.has(node.id)) nodes.set(node.id, node)
  }
  const addEdge = (edge: CollabGitGraphEdge) => {
    if (!edges.has(edge.id)) edges.set(edge.id, edge)
  }

  const visibleClaims = claims.filter(claim => claim.state !== 'terminal').slice(0, 18)
  const source: CollabGitGraphSource = visibleClaims.some(claim => claim.branch && claim.repoName)
    ? 'worktree'
    : 'coordination_fallback'

  for (const claim of visibleClaims) {
    const repoName = claim.repoName ?? 'coordination'
    const repoId = graphId('repo', repoName)
    const mainId = graphId('main', repoName)
    const branch = claim.branch ?? `unclaimed/${claim.taskId}`
    const branchId = graphId('branch', repoName, branch)
    const taskId = graphId('task', claim.taskId)
    const nodeSource: CollabGitGraphSource = claim.repoName && claim.branch
      ? 'worktree'
      : 'coordination_fallback'

    hasWorktree = hasWorktree || nodeSource === 'worktree'
    addNode({ id: repoId, label: repoName, type: 'repo', source: nodeSource })
    addNode({ id: mainId, label: 'main', type: 'main', parent: repoId, source: nodeSource })
    addNode({ id: branchId, label: branch, type: 'branch', parent: repoId, source: nodeSource })
    addNode({ id: taskId, label: claim.taskId, type: 'task', parent: branchId, source: nodeSource })
    addEdge({ id: graphId('edge', mainId, branchId), source: mainId, target: branchId })
    addEdge({ id: graphId('edge', branchId, taskId), source: branchId, target: taskId, label: claim.claimant ?? claim.state })
  }

  if (nodes.size === 0) {
    addNode({ id: 'repo:coordination', label: 'coordination', type: 'repo', source })
    addNode({ id: 'main:coordination', label: 'main', type: 'main', parent: 'repo:coordination', source })
  }

  return {
    nodes: Array.from(nodes.values()),
    edges: Array.from(edges.values()),
    source: hasWorktree ? 'worktree' : source,
  }
}

export function buildCollabMvpProjection({
  agents,
  tasks,
  boardPosts,
  nowIso,
}: BuildCollabMvpProjectionArgs): CollabMvpProjection {
  const todoClaims = makeTodoClaims(tasks)
  const openClaims = todoClaims.filter(claim => OPEN_CLAIM_STATES.has(claim.state))
  const turnQueue = makeTurnQueue(agents, tasks)
  const gitGraph = makeGitGraph(todoClaims)

  return {
    generatedAt: nowIso ?? fallbackNowIso(),
    summary: {
      activeAgents: agents.filter(agent => agent.status !== 'offline').length,
      openClaims: openClaims.length,
      unclaimedTasks: todoClaims.filter(claim => claim.state === 'unclaimed').length,
      worktreeBackedBranches: todoClaims.filter(claim => claim.branch && claim.repoName).length,
      boardObservations: boardPosts.length,
    },
    todoClaims,
    turnQueue,
    gitGraph,
  }
}
