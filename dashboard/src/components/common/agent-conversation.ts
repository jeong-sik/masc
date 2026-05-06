// AgentConversation — multi-turn conversation timeline with branch/merge
// Kimi design system sec02 2.2.3: agent message timeline, branch visualisation.
// Zero-dependency fallback (no external graph library).

import { html } from 'htm/preact'

export interface ConversationMessage {
  id: string
  role: 'user' | 'agent' | 'system' | 'tool'
  content: string
  timestamp: number
  parentId?: string
  branchLabel?: string
}

export type AgentConversationStatus = 'empty' | 'linear' | 'branched' | 'orphaned'

export interface AgentConversationSummary {
  messageCount: number
  userCount: number
  agentCount: number
  systemCount: number
  toolCount: number
  branchCount: number
  orphanCount: number
  firstTimestamp: number | null
  latestTimestamp: number | null
  status: AgentConversationStatus
}

interface AgentConversationProps {
  messages: ConversationMessage[]
  onSelectMessage?: (id: string) => void
  testId?: string
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return '--:--'
  return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' })
}

function formatDateTime(ts: number): string | undefined {
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return undefined
  return d.toISOString()
}

export function summarizeAgentConversation(messages: ConversationMessage[]): AgentConversationSummary {
  const ids = new Set(messages.map(msg => msg.id))
  const userCount = messages.filter(msg => msg.role === 'user').length
  const agentCount = messages.filter(msg => msg.role === 'agent').length
  const systemCount = messages.filter(msg => msg.role === 'system').length
  const toolCount = messages.filter(msg => msg.role === 'tool').length
  const branchCount = messages.filter((msg, idx) => {
    const prev = messages[idx - 1]
    return msg.branchLabel !== undefined || (msg.parentId !== undefined && prev?.id !== msg.parentId)
  }).length
  const orphanCount = messages.filter(msg => msg.parentId !== undefined && !ids.has(msg.parentId)).length
  const status: AgentConversationStatus =
    messages.length === 0
      ? 'empty'
      : orphanCount > 0
        ? 'orphaned'
        : branchCount > 0
          ? 'branched'
          : 'linear'

  return {
    messageCount: messages.length,
    userCount,
    agentCount,
    systemCount,
    toolCount,
    branchCount,
    orphanCount,
    firstTimestamp: messages[0]?.timestamp ?? null,
    latestTimestamp: messages[messages.length - 1]?.timestamp ?? null,
    status,
  }
}

function MessageBubble({
  msg,
  onSelect,
  isOrphan,
}: {
  msg: ConversationMessage
  onSelect?: (id: string) => void
  isOrphan?: boolean
}) {
  const isUser = msg.role === 'user'
  const isSystem = msg.role === 'system'
  const isTool = msg.role === 'tool'

  const baseCls =
    'max-w-[80%] rounded-[var(--r-3)] px-3 py-2 text-sm leading-relaxed break-words'
  const roleCls = isSystem
    ? 'mx-auto bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)] text-xs italic'
    : isTool
      ? 'bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)] text-xs border border-[var(--color-border-default)]'
      : isUser
        ? 'ml-auto border border-[var(--accent-30)] bg-[var(--accent-20)] text-[var(--color-accent-fg)]'
        : 'mr-auto bg-[var(--dialog-panel-bg)] text-[var(--color-fg-primary)] border border-[var(--dialog-panel-border)]'

  const alignCls = isUser ? 'items-end' : isSystem ? 'items-center' : 'items-start'

  return html`
    <article
      class="flex flex-col gap-0.5 ${alignCls}"
      aria-label="${msg.role} 메시지"
      data-message-id=${msg.id}
      data-message-role=${msg.role}
      data-message-parent-id=${msg.parentId ?? ''}
      data-message-branch-label=${msg.branchLabel ?? ''}
      data-message-orphan=${isOrphan ? 'true' : 'false'}
      data-message-timestamp=${msg.timestamp}
    >
      ${msg.branchLabel
        ? html`<span class="text-2xs text-[var(--color-accent-fg)] font-mono">${msg.branchLabel}</span>`
        : null}
      <div
        class="${baseCls} ${roleCls}"
        onClick=${() => onSelect?.(msg.id)}
        style=${{ cursor: onSelect ? 'pointer' : 'default' }}
      >
        ${msg.content}
      </div>
      <time class="text-3xs text-[var(--color-fg-muted)]" datetime=${formatDateTime(msg.timestamp)}>
        ${formatTime(msg.timestamp)}
      </time>
    </article>
  `
}

