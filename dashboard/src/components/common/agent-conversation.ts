// AgentConversation — multi-turn conversation timeline with branch/merge
// Kimi design system sec02 2.2.3: agent message timeline, branch visualisation.
// Zero-dependency fallback (no external graph library).

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export interface ConversationMessage {
  id: string
  role: 'user' | 'agent' | 'system' | 'tool'
  content: string
  timestamp: number
  parentId?: string
  branchLabel?: string
}

interface AgentConversationProps {
  messages: ConversationMessage[]
  onSelectMessage?: (id: string) => void
  testId?: string
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' })
}

function MessageBubble({
  msg,
  onSelect,
}: {
  msg: ConversationMessage
  onSelect?: (id: string) => void
}) {
  const isUser = msg.role === 'user'
  const isSystem = msg.role === 'system'
  const isTool = msg.role === 'tool'

  const baseCls =
    'max-w-[80%] rounded-lg px-3 py-2 text-sm leading-relaxed break-words'
  const roleCls = isSystem
    ? 'mx-auto bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)] text-xs italic'
    : isTool
      ? 'bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)] text-xs border border-[var(--color-border-default)]'
      : isUser
        ? 'ml-auto bg-[var(--color-accent)] text-[var(--color-fg-primary)]'
        : 'mr-auto bg-[var(--dialog-panel-bg)] text-[var(--color-fg-primary)] border border-[var(--dialog-panel-border)]'

  const alignCls = isUser ? 'items-end' : isSystem ? 'items-center' : 'items-start'

  return html`
    <article
      class="flex flex-col gap-0.5 ${alignCls}"
      aria-label="${msg.role} 메시지"
      data-message-id=${msg.id}
    >
      ${msg.branchLabel
        ? html`<span class="text-2xs text-[var(--color-accent)] font-mono">${msg.branchLabel}</span>`
        : null}
      <div
        class="${baseCls} ${roleCls}"
        onClick=${() => onSelect?.(msg.id)}
        style=${{ cursor: onSelect ? 'pointer' : 'default' }}
      >
        ${msg.content}
      </div>
      <time class="text-3xs text-[var(--color-fg-muted)]" datetime=${new Date(msg.timestamp).toISOString()}>
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
  if (messages.length === 0) {
    return html`
      <div
        data-testid=${testId}
        class="flex h-32 items-center justify-center text-xs text-[var(--color-fg-muted)]"
        role="region"
        aria-label="에이전트 대화 기록"
      >
        대화 내용이 없습니다.
      </div>
    `
  }

  return html`
    <div
      data-testid=${testId}
      class="flex flex-col gap-2 overflow-auto p-3"
      role="feed"
      aria-label="에이전트 대화 기록"
      aria-busy="false"
    >
      ${messages.map((msg, idx) => {
        const prev = messages[idx - 1]
        const showConnector = msg.parentId && prev && prev.id !== msg.parentId
        return html`
          <div key=${msg.id}>
            ${showConnector ? html`<${BranchConnector} parentId=${msg.parentId} />` : null}
            <${MessageBubble} msg=${msg} onSelect=${onSelectMessage} />
          </div>
        `
      })}
    </div>
  `
}
