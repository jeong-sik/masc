import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { render } from 'preact'
import { useState } from 'preact/hooks'
import { html } from 'htm/preact'
import { ChatTranscript } from '../components/chat/primitives'
import { appendThreadEntry, keeperThreads } from '../keeper-state'
import { applyKeeperQueuedTurnEvent } from '../keeper-stream'

const KEEPER = 'sangsu'
const receipts = [
  'chatq_00000000-0000-4000-8000-000000000001',
  'chatq_00000000-0000-4000-8000-000000000002',
]
let submitted = 0

keeperThreads.value = { [KEEPER]: [] }

function submitMessage(message: string): void {
  const receiptId = receipts[submitted]
  if (!receiptId) return
  const index = submitted++
  appendThreadEntry(KEEPER, {
    id: `fixture-user-${index}`,
    role: 'user',
    source: 'direct_user',
    label: 'operator',
    text: message,
    rawText: message,
    timestamp: new Date().toISOString(),
    delivery: 'delivered',
    streamState: null,
    details: null,
  })
  appendThreadEntry(KEEPER, {
    id: `fixture-assistant-${index}`,
    role: 'assistant',
    source: 'direct_assistant',
    label: KEEPER,
    text: `${KEEPER}가 다른 작업을 처리 중이에요. 메시지는 대기열에 추가했습니다.`,
    rawText: null,
    timestamp: null,
    delivery: 'queued',
    streamState: null,
    queueReceiptIds: [receiptId],
    details: { queueReceiptId: receiptId, queueState: 'pending' },
  })
}

function startFirstTurn(): void {
  const receiptId = receipts[0]!
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: { type: 'RUN_STARTED', runId: 'fixture-run-1' },
  })
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: {
      type: 'CUSTOM',
      name: 'KEEPER_THINKING_DELTA',
      value: { index: 0, delta: '요청 내용을 검토하고 있습니다.' },
    },
  })
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: {
      type: 'TOOL_CALL_START',
      toolCallId: 'fixture-tool-1',
      toolCallName: 'keeper_context_status',
    },
  })
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: {
      type: 'TOOL_CALL_ARGS',
      toolCallId: 'fixture-tool-1',
      delta: '{"scope":"current"}',
    },
  })
}

function finishFirstTurn(): void {
  const receiptId = receipts[0]!
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: { type: 'TOOL_CALL_END', toolCallId: 'fixture-tool-1' },
  })
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: { type: 'TEXT_MESSAGE_START', messageId: 'fixture-message-1' },
  })
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: {
      type: 'TEXT_MESSAGE_CONTENT',
      messageId: 'fixture-message-1',
      delta: '대기 요청도 이제 같은 말풍선에서 실시간으로 답변합니다.',
    },
  })
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: { type: 'TEXT_MESSAGE_END', messageId: 'fixture-message-1' },
  })
  applyKeeperQueuedTurnEvent(KEEPER, {
    receiptId,
    event: {
      type: 'CUSTOM',
      name: 'KEEPER_REQUEST_TERMINAL',
      value: { request_id: 'kmsg-fixture-1', status: 'done', ok: true },
    },
  })
}

function QueuedStreamFixture() {
  const [message, setMessage] = useState('')
  const entries = keeperThreads.value[KEEPER] ?? []
  return html`
    <main class="min-h-screen px-4 py-8" style="background: var(--bg-deep);" data-queued-stream-fixture>
      <section class="mx-auto max-w-[820px]">
        <h1 class="mb-4 text-xl font-semibold" style="color: var(--text-main);">
          Keeper queued stream contract
        </h1>
        <div class="kw-chat rounded-[var(--r-2)] border p-4" style="background: var(--bg-panel); border-color: var(--border-main);">
          <${ChatTranscript}
            entries=${entries}
            emptyText="메시지를 입력하세요"
            variant="messenger"
            size="primary"
            showMetadata=${false}
            groupToolCalls=${true}
          />
          <form
            class="mt-4 flex gap-2"
            onSubmit=${(event: Event) => {
              event.preventDefault()
              const next = message.trim()
              if (!next) return
              submitMessage(next)
              setMessage('')
            }}
          >
            <input
              data-testid="queued-stream-composer"
              class="min-w-0 flex-1 rounded border px-3 py-2"
              value=${message}
              onInput=${(event: Event) => setMessage((event.currentTarget as HTMLInputElement).value)}
              aria-label="Keeper message"
            />
            <button data-testid="queued-stream-submit" type="submit">보내기</button>
          </form>
          <div class="mt-3 flex gap-2">
            <button data-testid="queued-stream-start" type="button" onClick=${startFirstTurn}>
              첫 요청 실행
            </button>
            <button data-testid="queued-stream-finish" type="button" onClick=${finishFirstTurn}>
              첫 요청 완료
            </button>
          </div>
        </div>
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) render(html`<${QueuedStreamFixture} />`, root)
