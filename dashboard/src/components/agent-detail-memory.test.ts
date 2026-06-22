// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

import type { MemorySubsystemsResponse } from '../api/dashboard'

// ── Mock API ──────────────────────────────────────────
// AgentDetailMemory fetches via fetchMemorySubsystems() inside useEffect.
// Mocking the module returns a valid empty payload so the component reaches
// its loaded state without a real HTTP call; the memory-inspector wiring is
// independent of the fetched subsystems data.
const mockFetch = vi.fn<() => Promise<MemorySubsystemsResponse>>()

vi.mock('../api/dashboard', () => ({
  fetchMemorySubsystems: () => mockFetch(),
}))

// ── Import after mocks ────────────────────────────────
import { AgentDetailMemory } from './agent-detail-memory'

function emptyResponse(): MemorySubsystemsResponse {
  return {
    generated_at: '2026-06-22T00:00:00Z',
    hebbian: { synapses: [], last_consolidation: 0 },
    episodes: { total: 0, filtered: 0, shown: 0, limit: 10, items: [] },
    filters: { keepers: [], outcomes: [] },
  }
}

afterEach(() => {
  cleanup()
  mockFetch.mockReset()
})

// The memory surface lives inside a CollapsibleSection that defers mounting
// its children until opened (mountWhenOpen). Open the <details> the way the
// operator would so the trigger renders.
async function openTrigger(container: Element): Promise<HTMLButtonElement> {
  // Wait for the async resource to load (replaces the LoadingState with the
  // CollapsibleSection), then expand the <details> the way an operator would.
  const details = await waitFor(() => {
    const d = container.querySelector('details')
    expect(d).toBeTruthy()
    return d as HTMLDetailsElement
  })
  details.open = true
  fireEvent(details, new Event('toggle'))
  return await waitFor(() => {
    const btn = container.querySelector('.cmp-open')
    expect(btn).toBeTruthy()
    return btn as HTMLButtonElement
  })
}

describe('AgentDetailMemory — MemoryInspector wiring', () => {
  it('renders the 메모리 보기 trigger after load and opens the inspector overlay on click', async () => {
    mockFetch.mockResolvedValue(emptyResponse())
    const { container } = render(
      html`<${AgentDetailMemory} agentName="masc-improver" />`,
    )

    // Trigger appears once the async resource has loaded and the section opens.
    const trigger = await openTrigger(container)
    expect(trigger.textContent).toContain('메모리 보기')

    // Inspector is not mounted until the trigger is clicked.
    expect(container.querySelector('.turn-overlay')).toBeFalsy()

    fireEvent.click(trigger)

    // The MemoryInspector overlay-drawer now renders, scoped to the agent.
    const drawer = container.querySelector('.mem-drawer')
    expect(drawer).toBeTruthy()
    expect(container.querySelector('.turn-overlay')).toBeTruthy()
    expect(container.querySelector('.turn-hd h3')?.textContent).toContain(
      'Keeper 메모리',
    )
    // agentName 'masc-improver' resolves to the ported roster keeper.
    expect(container.querySelector('.tid')?.textContent).toBe('masc-improver')
  })

  it('resolves the keeper id from a keeper-prefixed agent name', async () => {
    mockFetch.mockResolvedValue(emptyResponse())
    const { container } = render(
      html`<${AgentDetailMemory} agentName="keeper-sangsu-agent" />`,
    )
    const trigger = await openTrigger(container)
    fireEvent.click(trigger)
    // normalizeKeeperName strips keeper-/-agent → 'sangsu' (a roster keeper).
    expect(container.querySelector('.tid')?.textContent).toBe('sangsu')
  })

  it('closes the inspector when onClose fires (✕ button)', async () => {
    mockFetch.mockResolvedValue(emptyResponse())
    const { container } = render(
      html`<${AgentDetailMemory} agentName="masc-improver" />`,
    )
    const trigger = await openTrigger(container)
    fireEvent.click(trigger)
    expect(container.querySelector('.mem-drawer')).toBeTruthy()

    fireEvent.click(container.querySelector('.turn-close')!)
    expect(container.querySelector('.mem-drawer')).toBeFalsy()
    expect(container.querySelector('.turn-overlay')).toBeFalsy()
  })
})
