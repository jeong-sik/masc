import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { bootKeeper, shutdownKeeper } = vi.hoisted(() => ({
  bootKeeper: vi.fn(),
  shutdownKeeper: vi.fn(),
}))

const { invalidateDashboardCache, refreshDashboard } = vi.hoisted(() => ({
  invalidateDashboardCache: vi.fn(),
  refreshDashboard: vi.fn(async () => undefined),
}))

vi.mock('../keeper-actions', () => ({
  cancelActiveKeeperThreadMessage: vi.fn(async () => true),
  hydrateKeeperStatus: vi.fn(async () => null),
  hydrateKeeperChatHistory: vi.fn(async () => undefined),
  loadFullKeeperHistory: vi.fn(async () => null),
  probeKeeperRuntime: vi.fn(),
  recoverKeeperRuntime: vi.fn(),
  resumePendingKeeperChatRequests: vi.fn(async () => undefined),
  sendKeeperThreadMessage: vi.fn(async () => null),
  isKeeperThreadMessageSendInFlight: vi.fn(() => false),
}))

vi.mock('../keeper-state', async () => {
  const { signal } = await import('@preact/signals')
  const withoutUndefined = (record: Record<string, unknown>): Record<string, unknown> =>
    Object.fromEntries(Object.entries(record).filter(([, value]) => value !== undefined))

  return {
    keeperActionErrors: signal({}),
    keeperHydrating: signal({}),
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
      deliveryReceipt: opts.deliveryReceipt ?? undefined,
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
  }
})

vi.mock('../api/keeper', () => ({
  bootKeeper,
  shutdownKeeper,
}))

vi.mock('../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../store')>()
  return {
    ...actual,
    invalidateDashboardCache,
    refreshDashboard,
  }
})

vi.mock('./common/toast', () => ({
  showToast: vi.fn(),
}))

