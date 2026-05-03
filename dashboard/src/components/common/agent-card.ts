// AgentCard — composite AX card that assembles Presence + Capability + Trust +
// Failure + Human-in-the-loop into a single scannable unit.
//
// Kimi design system sec05 5.4: "에이전트의 삶을 조망하는 도구"의 핵심 단위.
// Each section is conditional so the card density adapts to the agent's state.

import { html } from 'htm/preact'
import { AgentPresence } from './agent-presence'
import { AgentCapability } from './agent-capability'
import { AgentTrust, type TrustMetrics } from './agent-trust'
import { AgentFailure, type FailureType } from './agent-failure'
import { HumanInTheLoop, type ApprovalRequest } from './human-in-the-loop'

export interface AgentFailureState {
  type: FailureType
  message: string
  retryCount?: number
  maxRetries?: number
}

export interface AgentCardAgent {
  id: string
  name: string
  status: string | null | undefined
  currentTask?: string | null
  capabilities: Array<string | null | undefined> | null | undefined
  trustMetrics: TrustMetrics
  failure?: AgentFailureState | null
}

interface AgentCardProps {
  agent: AgentCardAgent
  approvals?: ApprovalRequest[]
  onApprove?: (id: string) => void
  onReject?: (id: string) => void
  onModify?: (id: string, action: string) => void
  testId?: string
}

export function AgentCard({
  agent,
  approvals = [],
  onApprove,
  onReject,
  onModify,
  testId,
}: AgentCardProps) {
  const initial = agent.name.charAt(0).toUpperCase()
  const hasFailure = agent.failure != null
  const hasApprovals = approvals.length > 0

  return html`
    <article
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4"
      data-agent-card
      data-testid=${testId}
    >
      <!-- Header: avatar + name + presence + trust -->
      <div class="mb-3 flex items-start justify-between gap-3">
        <div class="flex items-center gap-3 min-w-0">
          <div
            class="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-[var(--color-accent)] text-sm font-bold text-white"
            aria-hidden="true"
          >
            ${initial}
          </div>
          <div class="min-w-0">
            <div class="truncate text-sm font-medium text-[var(--color-fg-primary)]">
              ${agent.name}
            </div>
            <${AgentPresence}
              status=${agent.status}
              detail=${agent.currentTask}
              size="sm"
            />
          </div>
        </div>
        <div class="shrink-0">
          <${AgentTrust} metrics=${agent.trustMetrics} />
        </div>
      </div>

      <!-- Capability row -->
      <div class="mb-3">
        <${AgentCapability} tools=${agent.capabilities} maxVisible=${6} />
      </div>

      <!-- Failure alert (conditional) -->
      ${hasFailure
        ? html`
            <div class="mb-3">
              <${AgentFailure}
                type=${agent.failure!.type}
                message=${agent.failure!.message}
                retryCount=${agent.failure!.retryCount}
                maxRetries=${agent.failure!.maxRetries}
              />
            </div>
          `
        : null}

      <!-- Pending approvals (conditional) -->
      ${hasApprovals
        ? html`
            <div class="space-y-2">
              <div
                class="text-xs font-medium uppercase tracking-wider text-[var(--color-fg-secondary)]"
              >
                승인 대기 (${approvals.length})
              </div>
              ${approvals.map(
                (req) => html`
                  <${HumanInTheLoop}
                    key=${req.id}
                    request=${req}
                    onApprove=${onApprove ?? (() => {})}
                    onReject=${onReject ?? (() => {})}
                    onModify=${onModify ?? (() => {})}
                  />
                `,
              )}
            </div>
          `
        : null}
    </article>
  `
}
