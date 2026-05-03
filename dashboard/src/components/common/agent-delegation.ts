// AgentDelegation — AX organism that renders an agent delegation tree.
//
// Kimi design system sec05 reference: recursive tree of sub-task delegation
// with AgentPresence integration. Each node shows task, agent id and
// elapsed time.

import { html } from 'htm/preact'
import { AgentPresence } from './agent-presence'

export interface DelegationNode {
  agentId: string
  task: string
  status: 'pending' | 'active' | 'completed' | 'failed'
  children?: DelegationNode[]
  startedAt?: number
  completedAt?: number
}

interface AgentDelegationProps {
  root: DelegationNode
  testId?: string
}

function statusToPresence(status: DelegationNode['status']): string {
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

function formatElapsed(startedAt?: number, completedAt?: number): string | null {
  if (startedAt == null || completedAt == null) return null
  const ms = completedAt - startedAt
  if (ms < 0) return null
  return `${(ms / 1000).toFixed(1)}s`
}

interface NodeViewProps {
  node: DelegationNode
  depth: number
}

function NodeView({ node, depth }: NodeViewProps) {
  const presenceStatus = statusToPresence(node.status)
  const elapsed = formatElapsed(node.startedAt, node.completedAt)
  const marginLeft = depth > 0 ? 'ml-6' : ''
  const borderLeft = depth > 0 ? 'border-l-2 border-[var(--color-border-default)] pl-3' : ''

  return html`
    <div class="flex flex-col ${marginLeft}" role="treeitem" aria-expanded=${node.children && node.children.length > 0 ? 'true' : undefined}>
      <div class="flex items-center gap-2 py-1.5 ${borderLeft}">
        <${AgentPresence} status=${presenceStatus} size="sm" />
        <span class="text-sm text-[var(--color-fg-primary)]">${node.task}</span>
        <span class="font-mono text-xs text-[var(--color-fg-secondary)]">
          ${node.agentId.slice(0, 8)}
        </span>
        ${elapsed
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">(${elapsed})</span>`
          : null}
      </div>
      ${node.children && node.children.length > 0
        ? html`
            <div role="group">
              ${node.children.map((child) => html`<${NodeView} node=${child} depth=${depth + 1} />`)}
            </div>
          `
        : null}
    </div>
  `
}

export function AgentDelegation({ root, testId }: AgentDelegationProps) {
  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      role="tree"
      data-agent-delegation
      data-testid=${testId}
    >
      <${NodeView} node=${root} depth=${0} />
    </div>
  `
}
