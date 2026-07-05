import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { ChatTranscript } from '../components/chat/primitives'
import { chatHistoryEntriesFromRest } from '../keeper-state'

export const replayEntries = chatHistoryEntriesFromRest('sangsu', [
  {
    id: 'smoke-user',
    role: 'user',
    content: 'please run the long check',
    ts: 1_780_000_000,
    turn_ref: 'trace-chat-contract-smoke#7',
    stream_contract: {
      source: 'keeper_chat_store',
      status: 'history_without_stream_events',
      turn_ref: 'trace-chat-contract-smoke#7',
      delivery_receipt: 'no_delivery_receipt',
      reason: 'user history rows are persisted chat input, not a live client stream receipt',
    },
  },
  {
    id: 'smoke-legacy-user',
    role: 'user',
    content: 'legacy row without turn ref',
    ts: 1_780_000_001,
    stream_contract: {
      source: 'keeper_chat_store',
      status: 'history_without_turn_ref',
      delivery_receipt: 'no_delivery_receipt',
      reason: 'history row has no durable turn_ref; cannot join stream events',
    },
  },
  {
    id: 'smoke-error-assistant',
    role: 'assistant',
    content: 'Keeper request failed: Timeout after 630.0s',
    ts: 1_780_000_002,
    kind: 'transport_failure',
    turn_ref: 'trace-chat-contract-smoke#8',
    stream_contract: {
      source: 'backend_stream_lifecycle',
      status: 'backend_lifecycle_replay',
      turn_ref: 'trace-chat-contract-smoke#8',
      event_name: 'RUN_ERROR',
      lifecycle_events: [
        'RUN_STARTED',
        'RUN_ERROR',
      ],
      delivery_receipt: 'server_lifecycle_replay_only',
      reason: 'history row records durable server stream lifecycle replay',
    },
  },
])

export const clientObservedCount = replayEntries.filter(
  entry => entry.streamContract?.deliveryReceipt === 'client_observed_sse_event',
).length
export const fixtureStatus = replayEntries.length === 3 && clientObservedCount === 0 ? 'ok' : 'invalid'

export function ReplayContractFixture() {
  return html`
    <main
      class="min-h-screen px-4 py-8"
      style="background: var(--bg-deep);"
      data-keeper-chat-layout="workspace"
      data-replay-contract-fixture
      data-replay-contract-fixture-status=${fixtureStatus}
      data-replay-contract-fixture-row-count=${replayEntries.length}
      data-replay-contract-fixture-client-observed-count=${clientObservedCount}
    >
      <section class="mx-auto max-w-[760px]">
        <header class="mb-5">
          <p class="font-mono text-2xs uppercase tracking-[0.2em]" style="color: var(--text-dim);">
            Keeper Chat Replay Contract Fixture
          </p>
          <h1 class="mt-2 text-xl font-semibold" style="color: var(--text-main);">
            Rendered replay contracts
          </h1>
        </header>
        <div
          class="kw-chat rounded-[var(--r-2)] border p-4"
          style="background: var(--bg-panel); border-color: var(--border-main);"
        >
          <${ChatTranscript}
            entries=${replayEntries}
            emptyText="No replay rows"
            variant="messenger"
            size="primary"
            showMetadata=${false}
          />
        </div>
      </section>
    </main>
  `
}

const root = document.getElementById('app')
if (root) {
  render(html`<${ReplayContractFixture} />`, root)
}
