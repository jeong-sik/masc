import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'
import { useState } from 'preact/hooks'
import { ringFocusClasses } from '../common/ring'

const CHAT_FOCUS_RING = ringFocusClasses({ tone: 'accent-medium', width: 2 })

function renderStructuredFailureText(text: string): Array<string | VNode> {
  return text.split(/(\s+)/).map((part, index) => {
    if (!part || /^\s+$/.test(part)) return part
    return html`<span class="chat-error-token" key=${index}>${part}</span>`
  })
}

/** Typed failure card for kind=transport_failure rows.
 *
 * The discriminator is the writer-declared row kind (normalized to the closed
 * delivery='transport_failure' variant), never a string match on the content.
 * The raw error text is diagnostic payload, shown collapsed. The reassurance line states
 * what the backend guarantees: a Transport_failure row is watermark-neutral
 * (keeper_chat_store), so the user message it failed to answer stays pending
 * for the keeper's next turn. */
export function ChatFailureCard({ diagnostic, children, onCopy }: {
  diagnostic: string
  children?: ComponentChildren
  onCopy: () => Promise<void>
}) {
  const [detailOpen, setDetailOpen] = useState(false)
  return html`
    <div
      class="flex flex-col gap-2 rounded-[var(--r-1)] border border-[var(--color-status-error)]/40 bg-[var(--color-bg-surface)] p-3"
      data-chat-structured-error
      data-chat-failure-card
    >
      <div class="flex flex-wrap items-center gap-2">
        <span
          class="inline-flex items-center rounded-[var(--r-0)] bg-[var(--color-status-error)]/15 px-2 py-0.5 text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-status-error)]"
        >
          응답 실패
        </span>
        <span class="text-sm font-semibold text-[var(--color-fg-primary)]">
          이 턴은 응답을 마무리하지 못했습니다
        </span>
      </div>
      <p class="m-0 text-sm leading-airy text-[var(--color-fg-secondary)]" data-chat-failure-reassurance>
        보낸 메시지는 사라지지 않았습니다. 이 실패 기록은 처리 완료로 간주되지 않으며, keeper가 이후 정상 응답하기 전까지 다시 처리 대상에 남습니다.
      </p>
      ${children}
      <div class="flex items-center gap-2">
        <button
          type="button"
          class="self-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1 text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING}"
          aria-expanded=${detailOpen}
          data-chat-failure-detail-toggle
          onClick=${() => { setDetailOpen(open => !open) }}
        >
          ${detailOpen ? '상세 접기' : '오류 상세 보기'}
        </button>
        <button
          type="button"
          class="self-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1 text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING}"
          data-chat-failure-copy
          onClick=${() => { void onCopy() }}
        >
          오류 복사
        </button>
      </div>
      ${detailOpen
        ? html`
            <pre class="chat-error-text" data-chat-failure-detail>${renderStructuredFailureText(diagnostic)}</pre>
          `
        : null}
    </div>
  `
}

