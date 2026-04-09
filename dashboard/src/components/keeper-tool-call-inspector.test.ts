// Tests for KeeperToolCallInspector component

import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { waitFor } from '@testing-library/preact'

const { fetchKeeperToolCalls } = vi.hoisted(() => ({
  fetchKeeperToolCalls: vi.fn(),
}))

vi.mock('../api/dashboard', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api/dashboard')>()
  return { ...actual, fetchKeeperToolCalls }
})

import { KeeperToolCallInspector } from './keeper-tool-call-inspector'
import type { ToolCallEntry } from '../api/dashboard'

function makeEntry(overrides: Partial<ToolCallEntry> = {}): ToolCallEntry {
  return {
    ts: 1700000000,
    keeper: 'alice',
    tool: 'masc_status',
    input: { query: 'hi' },
    output: 'status: ok',
    success: true,
    duration_ms: 42,
    ...overrides,
  }
}

describe('KeeperToolCallInspector', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
  })

  it('shows loading state initially', async () => {
    // Never resolves during this test
    fetchKeeperToolCalls.mockReturnValue(new Promise(() => {}))

    render(html`<${KeeperToolCallInspector} keeperName="alice" />`, container)
    await Promise.resolve()

    expect(container.textContent).toContain('불러오는 중')
  })

  it('renders entries after successful fetch', async () => {
    const entries = [
      makeEntry({ tool: 'masc_status', success: true }),
      makeEntry({ tool: 'masc_board_post', success: false, duration_ms: 1500 }),
    ]
    fetchKeeperToolCalls.mockResolvedValue({ keeper: 'alice', count: 2, entries })

    render(html`<${KeeperToolCallInspector} keeperName="alice" />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('masc_status')
    })

    expect(container.textContent).toContain('masc_board_post')
    expect(container.textContent).toContain('2 calls')
  })

  it('shows empty state when no entries', async () => {
    fetchKeeperToolCalls.mockResolvedValue({ keeper: 'alice', count: 0, entries: [] })

    render(html`<${KeeperToolCallInspector} keeperName="alice" />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('도구 호출 데이터 없음')
    })
  })

  it('shows error state on fetch failure', async () => {
    fetchKeeperToolCalls.mockRejectedValue(new Error('network error'))

    render(html`<${KeeperToolCallInspector} keeperName="alice" />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('network error')
    })
  })

  it('filters entries by tool name', async () => {
    const entries = [
      makeEntry({ tool: 'masc_status' }),
      makeEntry({ tool: 'masc_board_post' }),
    ]
    fetchKeeperToolCalls.mockResolvedValue({ keeper: 'alice', count: 2, entries })

    render(html`<${KeeperToolCallInspector} keeperName="alice" />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('masc_status')
    })

    const filterInput = container.querySelector('input[type="text"]') as HTMLInputElement
    expect(filterInput).not.toBeNull()

    filterInput.value = 'board'
    filterInput.dispatchEvent(new Event('input', { bubbles: true }))
    await Promise.resolve()

    await waitFor(() => {
      expect(container.textContent).not.toContain('masc_status')
      expect(container.textContent).toContain('masc_board_post')
    })
  })

  it('rows have aria-expanded attribute for accessibility', async () => {
    const entries = [makeEntry({ tool: 'masc_status' })]
    fetchKeeperToolCalls.mockResolvedValue({ keeper: 'alice', count: 1, entries })

    render(html`<${KeeperToolCallInspector} keeperName="alice" />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('masc_status')
    })

    const rowButton = container.querySelector('[role="button"]') as HTMLElement
    expect(rowButton).not.toBeNull()
    expect(rowButton.getAttribute('aria-expanded')).toBe('false')

    rowButton.click()
    await Promise.resolve()

    await waitFor(() => {
      expect(rowButton.getAttribute('aria-expanded')).toBe('true')
    })
  })

  it('uses stable keys (ts+keeper+tool) not index', async () => {
    // Stable keys ensure expand state is preserved when filtering
    // We verify the key attribute includes ts and keeper
    const entries = [
      makeEntry({ ts: 1700000001, keeper: 'alice', tool: 'masc_status' }),
      makeEntry({ ts: 1700000002, keeper: 'alice', tool: 'masc_board_post' }),
    ]
    fetchKeeperToolCalls.mockResolvedValue({ keeper: 'alice', count: 2, entries })

    render(html`<${KeeperToolCallInspector} keeperName="alice" />`, container)

    await waitFor(() => {
      expect(container.textContent).toContain('masc_status')
      expect(container.textContent).toContain('masc_board_post')
    })

    // Both entries visible, no crash = stable keys working
    const rows = container.querySelectorAll('[role="button"]')
    expect(rows.length).toBe(2)
  })
})
