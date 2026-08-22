// @vitest-environment jsdom

// The "여기까지 읽음" divider anchors on the last-seen cursor captured when the
// panel is entered, not on the live cursor. The mount flow itself advances the
// cursor (hydration marks the newest merged entry as seen) and so does every
// pinned-to-bottom render, so an anchor read from the live cursor would place
// the line under the newest entry — or nowhere — on every visit.

import { html } from 'htm/preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ToolCallEntry } from '../api/dashboard'

const { fetchKeeperChatHistory } = vi.hoisted(() => ({
  fetchKeeperChatHistory: vi.fn(),
}))

const { fetchKeeperToolCalls, fetchKeeperWaitingInventory } = vi.hoisted(() => ({
  fetchKeeperToolCalls: vi.fn(async (): Promise<{ entries: ToolCallEntry[] }> => ({ entries: [] })),
  fetchKeeperWaitingInventory: vi.fn(async () => ({ keepers: [] })),
}))

vi.mock('../api/keeper', () => ({
  cancelQueuedKeeperMessage: vi.fn(async () => undefined),
  fetchKeeperChatHistory,
  fetchQueuedKeeperMessageResult: vi.fn(),
  isTerminalQueuedKeeperMessage: vi.fn(() => true),
  queuedKeeperMessageError: vi.fn(() => 'request failed'),
  queuedKeeperMessageToReply: vi.fn(() => ({ text: '', details: null })),
  streamKeeperMessage: vi.fn(),
}))

vi.mock('../api/dashboard', () => ({
  fetchKeeperToolCalls,
  fetchKeeperWaitingInventory,
}))
vi.mock('../api/mcp', () => ({ callMcpTool: vi.fn() }))
vi.mock('../api/core', () => ({ runOperatorAction: vi.fn() }))
vi.mock('../store', async () => {
  const { signal } = await import('@preact/signals')
  return {
    invalidateDashboardCache: vi.fn(),
    refreshDashboard: vi.fn(async () => undefined),
    shellAuthSummary: signal(null),
  }
})
vi.mock('./common/toast', () => ({ showToast: vi.fn() }))

import { KeeperConversationPanel } from './keeper-shared'
import { _resetChatHydrationForTests } from '../keeper-actions'
import {
  activeKeeperName,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamLastEventAt,
  keeperStreamStartedAt,
  keeperThreads,
} from '../keeper-state'
import {
  _clearKeeperLastSeenForTests,
  advanceKeeperLastSeen,
  getKeeperLastSeen,
} from '../keeper-last-seen'
import { resetToolCallOutputs } from '../tool-call-output-store'
import { _clearTrackedKeeperChatOperationsForTests } from '../keeper-chat-operations-local'
import { _resetChatStoreForTests } from '../keeper-chat-store'
import type { KeeperConversationEntry } from '../types'

const DIVIDER = '.kw-unreaddiv'

function historyRow(id: string, ts: number) {
  return { id, role: 'assistant' as const, content: `message ${id}`, ts, source: 'dashboard' as const }
}

function liveEntry(id: string, tsUnix: number): KeeperConversationEntry {
  return {
    id,
    role: 'assistant',
    source: 'direct_assistant',
    label: 'sangsu',
    text: `message ${id}`,
    rawText: `message ${id}`,
    timestamp: new Date(tsUnix * 1000).toISOString(),
    delivery: 'history',
    streamState: null,
    details: null,
  }
}

function mount(container: HTMLElement, keeperName: string) {
  render(
    html`<${KeeperConversationPanel} keeperName=${keeperName} placeholder="메시지 입력..." layout="workspace" />`,
    container,
  )
}

function entryAfterDivider(container: HTMLElement): string | null {
  const divider = container.querySelector(DIVIDER)
  return divider?.nextElementSibling?.getAttribute('data-chat-entry-id') ?? null
}

