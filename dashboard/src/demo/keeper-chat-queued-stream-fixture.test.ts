import { afterEach, describe, expect, it, vi } from 'vitest'

import { listQueuedKeeperChatOperations, streamKeeperMessage } from '../api/keeper'
import type { KeeperChatStreamEvent } from '../lib/keeper-chat-stream-contract'
import {
  finishRunning,
  fixtureFetch,
  startHead,
} from './keeper-chat-queued-stream-fixture'

// The queued-stream e2e runs only by hand, so nothing else notices when the
// fixture drifts from what the dashboard reads: the dashboard rejected every
// frame and the e2e waited for replies that had ended as errors (#51569).
// These read the fixture with the dashboard's own readers.
describe('Keeper queued stream fixture', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  // One operation's whole stream passes every place the fixture writes a frame.
  it('emits only frames the dashboard stream reader accepts', async () => {
    const requests: string[] = []
    vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(`${init?.method ?? 'GET'} ${String(input)}`)
      const response = await fixtureFetch(input, init)
      // What the e2e does with the fixture buttons once the submit is queued:
      // run the FIFO head, then let it finish.
      startHead()
      finishRunning()
      return response
    })
    const events: KeeperChatStreamEvent[] = []
    const rejected: string[] = []

    const outcome = await streamKeeperMessage('sangsu', '첫 번째 요청', {
      operationId: 'queued-stream-fixture-op',
      onEvent: event => { events.push(event) },
      onDecodeError: reason => { rejected.push(reason) },
    })

    expect(requests).toEqual(['POST /api/v1/keepers/chat/stream'])
    expect(rejected).toEqual([])
    expect(outcome).toEqual({ terminal: true })
    expect(events[0]).toMatchObject({
      type: 'CUSTOM',
      name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
      value: { operation_id: 'queued-stream-fixture-op', state: 'Queued' },
    })
    expect(events.at(-1)?.type).toBe('RUN_FINISHED')
  })

  it('lists its queued operations to the dashboard queue reader', async () => {
    vi.stubGlobal('fetch', fixtureFetch)
    for (const [operationId, message] of [['queue-a', '두 번째 요청'], ['queue-b', '세 번째 요청']]) {
      const response = await fixtureFetch('/api/v1/keepers/chat/stream', {
        method: 'POST',
        body: JSON.stringify({ request_id: operationId, name: 'sangsu', message }),
      })
      await response.body?.cancel()
    }

    // The queue control panel reads pages until one is empty (#45908).
    const queued = await listQueuedKeeperChatOperations('sangsu')

    expect(queued.map(operation => [operation.operationId, operation.input?.message]))
      .toEqual([['queue-a', '두 번째 요청'], ['queue-b', '세 번째 요청']])
  })
})
