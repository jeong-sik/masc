import { clearStoredToken, currentStoredTokenRevision, setStoredToken } from '../api/core'
import { showToast } from './common/toast'
import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const {
  bootKeeper,
  shutdownKeeper,
  cancelKeeperChatOperation,
  editQueuedKeeperChatOperation,
  listQueuedKeeperChatOperations,
  moveQueuedKeeperChatOperationToEnd,
} = vi.hoisted(() => ({
  bootKeeper: vi.fn(),
  shutdownKeeper: vi.fn(),
  cancelKeeperChatOperation: vi.fn(),
  editQueuedKeeperChatOperation: vi.fn(),
  listQueuedKeeperChatOperations: vi.fn(),
  moveQueuedKeeperChatOperationToEnd: vi.fn(),
}))

const panelRefresh = vi.hoisted(() => ({ listeners: new Set<(name: string) => void>() }))
vi.mock('../sse-store', async importOriginal => ({
  ...await importOriginal<typeof import('../sse-store')>(),
  registerKeeperWaitingInventoryRefresh: (listener: (name: string) => void) => {
    panelRefresh.listeners.add(listener)
    return () => panelRefresh.listeners.delete(listener)
  },
}))

const { invalidateDashboardCache, refreshDashboard } = vi.hoisted(() => ({
  invalidateDashboardCache: vi.fn(),
  refreshDashboard: vi.fn(async () => undefined),
}))

// Mutable handle for the keeper-scoped inventory mock. `vi.mock` is hoisted
// above `let` declarations, so the shared state must itself be created inside
// `vi.hoisted` to avoid the temporal dead zone.
const { mockedToolsData, mockedToolsError } = vi.hoisted(() => ({
  mockedToolsData: { value: null as unknown },
  mockedToolsError: { value: null as string | null },
}))

vi.mock('../keeper-actions', () => ({
  cancelActiveKeeperThreadMessage: vi.fn(async () => true),
  hydrateKeeperStatus: vi.fn(async () => null),
  hydrateKeeperChatHistory: vi.fn(async () => undefined),
  loadFullKeeperHistory: vi.fn(async () => null),
  probeKeeperRuntime: vi.fn(),
  recoverKeeperRuntime: vi.fn(),
  hydrateTrackedKeeperChatOperations: vi.fn(async () => undefined),
  sendKeeperThreadMessage: vi.fn(async () => null),
  interruptKeeperTurn: vi.fn(async () => ({ kind: 'signalled', authRevision: 0 })),
  isKeeperThreadMessageSendInFlight: vi.fn(() => false),
}))

vi.mock('../keeper-state', async () => {
  const { signal } = await import('@preact/signals')
  const withoutUndefined = (record: Record<string, unknown>): Record<string, unknown> =>
    Object.fromEntries(Object.entries(record).filter(([, value]) => value !== undefined))

  return {
    keeperActionErrors: signal({}),
    keeperChatHistoryErrors: signal({}),
    keeperHydrating: signal({}),
    // keeper-actions is mocked here, so no history hydration ever settles:
    // treat the first hydration as settled to exercise the rendered thread.
    isKeeperChatHistoryPending: () => false,
    keeperProbing: signal({}),
    keeperRecovering: signal({}),
    keeperSending: signal({}),
    keeperStatusDetails: signal({}),
    keeperStreamStartedAt: signal({}),
    keeperStreamLastEventAt: signal({}),
    keeperThreads: signal({}),
    keeperStreamContract: (source: string, status: string, opts: Record<string, unknown> = {}) => withoutUndefined({
      source,
      status,
      eventName: opts.eventName ?? undefined,
      requestId: opts.requestId ?? undefined,
      turnRef: opts.turnRef ?? undefined,
      traceEventCount: opts.traceEventCount ?? undefined,
      lifecycleEvents: opts.lifecycleEvents ?? undefined,
      reason: opts.reason ?? undefined,
    }),
    setRecordValue: (state: { value: Record<string, unknown> }, key: string, value: unknown) => {
      state.value = { ...state.value, [key]: value }
    },
    isDefaultVisibleConversationEntry: vi.fn((entry: { role?: string; source?: string }) =>
      entry.role === 'tool'
        || ((entry.role === 'user' || entry.role === 'assistant')
          && entry.source !== 'world_state_prompt'
          && entry.source !== 'internal_assistant'
          && entry.source !== 'tool_result'
          && entry.source !== 'system'),
    ),
    isAutonomousTurnEntry: (entry: { source?: string }) => entry.source === 'autonomous_turn',
  }
})

vi.mock('../api/keeper', () => ({
  bootKeeper,
  shutdownKeeper,
  cancelKeeperChatOperation,
  editQueuedKeeperChatOperation,
  listQueuedKeeperChatOperations,
  moveQueuedKeeperChatOperationToEnd,
}))

