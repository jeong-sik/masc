// Live Topology Map — real-time force-directed graph of agent/task connections
//
// Derives its data from the live agent and task signals rather than historical
// activity-graph API data.  Each agent is a node; edges come from:
//   - agent.keeper_name  (agent → keeper, "supervised by")
//   - task.assignee      (task → agent, "assigned to")
// Active/busy agents pulse; offline agents fade.  Tasks in stalled states
// (awaiting_verification) render with a warning color.
//
// Uses vis-network (already a project dependency) with the forceAtlas2Based
// physics solver — the same solver as activity-graph-view.ts — so the visual
// language is consistent across topology surfaces.

import { html } from 'htm/preact'
import { computed, type ReadonlySignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { Network } from 'vis-network'
import { DataSet } from 'vis-data'
// Match the codebase convention from activity-graph-view.ts: pull the
// vis-network base stylesheet locally so this surface renders with the
// expected container/interaction/tooltip styles even when imported in
// isolation.
import 'vis-network/styles/vis-network.css'
import { agents, tasks, keepers } from '../../store'
import { openAgentDetail } from '../agent-detail-state'
import type { Agent, Task, Keeper } from '../../types/core'

// ─── Pure helpers (exported for tests) ───────────────────────────────────────

interface TopologyNode {
  id: string
  label: string
  kind: 'agent' | 'keeper' | 'task'
  status: string
}

interface TopologyEdge {
  from: string
  to: string
  kind: 'supervised_by' | 'assigned_to'
}

interface TopologyGraph {
  nodes: TopologyNode[]
  edges: TopologyEdge[]
}

/** Map an agent/task status to a vis-network compatible color string. */
function topologyNodeColor(kind: 'agent' | 'keeper' | 'task', status: string): string {
  if (status === 'offline' || status === 'inactive') {
    return 'var(--color-fg-disabled)'
  }
  switch (kind) {
    case 'keeper':
      return 'var(--color-status-ok)'
    case 'agent':
      if (status === 'active' || status === 'busy') return 'var(--cyan)'
      return 'var(--info-border)'
    case 'task':
      if (status === 'awaiting_verification') return 'var(--color-status-warn)'
      if (status === 'done') return 'var(--ok-border)'
      return 'var(--warn-fg)'
    default:
      return 'var(--color-fg-muted)'
  }
}

/** Build a topology graph from the live agent/task/keeper state.
 *
 * Inclusion rules:
 *   - All keepers (as anchor nodes for their agents).
 *   - Every agent in `agentList` is included as a node; visual
 *     de-emphasis for `offline` / `inactive` agents is delegated to
 *     [topologyNodeColor]. (Agent.status is `string` and the runtime
 *     does not currently emit a "done" / "retired" state, so the
 *     filter is intentionally absent here rather than guessing at
 *     status names that may not appear.)
 *   - Tasks that are currently in-progress, claimed, or awaiting_verification.
 *     Completed/cancelled tasks are omitted to keep the graph readable.
 *
 * Edge rules:
 *   - agent → keeper when `agent.keeper_name` matches a known keeper.
 *   - task → agent when `task.assignee` matches a known agent name.
 */
function buildTopologyGraph(
  agentList: readonly Agent[],
  taskList: readonly Task[],
  keeperList: readonly Keeper[],
): TopologyGraph {
  const nodes: TopologyNode[] = []
  const edges: TopologyEdge[] = []

  const keeperIdSet = new Set<string>()
  const agentNameSet = new Set<string>()

  // Keeper nodes
  for (const k of keeperList) {
    const id = `keeper:${k.name}`
    keeperIdSet.add(k.name)
    nodes.push({
      id,
      label: k.koreanName && k.koreanName !== '' ? k.koreanName : k.name,
      kind: 'keeper',
      status: k.status ?? 'idle',
    })
  }

  // Agent nodes + supervisor edges
  for (const a of agentList) {
    const id = `agent:${a.name}`
    agentNameSet.add(a.name)
    nodes.push({
      id,
      label: a.koreanName && a.koreanName !== '' ? a.koreanName : a.name,
      kind: 'agent',
      status: a.status ?? 'idle',
    })
    if (a.keeper_name && keeperIdSet.has(a.keeper_name)) {
      edges.push({ from: id, to: `keeper:${a.keeper_name}`, kind: 'supervised_by' })
    }
  }

  // Active task nodes + assignment edges
  const ACTIVE_TASK_STATUSES = new Set(['in_progress', 'claimed', 'awaiting_verification'])
  for (const t of taskList) {
    if (!t.status || !ACTIVE_TASK_STATUSES.has(t.status)) continue
    const id = `task:${t.id}`
    nodes.push({
      id,
      label: t.title.length > 24 ? `${t.title.slice(0, 22)}…` : t.title,
      kind: 'task',
      status: t.status,
    })
    if (t.assignee && agentNameSet.has(t.assignee)) {
      edges.push({ from: id, to: `agent:${t.assignee}`, kind: 'assigned_to' })
    }
  }

  return { nodes, edges }
}

// ─── Derived signal ───────────────────────────────────────────────────────────

const liveTopologyGraph: ReadonlySignal<TopologyGraph> = computed(() =>
  buildTopologyGraph(agents.value, tasks.value, keepers.value),
)

// ─── Component ───────────────────────────────────────────────────────────────

function nodeShape(kind: 'agent' | 'keeper' | 'task'): string {
  switch (kind) {
    case 'keeper': return 'diamond'
    case 'task': return 'box'
    default: return 'dot'
  }
}

interface VisTopologyNode {
  id: string
  label: string
  title: string
  shape: string
  color: {
    background: string
    border: string
    highlight: { background: string; border: string }
    hover: { background: string; border: string }
  }
  font: { color: string; size: number }
  size: number
}

interface VisTopologyEdge {
  id: string
  from: string
  to: string
  color: { color: string; highlight: string }
  arrows: { to: { enabled: boolean; scaleFactor: number } }
  dashes: boolean
  width: number
}

function toVisNodes(graph: TopologyGraph): VisTopologyNode[] {
  return graph.nodes.map(n => {
    const color = topologyNodeColor(n.kind, n.status)
    return {
      id: n.id,
      label: n.label,
      title: `${n.id} · ${n.status}`,
      shape: nodeShape(n.kind),
      color: {
        background: color,
        border: color,
        highlight: { background: color, border: 'var(--color-status-warn)' },
        hover: { background: color, border: 'var(--white-pure)' },
      },
      font: { color: 'var(--frost-100)', size: 11 },
      size: n.kind === 'keeper' ? 14 : n.kind === 'task' ? 8 : 10,
    }
  })
}

function toVisEdges(graph: TopologyGraph): VisTopologyEdge[] {
  return graph.edges.map(e => ({
    id: `${e.kind}:${e.from}->${e.to}`,
    from: e.from,
    to: e.to,
    color: {
      color: e.kind === 'supervised_by'
        ? 'var(--ok-border)'
        : 'var(--warn-border)',
      highlight: e.kind === 'supervised_by'
        ? 'var(--ok-fg)'
        : 'var(--warn-fg)',
    },
    arrows: { to: { enabled: true, scaleFactor: 0.45 } },
    dashes: e.kind === 'assigned_to',
    width: 1,
  }))
}

function staleIdsFor<T extends { id: string }>(dataSet: DataSet<T>, nextItems: T[]) {
  const nextIds = new Set(nextItems.map(item => item.id))
  return dataSet.getIds().filter(id => !nextIds.has(String(id)))
}

function syncTopologyData(
  nodesData: DataSet<VisTopologyNode>,
  edgesData: DataSet<VisTopologyEdge>,
  graph: TopologyGraph,
) {
  const nextNodes = toVisNodes(graph)
  const staleNodeIds = staleIdsFor(nodesData, nextNodes)
  if (staleNodeIds.length > 0) {
    nodesData.remove(staleNodeIds)
  }
  if (nextNodes.length > 0) {
    nodesData.update(nextNodes)
  }

  const nextEdges = toVisEdges(graph)
  const staleEdgeIds = staleIdsFor(edgesData, nextEdges)
  if (staleEdgeIds.length > 0) {
    edgesData.remove(staleEdgeIds)
  }
  if (nextEdges.length > 0) {
    edgesData.update(nextEdges)
  }
}

export function LiveTopologyMap() {
  const graph = liveTopologyGraph.value
  const containerRef = useRef<HTMLDivElement>(null)
  const networkRef = useRef<Network | null>(null)
  const nodesDataRef = useRef<DataSet<VisTopologyNode> | null>(null)
  const edgesDataRef = useRef<DataSet<VisTopologyEdge> | null>(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    const options = {
      nodes: { borderWidth: 1, borderWidthSelected: 2.5 },
      edges: {
        smooth: { enabled: true, type: 'continuous', roundness: 0.4 },
      },
      physics: {
        forceAtlas2Based: {
          gravitationalConstant: -40,
          centralGravity: 0.015,
          springLength: 90,
          springConstant: 0.07,
        },
        maxVelocity: 50,
        solver: 'forceAtlas2Based',
        timestep: 0.35,
        stabilization: { iterations: 120 },
      },
      interaction: {
        hover: true,
        tooltipDelay: 150,
        zoomView: true,
        dragView: true,
      },
    }

    const nodesData = new DataSet<VisTopologyNode>([])
    const edgesData = new DataSet<VisTopologyEdge>([])
    nodesDataRef.current = nodesData
    edgesDataRef.current = edgesData

    const network = new Network(container, { nodes: nodesData, edges: edgesData }, options)
    networkRef.current = network

    network.on('click', params => {
      if (params.nodes.length > 0) {
        const nodeId = String(params.nodes[0])
        if (nodeId.startsWith('agent:')) {
          openAgentDetail(nodeId.slice('agent:'.length))
        }
      }
    })

    return () => {
      network.destroy()
      networkRef.current = null
      nodesDataRef.current = null
      edgesDataRef.current = null
    }
  }, [])

  useEffect(() => {
    const nodesData = nodesDataRef.current
    const edgesData = edgesDataRef.current
    if (!nodesData || !edgesData) return
    syncTopologyData(nodesData, edgesData, graph)
  }, [graph])

  return html`
    <div class="relative w-full rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--color-bg-surface)] overflow-hidden">
      <div ref=${containerRef} class="w-full h-64" role="img" aria-label="라이브 에이전트 토폴로지 맵"></div>
      ${graph.nodes.length === 0
        ? html`
          <div class="absolute inset-0 flex items-center justify-center text-sm text-[var(--color-fg-muted)]">
            연결된 에이전트 없음 — 에이전트가 접속하면 여기에 표시됩니다.
          </div>
        `
        : null}
      <div class="absolute bottom-2 right-2 flex flex-wrap gap-2.5 text-3xs text-[var(--color-fg-muted)]">
        <span class="flex items-center gap-1"><span class="inline-block size-2 rounded-full bg-[var(--color-status-ok)]"></span>Keeper</span>
        <span class="flex items-center gap-1"><span class="inline-block size-2 rounded-full bg-[var(--cyan)]"></span>에이전트</span>
        <span class="flex items-center gap-1"><span class="inline-block size-2 rounded-[var(--r-0)] bg-[var(--warn-fg)]"></span>작업</span>
      </div>
    </div>
  `
}
