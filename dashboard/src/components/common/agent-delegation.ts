// AgentDelegation — AX organism that renders an agent delegation tree.
//
// Kimi design system sec05 reference: recursive tree of sub-task delegation
// with AgentPresence integration. Each node shows task, agent id and
// elapsed time.

import { html } from 'htm/preact'
import { AgentPresence } from './agent-presence'

export type DelegationStatus = 'pending' | 'active' | 'completed' | 'failed'
export type DelegationTreeStatus = 'empty' | 'pending' | 'active' | 'completed' | 'failed' | 'mixed'

export interface DelegationNode {
  agentId: string
  task: string
  status: DelegationStatus
  children?: DelegationNode[]
  startedAt?: number
  completedAt?: number
}

export interface DelegationNodeSummary {
  readonly node: DelegationNode
  readonly depth: number
  readonly index: number
  readonly childCount: number
  readonly leaf: boolean
  readonly elapsedMs: number | null
}

export interface DelegationSummary {
  readonly totalCount: number
  readonly leafCount: number
  readonly maxDepth: number
  readonly pendingCount: number
  readonly activeCount: number
  readonly completedCount: number
  readonly failedCount: number
  readonly latestStartedAt: number | null
  readonly latestCompletedAt: number | null
  readonly longestElapsedMs: number | null
  readonly status: DelegationTreeStatus
}

interface AgentDelegationProps {
  root: DelegationNode
  testId?: string
}

export function statusToPresence(status: DelegationStatus): string {
  switch (status) {
    case 'active':
      return 'busy'
    case 'completed':
      return 'active'
    case 'failed':
      return 'inactive'
    case 'pending':
    default:
      return 'idle'
  }
}

export function elapsedMs(startedAt?: number, completedAt?: number): number | null {
  if (startedAt == null || completedAt == null) return null
  const ms = completedAt - startedAt
  if (ms < 0) return null
  return ms
}

export function formatElapsed(startedAt?: number, completedAt?: number): string | null {
  const ms = elapsedMs(startedAt, completedAt)
  if (ms == null) return null
  return `${(ms / 1000).toFixed(1)}s`
}

export function flattenDelegationTree(root: DelegationNode): DelegationNodeSummary[] {
  const items: DelegationNodeSummary[] = []
  const visit = (node: DelegationNode, depth: number) => {
    const childCount = node.children?.length ?? 0
    items.push({
      node,
      depth,
      index: items.length,
      childCount,
      leaf: childCount === 0,
      elapsedMs: elapsedMs(node.startedAt, node.completedAt),
    })
    node.children?.forEach((child) => visit(child, depth + 1))
  }
  visit(root, 0)
  return items
}

export function summarizeDelegationTree(root: DelegationNode): DelegationSummary {
  const items = flattenDelegationTree(root)
  let pendingCount = 0
  let activeCount = 0
  let completedCount = 0
  let failedCount = 0
  let latestStartedAt: number | null = null
  let latestCompletedAt: number | null = null
  let longestElapsedMs: number | null = null

  items.forEach((item) => {
    switch (item.node.status) {
      case 'pending':
        pendingCount += 1
        break
      case 'active':
        activeCount += 1
        break
      case 'completed':
        completedCount += 1
        break
      case 'failed':
        failedCount += 1
        break
    }

    if (Number.isFinite(item.node.startedAt)) {
      latestStartedAt = latestStartedAt === null ? item.node.startedAt ?? null : Math.max(latestStartedAt, item.node.startedAt ?? 0)
    }
    if (Number.isFinite(item.node.completedAt)) {
      latestCompletedAt = latestCompletedAt === null ? item.node.completedAt ?? null : Math.max(latestCompletedAt, item.node.completedAt ?? 0)
    }
    if (item.elapsedMs != null) {
      longestElapsedMs = longestElapsedMs === null ? item.elapsedMs : Math.max(longestElapsedMs, item.elapsedMs)
    }
  })

  const totalCount = items.length
  const status: DelegationTreeStatus =
    totalCount === 0
      ? 'empty'
      : failedCount > 0
        ? 'failed'
        : activeCount > 0
          ? 'active'
          : pendingCount > 0
            ? completedCount > 0
              ? 'mixed'
              : 'pending'
            : completedCount === totalCount
              ? 'completed'
              : 'mixed'

  return {
    totalCount,
    leafCount: items.filter((item) => item.leaf).length,
    maxDepth: Math.max(0, ...items.map((item) => item.depth)),
    pendingCount,
    activeCount,
    completedCount,
    failedCount,
    latestStartedAt,
    latestCompletedAt,
    longestElapsedMs,
    status,
  }
}