vi.mock('../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../store')>()
  return {
    ...actual,
    invalidateDashboardCache,
    refreshDashboard,
  }
})

vi.mock('../keeper-waiting-inventory-store', () => ({
  keeperWaitingInventoryState: () => ({
    inventory: (mockedToolsData.value as {
      keeper_waiting_inventory?: unknown
    } | null)?.keeper_waiting_inventory ?? null,
    ready: mockedToolsData.value !== null,
    loading: false,
    error: mockedToolsError.value,
  }),
  subscribeKeeperWaitingInventory: vi.fn(() => vi.fn()),
  refreshKeeperWaitingInventory: vi.fn(async () => undefined),
}))

vi.mock('./common/toast', () => ({
  showToast: vi.fn(),
}))

import { keeperChatHistoryErrors, keeperActionErrors, keeperHydrating, keeperSending, keeperStreamStartedAt, keeperThreads } from '../keeper-state'
import { keeperStatusDetails } from '../keeper-state'
import {
  cancelActiveKeeperThreadMessage,
  hydrateKeeperStatus,
  interruptKeeperTurn,
  isKeeperThreadMessageSendInFlight,
  sendKeeperThreadMessage,
} from '../keeper-actions'
import {
  markToolCallOutputsHydrationFailed,
  markToolCallOutputsHydrating,
  resetToolCallOutputs,
} from '../tool-call-output-store'
import { shellAuthSummary } from '../store'
import { chatShowAutonomous, chatShowInternal } from '../lib/chat-view-prefs'
import type { KeeperConversationEntry } from '../types'
import {
  KeeperConversationPanel,
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
  filterConversationEntries,
} from './keeper-shared'

describe('filterConversationEntries', () => {
  function entry(partial: Partial<KeeperConversationEntry>): KeeperConversationEntry {
    return {
      id: 'e-1',
      role: 'user',
      source: 'direct_user',
      label: '사용자',
      text: 'hello',
      rawText: 'hello',
      timestamp: '2026-06-10T00:00:00.000Z',
      delivery: 'history',
      streamState: null,
      details: null,
      ...partial,
    }
  }

  it('returns the input untouched for empty and whitespace-only queries', () => {
    const entries = [entry({ id: 'a' }), entry({ id: 'b' })]
    expect(filterConversationEntries(entries, '')).toBe(entries)
    expect(filterConversationEntries(entries, '   ')).toBe(entries)
  })

  it('filters case-insensitively on entry text', () => {
    const entries = [
      entry({ id: 'a', text: 'Deploy the Dashboard' }),
      entry({ id: 'b', text: 'unrelated' }),
    ]
    expect(filterConversationEntries(entries, 'dashboard').map(e => e.id)).toEqual(['a'])
  })

  it('matches non-ASCII content and trims query whitespace', () => {
    const entries = [
      entry({ id: 'a', text: '배포 완료했습니다' }),
      entry({ id: 'b', text: 'done' }),
    ]
    expect(filterConversationEntries(entries, ' 배포 ').map(e => e.id)).toEqual(['a'])
  })

  it('does not match on role labels', () => {
    const entries = [entry({ id: 'a', label: '사용자', text: 'plain' })]
    expect(filterConversationEntries(entries, '사용자')).toEqual([])
  })

  it('matches tool rows by visible tool label', () => {
    const entries = [
      entry({ id: 'tool-a', role: 'tool', source: 'tool_result', label: 'masc_board_list', text: '{}' }),
      entry({ id: 'b', text: 'plain' }),
    ]
    expect(filterConversationEntries(entries, 'board_list').map(e => e.id)).toEqual(['tool-a'])
  })
})