describe('KeeperConversationPanel unread divider anchor', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.stubGlobal('localStorage', {
      getItem: vi.fn(() => null),
      setItem: vi.fn(),
      removeItem: vi.fn(),
      clear: vi.fn(),
    })
    fetchKeeperChatHistory.mockReset()
    fetchKeeperToolCalls.mockReset()
    fetchKeeperToolCalls.mockResolvedValue({ entries: [] })
    keeperThreads.value = {}
    keeperActionErrors.value = {}
    keeperHydrating.value = {}
    keeperProbing.value = {}
    keeperRecovering.value = {}
    keeperSending.value = {}
    keeperStatusDetails.value = {}
    keeperStreamStartedAt.value = {}
    keeperStreamLastEventAt.value = {}
    activeKeeperName.value = ''
    _clearKeeperLastSeenForTests()
    _resetChatHydrationForTests()
    _clearTrackedKeeperChatOperationsForTests()
    _resetChatStoreForTests()
    resetToolCallOutputs()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.unstubAllGlobals()
    _clearKeeperLastSeenForTests()
    _resetChatHydrationForTests()
    _clearTrackedKeeperChatOperationsForTests()
    _resetChatStoreForTests()
    resetToolCallOutputs()
  })

  it('places the divider by the cursor captured at mount even though hydration advances it', async () => {
    // The previous visit ended on the entry at ts=150; m2 and m3 arrived since.
    advanceKeeperLastSeen('sangsu', 150)
    fetchKeeperChatHistory.mockResolvedValueOnce([
      historyRow('m1', 100),
      historyRow('m2', 200),
      historyRow('m3', 300),
    ])

    mount(container, 'sangsu')

    await waitFor(() => {
      expect(container.querySelector('[data-chat-entry-id="m3"]')).not.toBeNull()
    })
    // Hydration marked the newest merged entry as seen for the NEXT visit...
    await waitFor(() => {
      expect(getKeeperLastSeen('sangsu')).toBe(300)
    })
    // ...but this visit's line still sits before the first entry newer than 150.
    expect(container.querySelectorAll(DIVIDER).length).toBe(1)
    expect(entryAfterDivider(container)).toBe('m2')
  })

  it('keeps the divider in place when the cursor advances during the visit', async () => {
    advanceKeeperLastSeen('sangsu', 150)
    fetchKeeperChatHistory.mockResolvedValueOnce([
      historyRow('m1', 100),
      historyRow('m2', 200),
      historyRow('m3', 300),
    ])

    mount(container, 'sangsu')
    await waitFor(() => {
      expect(entryAfterDivider(container)).toBe('m2')
    })

    // A new entry streams in and the operator, pinned to the bottom, is marked
    // as caught up past it.
    keeperThreads.value = {
      ...keeperThreads.value,
      sangsu: [...(keeperThreads.value.sangsu ?? []), liveEntry('m4', 400)],
    }
    advanceKeeperLastSeen('sangsu', 400)

    await waitFor(() => {
      expect(container.querySelector('[data-chat-entry-id="m4"]')).not.toBeNull()
    })
    expect(getKeeperLastSeen('sangsu')).toBe(400)
    expect(container.querySelectorAll(DIVIDER).length).toBe(1)
    expect(entryAfterDivider(container)).toBe('m2')
  })

  it('draws no divider on a first visit with no prior cursor', async () => {
    fetchKeeperChatHistory.mockResolvedValueOnce([historyRow('m1', 100), historyRow('m2', 200)])

    mount(container, 'sangsu')

    await waitFor(() => {
      expect(container.querySelector('[data-chat-entry-id="m2"]')).not.toBeNull()
    })
    // The cursor is seeded for the next visit, without a line on this one.
    await waitFor(() => {
      expect(getKeeperLastSeen('sangsu')).toBe(200)
    })
    expect(container.querySelector(DIVIDER)).toBeNull()
  })

  it('re-captures the anchor when the same panel instance switches keeper', async () => {
    advanceKeeperLastSeen('sangsu', 150)
    advanceKeeperLastSeen('idealist', 250)
    fetchKeeperChatHistory.mockImplementation(async (name: string) =>
      name === 'sangsu'
        ? [historyRow('s1', 100), historyRow('s2', 200), historyRow('s3', 300)]
        : [historyRow('i1', 100), historyRow('i2', 200), historyRow('i3', 300)],
    )

    mount(container, 'sangsu')
    await waitFor(() => {
      expect(entryAfterDivider(container)).toBe('s2')
    })

    mount(container, 'idealist')
    await waitFor(() => {
      expect(container.querySelector('[data-chat-entry-id="i3"]')).not.toBeNull()
    })
    expect(container.querySelectorAll(DIVIDER).length).toBe(1)
    expect(entryAfterDivider(container)).toBe('i3')
  })
})
