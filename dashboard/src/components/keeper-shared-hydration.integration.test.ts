// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ToolCallEntry } from '../api/dashboard'

const {
  cancelQueuedKeeperMessage,
  fetchKeeperChatHistory,
  fetchQueuedKeeperMessageResult,
  isTerminalQueuedKeeperMessage,
  queuedKeeperMessageError,
  queuedKeeperMessageToReply,
  streamKeeperMessage,
} = vi.hoisted(() => ({
  cancelQueuedKeeperMessage: vi.fn(async () => undefined),
  fetchKeeperChatHistory: vi.fn(),
  fetchQueuedKeeperMessageResult: vi.fn(),
  isTerminalQueuedKeeperMessage: vi.fn((result: { status: string }) => result.status === 'done'),
  queuedKeeperMessageError: vi.fn((result: { status: string }) => `request ${result.status}`),
  queuedKeeperMessageToReply: vi.fn((result: { result?: { reply?: string } }) => ({
    text: result.result?.reply ?? '(empty reply)',
    details: null,
  })),
  streamKeeperMessage: vi.fn(),
}))

const { fetchKeeperToolCalls } = vi.hoisted(() => ({
  fetchKeeperToolCalls: vi.fn(async (): Promise<{ entries: ToolCallEntry[] }> => ({ entries: [] })),
}))

vi.mock('../api/keeper', () => ({
  cancelQueuedKeeperMessage,
  fetchKeeperChatHistory,
  fetchQueuedKeeperMessageResult,
  isTerminalQueuedKeeperMessage,
  queuedKeeperMessageError,
  queuedKeeperMessageToReply,
  streamKeeperMessage,
}))

vi.mock('../api/dashboard', () => ({ fetchKeeperToolCalls }))
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
  lookupToolCallOutput,
  resetToolCallOutputs,
  toolCallOutputHydrationFailureReason,
  toolCallOutputHydrationStatus,
  toolCallOutputsCoveredSinceMs,
  toolCallOutputsCoveredThroughMs,
} from '../tool-call-output-store'
import { _clearPendingKeeperChatRequestsForTests } from '../keeper-chat-pending'
import { _resetChatStoreForTests } from '../keeper-chat-store'
import { keeperCatchupDigests } from '../keeper-digest-signals'