import { keeperActionErrors, keeperHydrating, keeperSending, keeperStreamStartedAt, keeperThreads } from '../keeper-state'
import { keeperStatusDetails } from '../keeper-state'
import {
  cancelActiveKeeperThreadMessage,
  hydrateKeeperStatus,
  isKeeperThreadMessageSendInFlight,
  sendKeeperThreadMessage,
} from '../keeper-actions'
import { _resetChatStoreForTests, enqueueInput, getQueuedMessages, getQueueLength } from '../keeper-chat-store'
import {
  markToolCallOutputsHydrationFailed,
  markToolCallOutputsHydrating,
  resetToolCallOutputs,
} from '../tool-call-output-store'
import { shellAuthSummary } from '../store'
import type { ChatBlock, KeeperConversationAttachment, KeeperConversationEntry, KeeperUserInputBlock } from '../types'
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
      entry({ id: 'tool-a', role: 'tool', source: 'tool_result', label: 'keeper_board_list', text: '{}' }),
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
    keeperHydrating.value = {}
    keeperStatusDetails.value = {}
    keeperActionErrors.value = {}
    keeperStreamStartedAt.value = {}
    shellAuthSummary.value = null
    _resetChatStoreForTests()
    vi.mocked(sendKeeperThreadMessage).mockReset()
    vi.mocked(sendKeeperThreadMessage).mockResolvedValue(undefined)
    vi.mocked(cancelActiveKeeperThreadMessage).mockReset()
    vi.mocked(cancelActiveKeeperThreadMessage).mockResolvedValue(true)
    vi.mocked(isKeeperThreadMessageSendInFlight).mockReset()
    vi.mocked(isKeeperThreadMessageSendInFlight).mockReturnValue(false)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    _resetChatStoreForTests()
    resetToolCallOutputs()
    vi.unstubAllGlobals()
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

  it('does not enqueue a duplicate submit for the active client action', async () => {
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

    expect(getQueueLength('sangsu')).toBe(0)
  })

  it('enqueues repeated same-draft submits as separate queued actions', async () => {
    keeperSending.value = { sangsu: true }
    enqueueInput('sangsu', 'same draft', undefined, 'queued-action-1')

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

    expect(getQueueLength('sangsu')).toBe(2)
  })

  it('renders queued drafts inside the transcript while the keeper is busy', async () => {
    keeperSending.value = { sangsu: true }
    enqueueInput('sangsu', 'queued transcript draft', undefined, 'queued-action-1')

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    expect(container.textContent).toContain('queued transcript draft')
    expect(container.querySelector('[data-chat-delivery="queued"]')).not.toBeNull()
  })

  it('renders queue card and transcript placeholder with the same FIFO identity', async () => {
    keeperSending.value = { sangsu: true }
    enqueueInput('sangsu', 'queued first', undefined, 'queued-click-1')
    enqueueInput('sangsu', 'queued second', undefined, 'queued-click-2')

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." layout="workspace" />`,
      container,
    )
    await Promise.resolve()

    const queueCards = [...container.querySelectorAll('[data-chat-queue-item]')] as HTMLElement[]
    const queuedBubbles = [...container.querySelectorAll('[data-chat-entry-id^="queued-user-"]')] as HTMLElement[]

    expect(queueCards.map(node => node.getAttribute('data-chat-queue-seq'))).toEqual(['1', '2'])
    expect(queuedBubbles.map(node => node.getAttribute('data-chat-queue-seq'))).toEqual(['1', '2'])
    expect(queueCards.map(node => node.getAttribute('data-chat-queue-client-action-id'))).toEqual([
      'queued-click-1',
      'queued-click-2',
    ])
    expect(queuedBubbles.map(node => node.getAttribute('data-chat-queue-client-action-id'))).toEqual([
      'queued-click-1',
      'queued-click-2',
    ])
    expect(queuedBubbles.map(node => node.getAttribute('data-chat-stream-contract-delivery-receipt'))).toEqual([
      'no_delivery_receipt',
      'no_delivery_receipt',
    ])
    expect(queuedBubbles.map(node => node.getAttribute('data-chat-stream-contract-reason'))).toEqual([
      'client-side composer queue item; not yet submitted to keeper runtime',
      'client-side composer queue item; not yet submitted to keeper runtime',
    ])
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

  it('renders queued voice draft display blocks inside the transcript', async () => {
    keeperSending.value = { sangsu: true }
    const voiceBlocks: ChatBlock[] = [
      { t: 'voice', secs: 3, size: '12 KB', wave: [0.2, 0.8], transcript: 'hello voice' },
      { t: 'p', html: '[Voice memo 00:03 (12 KB)]<br />hello voice' },
    ]
    enqueueInput(
      'sangsu',
      '[Voice memo 00:03 (12 KB)]\nhello voice',
      undefined,
      'queued-voice-1',
      voiceBlocks,
      [{ type: 'text', text: '[Voice memo 00:03 (12 KB)]\nhello voice' }],
    )

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    expect(container.querySelector('[data-chat-delivery="queued"]')).not.toBeNull()
    expect(container.querySelector('[data-chat-block="voice"]')).not.toBeNull()
    expect(container.textContent).toContain('hello voice')
  })

  it('keeps queued attachment drafts visible with multimodal provenance and no delivery receipt', async () => {
    keeperSending.value = { sangsu: true }
    const attachments: KeeperConversationAttachment[] = [
      {
        id: 'queued-att',
        type: 'image',
        name: 'queued.png',
        size: 1024,
        mimeType: 'image/png',
        data: 'data:image/png;base64,iVBORw0KGgo=',
      },
    ]
    const displayBlocks: ChatBlock[] = [
      {
        t: 'attach',
        id: 'queued-att',
        name: 'queued.png',
        kind: 'image',
        src: 'data:image/png;base64,iVBORw0KGgo=',
        mimeType: 'image/png',
        sizeBytes: 1024,
      },
    ]
    const userBlocks: KeeperUserInputBlock[] = [
      {
        type: 'image',
        attachmentId: 'queued-att',
        name: 'queued.png',
        mimeType: 'image/png',
        size: 1024,
      },
    ]
    enqueueInput('sangsu', '', attachments, 'queued-attachment-1', displayBlocks, userBlocks)

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    const bubble = container.querySelector('[data-chat-entry-id^="queued-user-"]') as HTMLElement
    expect(bubble.getAttribute('data-chat-delivery-state')).toBe('queued')
    expect(bubble.getAttribute('data-chat-stream-contract-delivery-receipt')).toBe('no_delivery_receipt')
    expect(bubble.getAttribute('data-chat-attachment-count')).toBe('1')
    expect(bubble.getAttribute('data-chat-server-attach-block-count')).toBe('1')
    expect(bubble.getAttribute('data-chat-multimodal-sources')).toBe('persisted_attachment,server_block')
    expect(bubble.getAttribute('data-chat-multimodal-kinds')).toBe('image')
    expect(bubble.querySelector('[data-chat-delivery="queued"]')).not.toBeNull()
    expect(bubble.querySelector('[data-chat-attachment-card="queued-att"]')).not.toBeNull()
    expect(bubble.querySelector('[data-chat-block="attach"][data-chat-multimodal-source="server_block"]')).not.toBeNull()
  })

  it('renders queued drafts with invalid timestamps without throwing', async () => {
    keeperSending.value = { sangsu: true }
    const msg = enqueueInput('sangsu', 'queued invalid timestamp', undefined, 'queued-action-1')
    msg.timestamp = Number.NaN

    expect(() => render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )).not.toThrow()
    await Promise.resolve()

    expect(container.textContent).toContain('queued invalid timestamp')
    expect(container.querySelector('[data-chat-delivery="queued"]')).not.toBeNull()
  })

  it('keeps queued client action ids attached when draining the queue as independent turns', async () => {
    enqueueInput('sangsu', 'queued one', undefined, 'queued-click-1')
    enqueueInput('sangsu', 'queued two', undefined, 'queued-click-2')

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'trigger drain' } })
    await Promise.resolve()

    const sendButton = container.querySelector('.send') as HTMLButtonElement
    fireEvent.click(sendButton)

    await waitFor(() => expect(sendKeeperThreadMessage).toHaveBeenCalledTimes(3))
    expect(vi.mocked(sendKeeperThreadMessage).mock.calls[1]?.[1]).toBe('queued one')
    expect(vi.mocked(sendKeeperThreadMessage).mock.calls[1]?.[2]).toEqual(expect.objectContaining({
      clientActionId: 'queued-click-1',
    }))
    expect(vi.mocked(sendKeeperThreadMessage).mock.calls[2]?.[1]).toBe('queued two')
    expect(vi.mocked(sendKeeperThreadMessage).mock.calls[2]?.[2]).toEqual(expect.objectContaining({
      clientActionId: 'queued-click-2',
    }))
  })

  it('continues draining messages queued while a queue batch is in flight', async () => {
    vi.mocked(sendKeeperThreadMessage).mockImplementation(async (_keeperName, message) => {
      if (message === 'queued one') {
        enqueueInput('sangsu', 'queued during drain', undefined, 'queued-click-3')
      }
    })
    enqueueInput('sangsu', 'queued one', undefined, 'queued-click-1')

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'trigger drain' } })
    await Promise.resolve()

    const sendButton = container.querySelector('.send') as HTMLButtonElement
    fireEvent.click(sendButton)

    await waitFor(() => expect(sendKeeperThreadMessage).toHaveBeenCalledTimes(3))
    expect(vi.mocked(sendKeeperThreadMessage).mock.calls[1]?.[1]).toBe('queued one')
    expect(vi.mocked(sendKeeperThreadMessage).mock.calls[2]?.[1]).toBe('queued during drain')
    expect(vi.mocked(sendKeeperThreadMessage).mock.calls[2]?.[2]).toEqual(expect.objectContaining({
      clientActionId: 'queued-click-3',
    }))
    expect(getQueueLength('sangsu')).toBe(0)
  })

  it('drops an aborted queued send instead of requeueing it', async () => {
    vi.mocked(sendKeeperThreadMessage).mockImplementation(async (_keeperName, message) => {
      if (message === 'queued one') throw new DOMException('cancelled', 'AbortError')
    })
    enqueueInput('sangsu', 'queued one', undefined, 'queued-click-1')
    enqueueInput('sangsu', 'queued two', undefined, 'queued-click-2')

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." />`,
      container,
    )
    await Promise.resolve()

    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: 'trigger drain' } })
    await Promise.resolve()

    const sendButton = container.querySelector('.send') as HTMLButtonElement
    fireEvent.click(sendButton)

    await waitFor(() => expect(sendKeeperThreadMessage).toHaveBeenCalledTimes(2))
    expect(vi.mocked(sendKeeperThreadMessage).mock.calls[1]?.[1]).toBe('queued one')
    expect(getQueuedMessages('sangsu').map(msg => msg.content)).toEqual(['queued two'])
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
        onSocialSweep=${() => {}}
      />`,
      container,
    )

    const buttons = Array.from(container.querySelectorAll('button')).map(b => b.textContent?.trim())
    expect(buttons).toContain('점검')
    expect(buttons).toContain('복구')
    expect(buttons).toContain('Social sweep')
    expect(buttons).not.toContain('기동')
    expect(buttons).not.toContain('종료')
  })

  it('falls back to snapshot diagnostic when hydrated detail is absent', async () => {
    const keeper = {
      name: 'sangsu',
      status: 'inactive',
      diagnostic: {
        health_state: 'stale',
        next_action_path: 'recover',
        last_reply_status: 'stale',
        summary: 'Snapshot says the keeper heartbeat is stale.',
      },
    } as any

    render(
      html`<${KeeperDiagnosticSummary} keeper=${keeper} />`,
      container,
    )
    await Promise.resolve()

    expect(container.textContent).toContain('stale')
    expect(container.textContent).toContain('Snapshot says the keeper heartbeat is stale.')
  })
})