function BranchConnector({ parentId }: { parentId?: string }) {
  if (!parentId) return null
  return html`
    <div class="flex justify-center my-1" aria-hidden="true">
      <div class="w-px h-3 bg-[var(--color-border-default)]"></div>
    </div>
  `
}

export function AgentConversation({
  messages,
  onSelectMessage,
  testId,
}: AgentConversationProps) {
  const summary = summarizeAgentConversation(messages)

  if (messages.length === 0) {
    return html`
      <div
        data-agent-conversation
        data-agent-conversation-message-count=${summary.messageCount}
        data-agent-conversation-user-count=${summary.userCount}
        data-agent-conversation-agent-count=${summary.agentCount}
        data-agent-conversation-system-count=${summary.systemCount}
        data-agent-conversation-tool-count=${summary.toolCount}
        data-agent-conversation-branch-count=${summary.branchCount}
        data-agent-conversation-orphan-count=${summary.orphanCount}
        data-agent-conversation-status=${summary.status}
        data-agent-conversation-first-timestamp=${summary.firstTimestamp ?? ''}
        data-agent-conversation-latest-timestamp=${summary.latestTimestamp ?? ''}
        data-testid=${testId}
        class="space-y-2"
        role="region"
        aria-label="에이전트 대화 기록, 메시지 없음"
      >
        <${ConversationSummaryStrip} summary=${summary} />
        <div class="flex h-32 items-center justify-center text-xs text-[var(--color-fg-muted)]">
          대화 내용이 없습니다.
        </div>
      </div>
    `
  }

  const ids = new Set(messages.map(msg => msg.id))

  return html`
    <div
      data-agent-conversation
      data-agent-conversation-message-count=${summary.messageCount}
      data-agent-conversation-user-count=${summary.userCount}
      data-agent-conversation-agent-count=${summary.agentCount}
      data-agent-conversation-system-count=${summary.systemCount}
      data-agent-conversation-tool-count=${summary.toolCount}
      data-agent-conversation-branch-count=${summary.branchCount}
      data-agent-conversation-orphan-count=${summary.orphanCount}
      data-agent-conversation-status=${summary.status}
      data-agent-conversation-first-timestamp=${summary.firstTimestamp ?? ''}
      data-agent-conversation-latest-timestamp=${summary.latestTimestamp ?? ''}
      data-testid=${testId}
      class="space-y-2 overflow-auto p-3"
    >
      <${ConversationSummaryStrip} summary=${summary} />
      <div
        class="flex flex-col gap-2"
        role="feed"
        aria-label="에이전트 대화 기록, 메시지 ${summary.messageCount}개"
        aria-busy="false"
      >
        ${messages.map((msg, idx) => {
          const prev = messages[idx - 1]
          const showConnector = msg.parentId && prev && prev.id !== msg.parentId
          const isOrphan = msg.parentId !== undefined && !ids.has(msg.parentId)
          return html`
            <div key=${msg.id}>
              ${showConnector ? html`<${BranchConnector} parentId=${msg.parentId} />` : null}
              <${MessageBubble} msg=${msg} onSelect=${onSelectMessage} isOrphan=${isOrphan} />
            </div>
          `
        })}
      </div>
    </div>
  `
}

function ConversationSummaryStrip({ summary }: { summary: AgentConversationSummary }) {
  return html`
    <div
      class="grid grid-cols-3 gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2"
      aria-label="에이전트 대화 요약"
    >
      <div>
        <div class="text-3xs text-[var(--color-fg-secondary)]">메시지</div>
        <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.messageCount}</div>
      </div>
      <div>
        <div class="text-3xs text-[var(--color-fg-secondary)]">분기</div>
        <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.branchCount}</div>
      </div>
      <div>
        <div class="text-3xs text-[var(--color-fg-secondary)]">도구</div>
        <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.toolCount}</div>
      </div>
    </div>
  `
}
