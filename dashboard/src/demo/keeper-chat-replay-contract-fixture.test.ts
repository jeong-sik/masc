import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  ReplayContractFixture,
  clientObservedCount,
  fixtureStatus,
  noDeliveryReceiptCount,
  replayEntries,
  serverReplayOnlyCount,
} from './keeper-chat-replay-contract-fixture'

describe('Keeper Chat replay contract fixture', () => {
  let container: HTMLDivElement | null = null

  afterEach(() => {
    if (container) {
      render(null, container)
      container.remove()
      container = null
    }
  })

  it('keeps replay, queue, and finalization rows deterministic with explicit receipt classes', () => {
    expect(replayEntries).toHaveLength(6)
    expect(clientObservedCount).toBe(1)
    expect(noDeliveryReceiptCount).toBe(4)
    expect(serverReplayOnlyCount).toBe(1)
    expect(fixtureStatus).toBe('ok')

    const legacyEntry = replayEntries.find(entry => entry.id === 'smoke-legacy-user')
    expect(legacyEntry?.streamContract).toMatchObject({
      source: 'keeper_chat_store',
      status: 'history_without_turn_ref',
      deliveryReceipt: 'no_delivery_receipt',
    })

    const serverReplayEntry = replayEntries.find(entry => entry.id === 'smoke-error-assistant')
    expect(serverReplayEntry?.streamContract).toMatchObject({
      source: 'backend_stream_lifecycle',
      status: 'backend_lifecycle_replay',
      eventName: 'RUN_ERROR',
      deliveryReceipt: 'server_lifecycle_replay_only',
    })

    const queuePlaceholder = replayEntries.find(entry => entry.id === 'smoke-queued-assistant')
    expect(queuePlaceholder).toMatchObject({
      delivery: 'queued',
      streamState: 'opening',
    })
    expect(queuePlaceholder?.streamContract).toMatchObject({
      source: 'pending_request_store',
      status: 'client_placeholder',
      requestId: 'req-chat-contract-smoke-1',
      deliveryReceipt: 'no_delivery_receipt',
    })

    const queueResult = replayEntries.find(entry => entry.id === 'smoke-queue-result-assistant')
    expect(queueResult?.streamContract).toMatchObject({
      source: 'queue_poll',
      status: 'queue_poll_result',
      requestId: 'req-chat-contract-smoke-1',
      deliveryReceipt: 'no_delivery_receipt',
    })

    const liveFinal = replayEntries.find(entry => entry.id === 'smoke-live-final-assistant')
    expect(liveFinal?.streamContract).toMatchObject({
      source: 'sse_event',
      status: 'backend_terminal_event',
      eventName: 'RUN_FINISHED',
      deliveryReceipt: 'client_observed_sse_event',
    })
  })

  it('renders replay contract badge state into durable DOM attributes', () => {
    container = document.createElement('div')
    document.body.append(container)

    render(html`<${ReplayContractFixture} />`, container)

    expect(
      container.querySelector(
        '[data-replay-contract-fixture-status="ok"][data-replay-contract-fixture-row-count="6"][data-replay-contract-fixture-client-observed-count="1"][data-replay-contract-fixture-no-delivery-count="4"][data-replay-contract-fixture-server-replay-count="1"]',
      ),
    ).not.toBeNull()

    expect(
      container.querySelector(
        '[data-chat-entry-id="smoke-legacy-user"][data-chat-stream-contract-badge-state="no-turn-ref"][data-chat-stream-contract-status="history_without_turn_ref"][data-chat-stream-contract-delivery-receipt="no_delivery_receipt"] [data-chat-stream-contract-badge="no-turn-ref"]',
      ),
    ).not.toBeNull()

    expect(
      container.querySelector(
        '[data-chat-entry-id="smoke-error-assistant"][data-chat-stream-contract-badge-state="server-replay"][data-chat-stream-contract-event="RUN_ERROR"][data-chat-stream-contract-delivery-receipt="server_lifecycle_replay_only"] [data-chat-stream-contract-badge="server-replay"]',
      ),
    ).not.toBeNull()

    expect(
      container.querySelector(
        '[data-chat-entry-id="smoke-queued-assistant"][data-chat-delivery-state="queued"][data-chat-stream-state="opening"][data-chat-stream-contract-source="pending_request_store"][data-chat-stream-contract-status="client_placeholder"][data-chat-stream-contract-request-id="req-chat-contract-smoke-1"][data-chat-stream-contract-delivery-receipt="no_delivery_receipt"]',
      ),
    ).not.toBeNull()

    expect(
      container.querySelector(
        '[data-chat-entry-id="smoke-queue-result-assistant"][data-chat-delivery-state="delivered"][data-chat-stream-contract-source="queue_poll"][data-chat-stream-contract-status="queue_poll_result"][data-chat-stream-contract-request-id="req-chat-contract-smoke-1"][data-chat-stream-contract-delivery-receipt="no_delivery_receipt"]',
      ),
    ).not.toBeNull()

    expect(
      container.querySelector(
        '[data-chat-entry-id="smoke-live-final-assistant"][data-chat-delivery-state="delivered"][data-chat-stream-contract-source="sse_event"][data-chat-stream-contract-status="backend_terminal_event"][data-chat-stream-contract-event="RUN_FINISHED"][data-chat-stream-contract-delivery-receipt="client_observed_sse_event"]',
      ),
    ).not.toBeNull()
  })
})