describe('KeeperConversationPanel', () => {
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
    keeperThreads.value = {}
    keeperSending.value = {}
    chatShowAutonomous.value = true
    chatShowInternal.value = true
    keeperHydrating.value = {}
    keeperStatusDetails.value = {}
    keeperActionErrors.value = {}
    keeperChatHistoryErrors.value = {}
    keeperStreamStartedAt.value = {}
    shellAuthSummary.value = null
    mockedToolsData.value = null
    mockedToolsError.value = null
    vi.mocked(sendKeeperThreadMessage).mockReset()
    vi.mocked(sendKeeperThreadMessage).mockResolvedValue(undefined)
    vi.mocked(cancelActiveKeeperThreadMessage).mockReset()
    vi.mocked(cancelActiveKeeperThreadMessage).mockResolvedValue(true)
    vi.mocked(isKeeperThreadMessageSendInFlight).mockReset()
    vi.mocked(isKeeperThreadMessageSendInFlight).mockReturnValue(false)
    cancelKeeperChatOperation.mockReset()
    editQueuedKeeperChatOperation.mockReset()
    listQueuedKeeperChatOperations.mockReset()
    listQueuedKeeperChatOperations.mockResolvedValue([])
    moveQueuedKeeperChatOperationToEnd.mockReset()
  })

  afterEach(() => {
    render(null, container)
    clearStoredToken()
    container.remove()
    resetToolCallOutputs()
    vi.unstubAllGlobals()
  })

  it('dismisses action and history errors independently', async () => {
    keeperActionErrors.value = { sangsu: 'Action failed' }
    keeperChatHistoryErrors.value = { sangsu: 'History failed' }
    render(html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`, container)
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('Action failed')
    fireEvent.click(container.querySelector('[aria-label="에러 메시지 닫기"]')!)
    await waitFor(() => expect(container.querySelector('[role="alert"]')?.textContent).toContain('History failed'))
    expect(keeperChatHistoryErrors.value.sangsu).toBe('History failed')
    fireEvent.click(container.querySelector('[aria-label="에러 메시지 닫기"]')!)
    await waitFor(() => expect(container.querySelector('[role="alert"]')).toBeNull())
  })

  it('renders a chat-first shell and removes the old KPI header cards', async () => {
    keeperThreads.value = {
      sangsu: [
        {
          id: 'world',
          role: 'user',
          source: 'world_state_prompt',
          label: 'system',
          text: '## Current World State',
          rawText: '## Current World State',
          timestamp: '2026-03-24T00:00:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
        {
          id: 'direct-user',
          role: 'user',
          source: 'direct_user',
          label: '사용자',
          text: '지금 상태 어때?',
          rawText: '지금 상태 어때?',
          timestamp: '2026-03-24T00:01:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
        {
          id: 'direct-assistant',
          role: 'assistant',
          source: 'direct_assistant',
          label: 'sangsu',
          text: '대화 UI를 정리하고 있습니다.',
          rawText: '대화 UI를 정리하고 있습니다.',
          timestamp: '2026-03-24T00:02:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
      ],
    }

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    expect(container.textContent).toContain('직접 대화')
    expect(container.textContent).toContain('@sangsu')
    // Metadata/internal visibility switches moved to the Tweaks panel
    // (global persisted prefs) — the transcript toolbar no longer hosts them.
    expect(container.textContent).not.toContain('메타데이터 표시')
    expect(container.textContent).not.toContain('내부 메시지 숨김')
    expect(container.textContent).toContain('Current World State')
    expect(container.textContent).not.toContain('Conversation Lane')
    expect(container.textContent).not.toContain('Visible thread')
    expect(container.textContent).not.toContain('Hidden internal')
    expect(container.textContent).not.toContain('Lane state')
    expect(container.querySelector('[data-chat-variant="messenger"]')).not.toBeNull()
    expect(container.querySelector('textarea')?.getAttribute('placeholder')).toBe('메시지 입력...')
    expect(hydrateKeeperStatus).not.toHaveBeenCalled()
  })

  it('hides autonomous turns when the autonomous view pref is off', async () => {
    keeperThreads.value = {
      sangsu: [
        {
          id: 'direct-user',
          role: 'user',
          source: 'direct_user',
          label: '사용자',
          text: '직접 질문',
          rawText: '직접 질문',
          timestamp: '2026-03-24T00:01:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
        {
          id: 'autonomous-1',
          role: 'assistant',
          source: 'autonomous_turn',
          label: 'sangsu',
          text: '자율 작업 결과',
          rawText: '자율 작업 결과',
          timestamp: '2026-03-24T00:02:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
      ],
    }

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()
    expect(container.textContent).toContain('자율턴')

    chatShowAutonomous.value = false
    await waitFor(() => {
      expect(container.textContent).not.toContain('자율턴')
    })
    expect(container.textContent).toContain('직접 질문')
  })

  it('internal-message banner count excludes autonomously hidden turns', async () => {
    keeperThreads.value = {
      sangsu: [
        {
          id: 'world',
          role: 'user',
          source: 'world_state_prompt',
          label: 'system',
          text: '## Current World State',
          rawText: '## Current World State',
          timestamp: '2026-03-24T00:00:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
        {
          id: 'direct-user',
          role: 'user',
          source: 'direct_user',
          label: '사용자',
          text: '직접 질문',
          rawText: '직접 질문',
          timestamp: '2026-03-24T00:01:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
        {
          id: 'autonomous-1',
          role: 'assistant',
          source: 'autonomous_turn',
          label: 'sangsu',
          text: '자율 작업 결과',
          rawText: '자율 작업 결과',
          timestamp: '2026-03-24T00:02:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
      ],
    }
    chatShowInternal.value = false
    chatShowAutonomous.value = false

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    // Only the world-state prompt counts as a hidden internal message; the
    // autonomous turn was hidden by its own toggle and must not inflate it.
    expect(container.textContent).toContain('1개의 내부 메시지가 숨겨져 있습니다')
    expect(container.textContent).not.toContain('자율턴')
    expect(container.textContent).toContain('직접 질문')
  })

  it('renders the primary conversation layout as an airy canvas', async () => {
    keeperThreads.value = {
      sangsu: [
        {
          id: 'direct-user',
          role: 'user',
          source: 'direct_user',
          label: '사용자',
          text: '넓게 보여줘',
          rawText: '넓게 보여줘',
          timestamp: '2026-03-24T00:01:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
      ],
    }

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." layout="primary" />`,
      container,
    )
    await Promise.resolve()

    const shell = container.querySelector('[data-keeper-chat-layout="primary"]')
    expect(shell).not.toBeNull()
    expect(shell?.classList.contains('overflow-hidden')).toBe(true)
    expect(shell?.classList.contains('h-[clamp(30rem,calc(100svh-13rem),52rem)]')).toBe(true)
    expect(container.querySelector('.chat-transcript-airy')).not.toBeNull()
    expect(container.querySelector('.chat-transcript-airy')?.classList.contains('flex-1')).toBe(true)
    expect(container.querySelector('.composer-textarea')).not.toBeNull()
    expect(container.textContent).toContain('@sangsu')
    expect(container.textContent).not.toContain('Enter로 전송')
  })

  it('logs abort failures from the conversation stop button', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    vi.mocked(cancelActiveKeeperThreadMessage).mockRejectedValueOnce(new Error('network down'))
    keeperSending.value = { sangsu: true }

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    fireEvent.click(container.querySelector('button[aria-label="응답 중지"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(cancelActiveKeeperThreadMessage).toHaveBeenCalledWith('sangsu')
      expect(consoleError).toHaveBeenCalledWith(
        expect.stringContaining('failed to cancel active keeper stream for sangsu'),
        'network down',
      )
    })
    consoleError.mockRestore()
  })

  it('logs when the conversation stop button has no stream to cancel', async () => {
    const consoleWarn = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    vi.mocked(cancelActiveKeeperThreadMessage).mockResolvedValueOnce(false)
    keeperSending.value = { sangsu: true }

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    fireEvent.click(container.querySelector('button[aria-label="응답 중지"]') as HTMLButtonElement)

    await waitFor(() => {
      expect(cancelActiveKeeperThreadMessage).toHaveBeenCalledWith('sangsu')
      expect(consoleWarn).toHaveBeenCalledWith(
        expect.stringContaining('no active keeper stream to cancel for sangsu'),
      )
    })
    consoleWarn.mockRestore()
  })

  it('shows a live assistant placeholder while streaming without a reply entry', async () => {
    keeperThreads.value = {
      echo: [
        {
          id: 'direct-user',
          role: 'user',
          source: 'direct_user',
          label: '사용자',
          text: '왜 PR 안함?',
          rawText: '왜 PR 안함?',
          timestamp: '2026-03-24T00:01:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
      ],
    }
    keeperSending.value = { echo: true }

    render(
      html`<${KeeperConversationPanel} keeperName="echo" placeholder="메시지 입력..." layout="primary" />`,
      container,
    )
    await Promise.resolve()

    const placeholder = container.querySelector('[data-chat-stream-placeholder]')
    expect(placeholder).not.toBeNull()
    expect(placeholder?.textContent).toContain('응답 작성 중...')
    expect(container.querySelector('[data-chat-delivery="live"]')).not.toBeNull()
  })

  it('renders the unified composer chrome: search input and attach button', async () => {
    keeperThreads.value = {
      sangsu: [
        {
          id: 'direct-user',
          role: 'user',
          source: 'direct_user',
          label: '사용자',
          text: '첨부 테스트',
          rawText: '첨부 테스트',
          timestamp: '2026-03-24T00:01:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
      ],
    }

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    // The shared panel exposes search and the new multimodal composer
    // (file attachment + voice input) inside ChatComposer.
    expect(container.querySelector('[title="이미지·파일 첨부"]')).not.toBeNull()
    expect(container.querySelector('input[type="file"]')).not.toBeNull()
    expect(container.querySelector('input[name="keeper_chat_search"]')).not.toBeNull()
  })

  it('does not resubmit an active client action', async () => {
    keeperSending.value = { sangsu: true }
    vi.mocked(isKeeperThreadMessageSendInFlight).mockReturnValue(true)

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'same draft' } })
    await Promise.resolve()

    const sendButton = container.querySelector('.send') as HTMLButtonElement
    fireEvent.click(sendButton)

    expect(sendKeeperThreadMessage).not.toHaveBeenCalled()
  })

  it('submits a new durable operation immediately while another reply streams', async () => {
    keeperSending.value = { sangsu: true }

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'second operation' } })
    await Promise.resolve()
    fireEvent.click(container.querySelector('.send') as HTMLButtonElement)

    await waitFor(() => {
      expect(sendKeeperThreadMessage).toHaveBeenCalledWith(
        'sangsu',
        'second operation',
        expect.objectContaining({ clientActionId: expect.any(String) }),
      )
    })
  })

  it('wires the live tool-output hydration contract store into the transcript', async () => {
    keeperThreads.value = {
      sangsu: [
        {
          id: 'tool-tc-live-hydration',
          role: 'tool',
          source: 'tool_result',
          label: 'keeper_context_status',
          text: '{}',
          rawText: '{}',
          timestamp: '2026-03-24T00:00:01.000Z',
          turnRef: 'trace-live-hydration#1',
          toolCallId: 'tc-live-hydration',
          executionId: 'exec-live-hydration',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
        {
          id: 'assistant-live-hydration',
          role: 'assistant',
          source: 'direct_assistant',
          label: 'sangsu',
          text: '도구 출력을 확인했습니다.',
          rawText: '도구 출력을 확인했습니다.',
          timestamp: '2026-03-24T00:00:02.000Z',
          turnRef: 'trace-live-hydration#1',
          delivery: 'history',
          streamState: null,
          streamContract: {
            source: 'sse_event',
            status: 'backend_terminal_event',
            eventName: 'RUN_FINISHED',
          },
          traceSteps: [
            {
              kind: 'tool',
              name: 'keeper_context_status',
              toolCallId: 'tc-live-hydration',
              executionId: 'exec-live-hydration',
              ts: '2026-03-24T00:00:01.000Z',
            },
          ],
          details: null,
          error: null,
        },
      ],
    }

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." layout="workspace" />`,
      container,
    )
    await Promise.resolve()

    const traceSelector = '[data-chat-work-trace][data-chat-tool-output-hydration-source="tool_calls_endpoint"]'
    await waitFor(() => {
      const trace = container.querySelector(traceSelector)
      expect(trace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('idle')
    })

    const initialStep = container.querySelector(
      '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-live-hydration"]',
    ) as HTMLElement
    expect(initialStep.getAttribute('data-chat-trace-output-state')).toBe('pending')
    expect(initialStep.getAttribute('data-chat-trace-output-coverage')).toBe('not-hydrated')

    markToolCallOutputsHydrating('sangsu')
    markToolCallOutputsHydrationFailed('sangsu', 'HTTP 502')

    await waitFor(() => {
      const trace = container.querySelector(traceSelector)
      expect(trace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('failed')
      expect(trace?.getAttribute('data-chat-tool-output-hydration-failure')).toBe('HTTP 502')

      const step = container.querySelector(
        '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-live-hydration"]',
      ) as HTMLElement
      expect(step.getAttribute('data-chat-trace-output-state')).toBe('hydration-failed')
      expect(step.getAttribute('data-chat-trace-output-coverage')).toBe('hydration-failed')
      expect(container.textContent).toContain('출력 hydration 실패 1')
    })

    const failedStep = container.querySelector(
      '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-live-hydration"]',
    ) as HTMLElement
    fireEvent.click(failedStep.querySelector('.chat-block-tstep-row') as HTMLElement)

    await waitFor(() => {
      expect(failedStep.textContent).toContain('출력 hydration 실패 — HTTP 502')
    })
  })

  it('forwards the message-level turn inspector action to the transcript', async () => {
    const onInspectTurn = vi.fn()
    keeperThreads.value = {
      sangsu: [
        {
          id: 'direct-assistant',
          role: 'assistant',
          source: 'direct_assistant',
          label: 'sangsu',
          text: '이번 턴을 검사합니다.',
          rawText: '이번 턴을 검사합니다.',
          timestamp: '2026-03-24T00:02:00.000Z',
          delivery: 'history',
          streamState: null,
          details: null,
          error: null,
        },
      ],
    }

    render(
      html`<${KeeperConversationPanel}
        keeperName="sangsu"
        placeholder="메시지 입력..."
        layout="workspace"
        onInspectTurn=${onInspectTurn}
      />`,
      container,
    )
    await Promise.resolve()

    const action = container.querySelector('[data-testid="chat-message-action"]') as HTMLButtonElement
    expect(action).not.toBeNull()
    expect(action.textContent).toBe('턴 상세')

    action.click()

    expect(onInspectTurn).toHaveBeenCalledTimes(1)
    expect(onInspectTurn.mock.calls[0]?.[0].id).toBe('direct-assistant')
  })

  it('renders probe and recover buttons in RuntimeActions', async () => {
    const keeper = { name: 'sangsu', status: 'running' } as any

    render(
      html`<${KeeperRuntimeActions}
        actor="dashboard"
        keeper=${keeper}
      />`,
      container,
    )

    const buttons = Array.from(container.querySelectorAll('button')).map(b => b.textContent?.trim())
    expect(buttons).toContain('점검')
    expect(buttons).toContain('복구')
    expect(buttons).not.toContain('기동')
    expect(buttons).not.toContain('종료')
  })

  it('falls back to snapshot diagnostic when hydrated detail is absent', async () => {
    const keeper = {
      name: 'sangsu',
      status: 'inactive',
      diagnostic: {
        health_state: 'idle',
        next_action_path: 'direct_message',
        last_reply_status: 'stale',
        summary: 'Snapshot says the keeper has not taken a turn yet.',
      },
    } as any

    render(
      html`<${KeeperDiagnosticSummary} keeper=${keeper} />`,
      container,
    )
    await Promise.resolve()

    expect(container.textContent).toContain('idle')
    expect(container.textContent).toContain('Snapshot says the keeper has not taken a turn yet.')
  })

  it('shows the running owner state while a Keeper turn is active', async () => {
    mockedToolsData.value = {
      keeper_waiting_inventory: {
        keepers: [
          { keeper_name: 'sangsu', state: 'busy', waiting_on: [], waiting_count: 0 },
        ],
      },
    }
    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="Say something" layout="primary" />`,
      container,
    )

    await waitFor(() => {
      expect(container.textContent).toContain('Keeper 턴 실행 중')
      expect(container.querySelector('[data-keeper-operation-status]')?.textContent).toContain('Running')
    })
  })

  it.each(['resolve', 'reject'] as const)('retains the newer operation list when an old read settles (%s)', async outcome => {
    shellAuthSummary.value = { effective_role: 'admin' } as typeof shellAuthSummary.value
    let finish!: (value: unknown) => void
    let fail!: (error: Error) => void
    const row = (operationId: string) => ({ operationId, sequence: '1', createdAt: 1, input: null, state: { kind: 'queued' } })
    listQueuedKeeperChatOperations.mockReturnValueOnce(new Promise((resolve, reject) => { finish = resolve; fail = reject }))
      .mockResolvedValueOnce([row('current-operation')])
    render(html`<${KeeperConversationPanel} keeperName="sangsu" layout="primary" />`, container)
    fireEvent.click(container.querySelector('[data-open-keeper-operation-control]') as HTMLButtonElement)
    await waitFor(() => expect(listQueuedKeeperChatOperations).toHaveBeenCalledTimes(1))
    for (const listener of panelRefresh.listeners) listener('sangsu')
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="current-operation"]')).not.toBeNull())
    if (outcome === 'resolve') finish([row('old-operation')])
    else fail(new Error('old list failure'))
    await Promise.resolve()
    await Promise.resolve()
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="current-operation"]')).not.toBeNull())
    expect(container.querySelector('[data-operator-chat-operation="old-operation"]')).toBeNull()
  })

  it.each(['authentication', 'keeper', 'remount'] as const)('revokes operation list ownership on %s replacement', async replacement => {
    shellAuthSummary.value = { effective_role: 'admin' } as typeof shellAuthSummary.value
    let finish!: (value: unknown) => void
    const row = (operationId: string) => ({ operationId, sequence: '1', createdAt: 1, input: null, state: { kind: 'queued' } })
    listQueuedKeeperChatOperations.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
      .mockResolvedValueOnce([row('replacement-operation')])
    const mount = (keeperName: string) => render(html`<${KeeperConversationPanel} keeperName=${keeperName} layout="primary" />`, container)
    mount('sangsu')
    fireEvent.click(container.querySelector('[data-open-keeper-operation-control]') as HTMLButtonElement)
    await waitFor(() => expect(listQueuedKeeperChatOperations).toHaveBeenCalledTimes(1))
    const signal = listQueuedKeeperChatOperations.mock.calls[0]?.[2]?.signal as AbortSignal
    if (replacement === 'authentication') setStoredToken('replacement-fixture')
    else if (replacement === 'keeper') mount('rondo')
    else {
      render(null, container)
      mount('sangsu')
      fireEvent.click(container.querySelector('[data-open-keeper-operation-control]') as HTMLButtonElement)
    }
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="replacement-operation"]')).not.toBeNull())
    expect(signal.aborted).toBe(true)
    finish([row('superseded-operation')])
    await Promise.resolve()
    await Promise.resolve()
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="replacement-operation"]')).not.toBeNull())
    expect(container.querySelector('[data-operator-chat-operation="superseded-operation"]')).toBeNull()
  })

  it('does not publish an old Keeper mutation failure after panel replacement', async () => {
    shellAuthSummary.value = { effective_role: 'admin' } as typeof shellAuthSummary.value
    const row = (operationId: string) => ({ operationId, sequence: '1', createdAt: 1, input: null, state: { kind: 'queued' } })
    listQueuedKeeperChatOperations.mockResolvedValueOnce([row('old-operation')]).mockResolvedValue([row('current-operation')])
    let fail!: (error: Error) => void
    cancelKeeperChatOperation.mockReturnValueOnce(new Promise((_resolve, reject) => { fail = reject }))
    const mount = (keeperName: string) => render(html`<${KeeperConversationPanel} keeperName=${keeperName} layout="primary" />`, container)
    mount('sangsu')
    fireEvent.click(container.querySelector('[data-open-keeper-operation-control]') as HTMLButtonElement)
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="old-operation"]')).not.toBeNull())
    const button = Array.from(container.querySelector('[data-operator-chat-operation="old-operation"]')!.querySelectorAll('button')).find(button => button.textContent === '취소')!
    fireEvent.click(button)
    await waitFor(() => expect(cancelKeeperChatOperation).toHaveBeenCalledTimes(1))
    mount('rondo')
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="current-operation"]')).not.toBeNull())
    vi.mocked(showToast).mockClear()
    fail(new Error('old mutation failure'))
    await new Promise(resolve => setTimeout(resolve, 0))
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="current-operation"]')).not.toBeNull())
    expect(showToast).not.toHaveBeenCalled()
    expect(listQueuedKeeperChatOperations).toHaveBeenCalledTimes(2)
  })

  it('preserves freshly reconciled queue rows when publishing a mutation error', async () => {
    shellAuthSummary.value = { effective_role: 'admin' } as typeof shellAuthSummary.value
    const row = (operationId: string) => ({ operationId, sequence: '1', createdAt: 1, input: null, state: { kind: 'queued' } })
    listQueuedKeeperChatOperations.mockResolvedValueOnce([row('before-mutation')]).mockResolvedValueOnce([row('after-mutation')])
    cancelKeeperChatOperation.mockRejectedValueOnce(new Error('mutation failed'))
    render(html`<${KeeperConversationPanel} keeperName="sangsu" layout="primary" />`, container)
    fireEvent.click(container.querySelector('[data-open-keeper-operation-control]') as HTMLButtonElement)
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="before-mutation"]')).not.toBeNull())
    const button = Array.from(container.querySelector('[data-operator-chat-operation="before-mutation"]')!.querySelectorAll('button')).find(button => button.textContent === '취소')!
    vi.mocked(showToast).mockClear()
    fireEvent.click(button)
    await waitFor(() => expect(showToast).toHaveBeenCalled())
    expect(container.querySelector('[data-operator-chat-operation="after-mutation"]')).not.toBeNull()
    expect(container.querySelector('[data-operator-chat-operation="before-mutation"]')).toBeNull()
    listQueuedKeeperChatOperations.mockRejectedValueOnce(new Error('push read failed'))
    for (const listener of panelRefresh.listeners) listener('sangsu')
    await waitFor(() => expect(listQueuedKeeperChatOperations).toHaveBeenCalledTimes(3))
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(container.textContent).toContain('mutation failed')
  })

  it('retains each operation action owner while another action is pending', async () => {
    shellAuthSummary.value = { effective_role: 'admin' } as typeof shellAuthSummary.value
    const row = (operationId: string) => ({ operationId, sequence: '1', createdAt: 1, input: null, state: { kind: 'queued' } })
    listQueuedKeeperChatOperations.mockResolvedValue([row('operation-a'), row('operation-b')])
    let failA!: (error: Error) => void
    let finishB!: (value: unknown) => void
    cancelKeeperChatOperation.mockReturnValueOnce(new Promise((_resolve, reject) => { failA = reject }))
      .mockReturnValueOnce(new Promise(resolve => { finishB = resolve }))
    render(html`<${KeeperConversationPanel} keeperName="sangsu" layout="primary" />`, container)
    fireEvent.click(container.querySelector('[data-open-keeper-operation-control]') as HTMLButtonElement)
    const cancel = (id: string) => Array.from(container.querySelector(`[data-operator-chat-operation="${id}"]`)!.querySelectorAll('button')).find(button => button.textContent === '취소')!
    await waitFor(() => expect(container.querySelector('[data-operator-chat-operation="operation-b"]')).not.toBeNull())
    fireEvent.click(cancel('operation-a'))
    fireEvent.click(cancel('operation-b'))
    await waitFor(() => expect(cancelKeeperChatOperation).toHaveBeenCalledTimes(2))
    expect(cancel('operation-a').disabled).toBe(true)
    expect(cancel('operation-b').disabled).toBe(true)
    vi.mocked(showToast).mockClear()
    failA(new Error('operation A failed'))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith('operation A failed', 'error'))
    expect(cancel('operation-b').disabled).toBe(true)
    finishB({})
    await waitFor(() => expect(cancel('operation-b').disabled).toBe(false))
    expect(container.textContent).toContain('operation A failed')
  })

  it('renders and mutates queued chat operations by singular operation id', async () => {
    shellAuthSummary.value = { effective_role: 'admin' } as typeof shellAuthSummary.value
    const operation = {
      operationId: 'kmsg-operation-1',
      sequence: '7',
      createdAt: 42,
      input: {
        message: 'durable operation input',
        wire: {
          schema: 'masc.keeper_chat_operation.input.v1',
          message: 'durable operation input',
          user_blocks: [{ type: 'text', text: 'durable operation input' }],
          turn_instructions: null,
          surface_context: null,
          attachments: [],
        },
      },
      state: { kind: 'queued' as const },
    }
    listQueuedKeeperChatOperations.mockResolvedValue([operation])
    editQueuedKeeperChatOperation.mockResolvedValue(operation)
    moveQueuedKeeperChatOperationToEnd.mockResolvedValue(operation)
    cancelKeeperChatOperation.mockResolvedValue({
      ...operation,
      input: null,
      state: { kind: 'cancelled', completedAt: 43 },
    })
    Object.defineProperty(window, 'prompt', {
      configurable: true,
      value: vi.fn(() => 'edited operation input'),
    })

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="Say something" layout="primary" />`,
      container,
    )
    fireEvent.click(container.querySelector('[data-open-keeper-operation-control]') as HTMLButtonElement)

    await waitFor(() => {
      const row = container.querySelector('[data-operator-chat-operation="kmsg-operation-1"]')
      expect(row?.textContent).toContain('seq 7')
      expect(row?.textContent).toContain('durable operation input')
    })

    const row = container.querySelector('[data-operator-chat-operation="kmsg-operation-1"]') as HTMLElement
    const buttons = Array.from(row.querySelectorAll('button'))
    fireEvent.click(buttons.find(button => button.textContent === '수정') as HTMLButtonElement)
    await waitFor(() => {
      expect(editQueuedKeeperChatOperation).toHaveBeenCalledWith(
        'sangsu',
        operation,
        'edited operation input',
      )
    })
  })

  it('keeps operation controls closed for a Worker session', async () => {
    shellAuthSummary.value = { effective_role: 'worker' } as typeof shellAuthSummary.value
    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="Say something" layout="primary" />`,
      container,
    )

    const openButton = container.querySelector('[data-open-keeper-operation-control]') as HTMLButtonElement
    expect(openButton.disabled).toBe(true)
    fireEvent.click(openButton)
    expect(container.querySelector('[data-keeper-operation-control-panel]')).toBeNull()
  })


  it.each(['authentication_superseded', 'signalled'] as const)('does not publish an interruption toast from replaced authentication (%s)', async kind => {
    setStoredToken('fixture-old')
    const authRevision = currentStoredTokenRevision()
    let finish!: (value: { kind: typeof kind; authRevision: number }) => void
    vi.mocked(interruptKeeperTurn).mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    vi.mocked(showToast).mockClear()
    mockedToolsData.value = { keeper_waiting_inventory: { keepers: [
      { keeper_name: 'sangsu', state: 'busy', waiting_on: [], waiting_count: 0 },
    ] } }
    render(html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="Say something" layout="primary" />`, container)
    await waitFor(() => expect(container.textContent).toContain('Keeper 턴 실행 중'))
    const button = Array.from(container.querySelectorAll('button')).find(button => button.textContent?.trim() === '현재 턴 중단')
    expect(button).toBeDefined()
    fireEvent.click(button!)
    setStoredToken('fixture-new')
    finish({ kind, authRevision })
    await Promise.resolve()
    await Promise.resolve()
    expect(showToast).not.toHaveBeenCalled()
    clearStoredToken()
  })

  it('calls interruptKeeperTurn when the busy toolbar interrupt button is clicked', async () => {
    mockedToolsData.value = {
      keeper_waiting_inventory: {
        keepers: [
          { keeper_name: 'sangsu', state: 'busy', waiting_on: [], waiting_count: 0 },
        ],
      },
    }
    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="Say something" layout="primary" />`,
      container,
    )
    await waitFor(() => {
      expect(container.textContent).toContain('Keeper 턴 실행 중')
    })

    const interruptButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.trim() === '현재 턴 중단') as HTMLButtonElement | undefined
    expect(interruptButton).toBeDefined()

    fireEvent.click(interruptButton as HTMLButtonElement)

    await waitFor(() => {
      expect(interruptKeeperTurn).toHaveBeenCalledWith('sangsu')
    })
  })
})
