import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  INTERLEAVE_FIXTURE_COVERED_THROUGH_MS,
  INTERLEAVE_ORDER_SIGNATURE,
  InterleaveContractFixture,
  installInterleaveFixtureToolOutputs,
  interleaveEntries,
  interleaveFixtureStatus,
  joinedToolCount,
  traceOnlyToolCount,
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
  })

  it('keeps deterministic fixture rows for joined and trace-only tool states', () => {
    expect(interleaveEntries).toHaveLength(2)
    expect(joinedToolCount).toBe(1)
    expect(traceOnlyToolCount).toBe(1)
    expect(interleaveFixtureStatus).toBe('ok')

    const assistant = interleaveEntries.find(entry => entry.id === 'assistant-interleave')
    expect(assistant?.traceSteps?.map(step => step.kind)).toEqual(['think', 'tool', 'think', 'tool'])
    expect(assistant?.traceSteps?.map(step => step.ts)).toEqual([
      '2026-07-05T14:20:05.000Z',
      '2026-07-05T14:20:01.000Z',
      '2026-07-05T14:20:02.000Z',
      '2026-07-05T14:20:03.000Z',
    ])
  })

  it('renders structural order and tool-output join state into durable DOM attributes', () => {
    container = document.createElement('div')
    document.body.append(container)
    installInterleaveFixtureToolOutputs()

    render(html`<${InterleaveContractFixture} />`, container)

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
