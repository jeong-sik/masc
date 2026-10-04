import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

// #35924: a joined trace step reads ok only after the exact per-execution
// endpoint verifies the output; the recorded bulk outputs alone do not. This
// registry stands in for that endpoint, keyed `${keeper}:${execution_id}`.
const { exactToolCallLookup } = vi.hoisted(() => ({
  exactToolCallLookup: new Map<string, { keeper: string; execution_id: string; entry: unknown }>(),
}))

vi.mock('../api/core', async importOriginal => ({
  ...await importOriginal<typeof import('../api/core')>(),
  get: vi.fn(async (path: string) => {
    const [, keeper, executionId] = /^\/api\/v1\/keepers\/([^/]+)\/tool-calls\?execution_id=([^&]+)$/.exec(path) ?? []
    const response = keeper !== undefined && executionId !== undefined
      ? exactToolCallLookup.get(`${decodeURIComponent(keeper)}:${decodeURIComponent(executionId)}`)
      : undefined
    if (response) return response
    throw new Error('Historical output not provided by this fixture')
  }),
}))

import {
  INTERLEAVE_FIXTURE_COVERED_THROUGH_MS,
  INTERLEAVE_ORDER_SIGNATURE,
  InterleaveContractFixture,
  installInterleaveFixtureToolOutputs,
  joinedToolOutput,
} from './keeper-chat-interleave-contract-fixture'
import { resetToolCallOutputs } from '../tool-call-output-store'

describe('Keeper Chat interleave contract fixture', () => {
  let container: HTMLDivElement | null = null

  afterEach(() => {
    if (container) {
      render(null, container)
      container.remove()
      container = null
    }
    resetToolCallOutputs()
    exactToolCallLookup.clear()
  })

  it('renders structural order and tool-output join state into durable DOM attributes', async () => {
    container = document.createElement('div')
    document.body.append(container)
    // happy-dom defines IntersectionObserver but never reports an
    // intersection, so the row's lazy lookup would never run. A browser
    // observes the row once it is on screen; the fixture says so directly.
    vi.stubGlobal('IntersectionObserver', class {
      private readonly callback: IntersectionObserverCallback

      constructor(callback: IntersectionObserverCallback) {
        this.callback = callback
      }

      observe(target: Element) {
        this.callback([{
          target,
          isIntersecting: true,
          intersectionRatio: 1,
        } as IntersectionObserverEntry], this as unknown as IntersectionObserver)
      }

      disconnect() {}
    })
    installInterleaveFixtureToolOutputs()
    const joinedExecutionId = joinedToolOutput.execution_id ?? ''
    exactToolCallLookup.set(`${joinedToolOutput.keeper}:${joinedExecutionId}`, {
      keeper: joinedToolOutput.keeper,
      execution_id: joinedExecutionId,
      entry: joinedToolOutput,
    })

    render(html`<${InterleaveContractFixture} />`, container)

    // The joined row reads its output through the exact per-execution
    // endpoint, so the verified state lands a tick after the first paint.
    await waitFor(() => {
      expect(
        document.querySelector('[data-chat-trace-tool-call-id="tc-context"][data-chat-trace-output-state="ok"]'),
      ).not.toBeNull()
    })

    expect(
      container.querySelector(
        `[data-interleave-contract-fixture-status="ok"][data-interleave-order-signature="${INTERLEAVE_ORDER_SIGNATURE}"][data-interleave-joined-tool-count="1"][data-interleave-trace-only-tool-count="1"]`,
      ),
    ).not.toBeNull()

    const trace = container.querySelector('[data-chat-work-trace]') as HTMLElement | null
    expect(trace).not.toBeNull()
    expect(trace?.getAttribute('data-chat-turn-order-signature')).toBe(INTERLEAVE_ORDER_SIGNATURE)
    expect(trace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('hydrated')
    expect(trace?.getAttribute('data-chat-tool-output-covered-through')).toBe(String(INTERLEAVE_FIXTURE_COVERED_THROUGH_MS))

    const ordered = [...container.querySelectorAll('[data-chat-turn-order-index]')] as HTMLElement[]
    expect(ordered.map(node => node.getAttribute('data-chat-turn-order-index'))).toEqual(['0', '1', '2', '3', '4'])
    expect(ordered.map(node => node.getAttribute('data-chat-turn-order-kind'))).toEqual([
      'trace',
      'tool',
      'trace',
      'tool',
      'chat',
    ])

    expect(ordered[0]?.getAttribute('data-chat-trace-ts')).toBe('2026-07-05T14:20:05.000Z')
    expect(ordered[1]?.getAttribute('data-chat-trace-tool-call-id')).toBe('tc-context')
    expect(ordered[1]?.getAttribute('data-chat-trace-entry-id')).toBe('tool-tc-context')
    expect(ordered[1]?.getAttribute('data-chat-trace-link-state')).toBe('joined')
    expect(ordered[1]?.getAttribute('data-chat-trace-output-state')).toBe('ok')
    expect(ordered[1]?.getAttribute('data-chat-trace-output-coverage')).toBe('covered')
    expect(ordered[2]?.getAttribute('data-chat-trace-ts')).toBe('2026-07-05T14:20:02.000Z')
    expect(ordered[3]?.getAttribute('data-chat-trace-tool-call-id')).toBe('tc-missing')
    expect(ordered[3]?.getAttribute('data-chat-trace-entry-id')).toBeNull()
    expect(ordered[3]?.getAttribute('data-chat-trace-link-state')).toBe('trace-only')
    expect(ordered[3]?.getAttribute('data-chat-trace-output-state')).toBe('pending')
    expect(ordered[4]?.getAttribute('data-chat-trace-entry-id')).toBe('assistant-interleave')

    const joinedToolRow = ordered[1]
    expect(joinedToolRow).toBeDefined()
    if (!joinedToolRow) {
      throw new Error('expected joined tool row at structural order index 1')
    }

    expect(container.textContent).not.toContain('context status joined from tool_calls_endpoint')
    fireEvent.click(joinedToolRow.querySelector('.chat-block-tstep-row') as HTMLElement)
    expect(container.textContent).toContain('context status joined from tool_calls_endpoint')
    expect(container.textContent).not.toContain('unrelated output')
  })
})
