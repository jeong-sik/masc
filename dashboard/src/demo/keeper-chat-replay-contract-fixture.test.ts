import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  ReplayContractFixture,
  clientObservedCount,
  fixtureStatus,
  replayEntries,
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

  it('keeps the replay rows deterministic without client-observed stream receipts', () => {
    expect(replayEntries).toHaveLength(3)
    expect(clientObservedCount).toBe(0)
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
  })

  it('renders replay contract badge state into durable DOM attributes', () => {
    container = document.createElement('div')
    document.body.append(container)

    render(html`<${ReplayContractFixture} />`, container)

    expect(
      container.querySelector(
        '[data-replay-contract-fixture-status="ok"][data-replay-contract-fixture-row-count="3"][data-replay-contract-fixture-client-observed-count="0"]',
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
  })
})