describe('KeeperConversationPanel hydration wiring', () => {
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
    keeperCatchupDigests.value = {}
    _resetChatHydrationForTests()
    _clearPendingKeeperChatRequestsForTests()
    _resetChatStoreForTests()
    resetToolCallOutputs()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.unstubAllGlobals()
    _resetChatHydrationForTests()
    _clearPendingKeeperChatRequestsForTests()
    _resetChatStoreForTests()
    resetToolCallOutputs()
  })

  it('drives live transcript hydration-failed DOM from a real tool-call endpoint failure', async () => {
    const consoleWarn = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    fetchKeeperChatHistory.mockResolvedValueOnce([
      {
        id: 'tool-history-api-hydration',
        role: 'tool',
        content: '{}',
        ts: 1_783_267_201,
        tool_call_id: 'tc-api-hydration',
        tool_call_name: 'keeper_context_status',
        source: 'dashboard',
        turn_ref: 'trace-api-hydration#1',
      },
      {
        id: 'assistant-history-api-hydration',
        role: 'assistant',
        content: '도구 출력을 확인했습니다.',
        ts: 1_783_267_202,
        source: 'dashboard',
        turn_ref: 'trace-api-hydration#1',
        stream_contract: {
          source: 'sse_event',
          status: 'backend_terminal_event',
          event_name: 'RUN_FINISHED',
          delivery_receipt: 'client_observed_sse_event',
        },
      },
    ])
    fetchKeeperToolCalls.mockRejectedValueOnce(new Error('HTTP 502'))

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." layout="workspace" />`,
      container,
    )

    await waitFor(() => {
      expect(fetchKeeperChatHistory).toHaveBeenCalledWith('sangsu')
      expect(fetchKeeperToolCalls).toHaveBeenCalledWith('sangsu', 200)
    })
    await waitFor(() => {
      expect(toolCallOutputHydrationStatus('sangsu')).toBe('failed')
      expect(toolCallOutputHydrationFailureReason('sangsu')).toBe('HTTP 502')
    })

    const traceSelector =
      '[data-chat-work-trace][data-chat-tool-output-hydration-source="tool_calls_endpoint"]'
    await waitFor(() => {
      const trace = container.querySelector(traceSelector)
      expect(trace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('failed')
      expect(trace?.getAttribute('data-chat-tool-output-hydration-failure')).toBe('HTTP 502')
      expect(trace?.getAttribute('data-chat-turn-stream-contract-source')).toBe('sse_event')
      expect(trace?.getAttribute('data-chat-turn-stream-contract-event')).toBe('RUN_FINISHED')

      const step = container.querySelector(
        '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-api-hydration"]',
      ) as HTMLElement
      expect(step.getAttribute('data-chat-trace-output-state')).toBe('hydration-failed')
      expect(step.getAttribute('data-chat-trace-output-coverage')).toBe('hydration-failed')
      expect(container.textContent).toContain('출력 hydration 실패 1')
    })

    const failedStep = container.querySelector(
      '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-api-hydration"]',
    ) as HTMLElement
    fireEvent.click(failedStep.querySelector('.chat-block-tstep-row') as HTMLElement)

    await waitFor(() => {
      expect(failedStep.textContent).toContain('출력 hydration 실패 — HTTP 502')
    })

    consoleWarn.mockRestore()
  })

  it('joins successful tool-call endpoint output into the live transcript DOM', async () => {
    fetchKeeperChatHistory.mockResolvedValueOnce([
      {
        id: 'tool-history-api-success',
        role: 'tool',
        content: '{}',
        ts: 1_783_267_211,
        tool_call_id: 'tc-api-success',
        tool_call_name: 'keeper_context_status',
        source: 'dashboard',
        turn_ref: 'trace-api-success#1',
      },
      {
        id: 'assistant-history-api-success',
        role: 'assistant',
        content: '도구 출력 조인이 완료되었습니다.',
        ts: 1_783_267_212,
        source: 'dashboard',
        turn_ref: 'trace-api-success#1',
        stream_contract: {
          source: 'sse_event',
          status: 'backend_terminal_event',
          event_name: 'RUN_FINISHED',
          delivery_receipt: 'client_observed_sse_event',
        },
      },
    ])
    fetchKeeperToolCalls.mockResolvedValueOnce({
      entries: [
        {
          ts: 1_783_267_211,
          keeper: 'sangsu',
          tool: 'keeper_context_status',
          input: {},
          output: 'context status joined from tool_calls_endpoint',
          success: true,
          duration_ms: 42,
          tool_use_id: 'tc-api-success',
        },
      ],
    })

    render(
      html`<${KeeperConversationPanel} keeperName="sangsu" placeholder="메시지 입력..." layout="workspace" />`,
      container,
    )

    await waitFor(() => {
      expect(fetchKeeperChatHistory).toHaveBeenCalledWith('sangsu')
      expect(fetchKeeperToolCalls).toHaveBeenCalledWith('sangsu', 200)
    })
    await waitFor(() => {
      expect(toolCallOutputHydrationStatus('sangsu')).toBe('hydrated')
      expect(toolCallOutputHydrationFailureReason('sangsu')).toBeNull()
      expect(lookupToolCallOutput('tool-tc-api-success')?.output).toBe(
        'context status joined from tool_calls_endpoint',
      )
      expect(toolCallOutputsCoveredSinceMs('sangsu')).toBe(1_783_267_211_000)
      expect(toolCallOutputsCoveredThroughMs('sangsu')).not.toBeNull()
    })

    const coveredThrough = toolCallOutputsCoveredThroughMs('sangsu')
    const traceSelector =
      '[data-chat-work-trace][data-chat-tool-output-hydration-source="tool_calls_endpoint"]'
    await waitFor(() => {
      const trace = container.querySelector(traceSelector)
      expect(trace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('hydrated')
      expect(trace?.getAttribute('data-chat-tool-output-hydration-failure')).toBeNull()
      expect(trace?.getAttribute('data-chat-tool-output-covered-since')).toBe('1783267211000')
      expect(trace?.getAttribute('data-chat-tool-output-covered-through')).toBe(String(coveredThrough))
      expect(trace?.getAttribute('data-chat-turn-stream-contract-source')).toBe('sse_event')
      expect(trace?.getAttribute('data-chat-turn-stream-contract-event')).toBe('RUN_FINISHED')

      const step = container.querySelector(
        '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-api-success"]',
      ) as HTMLElement
      expect(step.getAttribute('data-chat-trace-link-state')).toBe('joined')
      expect(step.getAttribute('data-chat-trace-output-state')).toBe('ok')
      expect(step.getAttribute('data-chat-trace-output-coverage')).toBe('covered')
      expect(step.querySelector('.chat-block-tstep-status.ok')).not.toBeNull()
      expect(step.querySelector('.chat-block-tstep-status.missing')).toBeNull()
      expect(step.querySelector('.chat-block-tstep-status.hydration-failed')).toBeNull()
      expect(container.textContent).not.toContain('결과 누락 1')
      expect(container.textContent).not.toContain('출력 범위 밖 1')
      expect(container.textContent).not.toContain('출력 hydration 실패 1')
    })

    const joinedStep = container.querySelector(
      '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-api-success"]',
    ) as HTMLElement
    fireEvent.click(joinedStep.querySelector('.chat-block-tstep-row') as HTMLElement)

    await waitFor(() => {
      expect(joinedStep.textContent).toContain('result')
      expect(joinedStep.textContent).toContain('context status joined from tool_calls_endpoint')
      expect(joinedStep.textContent).not.toContain('출력 대기 중')
      expect(joinedStep.textContent).not.toContain('결과 없음')
      expect(joinedStep.textContent).not.toContain('출력 hydration 실패')
      expect(joinedStep.textContent).not.toContain('출력 tail 범위 밖')
    })
  })
})