interface NodeViewProps {
  node: DelegationNode
  depth: number
  path: string
}

function NodeView({ node, depth, path }: NodeViewProps) {
  const presenceStatus = statusToPresence(node.status)
  const elapsed = formatElapsed(node.startedAt, node.completedAt)
  const elapsedValue = elapsedMs(node.startedAt, node.completedAt)
  const childCount = node.children?.length ?? 0
  const indentRem = Math.min(depth * 1.25, 3.75)
  const borderLeft = depth > 0 ? 'border-l-2 border-[var(--color-border-default)] pl-3' : ''

  return html`
    <div
      class="flex min-w-0 flex-col"
      style=${depth > 0 ? { marginLeft: `${indentRem}rem` } : undefined}
      role="treeitem"
      aria-level=${depth + 1}
      aria-expanded=${childCount > 0 ? 'true' : undefined}
      data-delegation-agent-id=${node.agentId}
      data-delegation-task=${node.task}
      data-delegation-status=${node.status}
      data-delegation-depth=${depth}
      data-delegation-path=${path}
      data-delegation-child-count=${childCount}
      data-delegation-leaf=${childCount === 0}
      data-delegation-elapsed-ms=${elapsedValue ?? ''}
    >
      <div class="min-w-0 py-1.5 ${borderLeft}">
        <div class="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] items-start gap-x-2 gap-y-1">
          <${AgentPresence} status=${presenceStatus} size="sm" />
          <div class="min-w-0 sm:grid sm:grid-cols-[minmax(0,1fr)_auto] sm:gap-x-2">
            <span class="block min-w-0 break-words text-sm text-[var(--color-fg-primary)]">${node.task}</span>
            <span class="mt-0.5 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 sm:mt-0 sm:justify-end">
              <span class="shrink-0 font-mono text-xs text-[var(--color-fg-secondary)]">
                ${node.agentId.slice(0, 8)}
              </span>
              ${elapsed
                ? html`<span class="shrink-0 text-xs text-[var(--color-fg-muted)]">(${elapsed})</span>`
                : null}
            </span>
          </div>
        </div>
      </div>
      ${childCount > 0
        ? html`
            <div role="group">
              ${node.children?.map((child, childIndex) => html`
                <${NodeView} node=${child} depth=${depth + 1} path=${`${path}.${childIndex}`} />
              `)}
            </div>
          `
        : null}
    </div>
  `
}

export function AgentDelegation({ root, testId }: AgentDelegationProps) {
  const summary = summarizeDelegationTree(root)

  return html`
    <div
      class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      role="tree"
      data-agent-delegation
      data-agent-delegation-total-count=${summary.totalCount}
      data-agent-delegation-leaf-count=${summary.leafCount}
      data-agent-delegation-max-depth=${summary.maxDepth}
      data-agent-delegation-pending-count=${summary.pendingCount}
      data-agent-delegation-active-count=${summary.activeCount}
      data-agent-delegation-completed-count=${summary.completedCount}
      data-agent-delegation-failed-count=${summary.failedCount}
      data-agent-delegation-latest-started-at=${summary.latestStartedAt ?? ''}
      data-agent-delegation-latest-completed-at=${summary.latestCompletedAt ?? ''}
      data-agent-delegation-longest-elapsed-ms=${summary.longestElapsedMs ?? ''}
      data-agent-delegation-status=${summary.status}
      data-testid=${testId}
    >
      <${NodeView} node=${root} depth=${0} path="0" />
    </div>
  `
}
