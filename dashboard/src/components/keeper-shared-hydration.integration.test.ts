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
import { _resetChatHydrationForTests, hydrateKeeperChatHistory } from '../keeper-actions'
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

  it('keeps simultaneous live panel hydration isolated by keeper', async () => {
    const consoleWarn = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    fetchKeeperChatHistory.mockImplementation(async (keeperName: string) => {
      if (keeperName === 'alpha') {
        return [
          {
            id: 'tool-history-alpha-scope',
            role: 'tool',
            content: '{}',
            ts: 1_783_267_221,
            tool_call_id: 'tc-alpha-scope',
            tool_call_name: 'keeper_context_status',
            source: 'dashboard',
            turn_ref: 'trace-alpha-scope#1',
          },
          {
            id: 'assistant-history-alpha-scope',
            role: 'assistant',
            content: 'alpha 도구 출력 조인이 완료되었습니다.',
            ts: 1_783_267_222,
            source: 'dashboard',
            turn_ref: 'trace-alpha-scope#1',
            stream_contract: {
              source: 'sse_event',
              status: 'backend_terminal_event',
              event_name: 'RUN_FINISHED',
              delivery_receipt: 'client_observed_sse_event',
            },
          },
        ]
      }
      if (keeperName === 'beta') {
        return [
          {
            id: 'tool-history-beta-scope',
            role: 'tool',
            content: '{}',
            ts: 1_783_267_231,
            tool_call_id: 'tc-beta-scope',
            tool_call_name: 'keeper_context_status',
            source: 'dashboard',
            turn_ref: 'trace-beta-scope#1',
          },
          {
            id: 'assistant-history-beta-scope',
            role: 'assistant',
            content: 'beta 도구 출력은 아직 조인되지 않았습니다.',
            ts: 1_783_267_232,
            source: 'dashboard',
            turn_ref: 'trace-beta-scope#1',
            stream_contract: {
              source: 'sse_event',
              status: 'backend_terminal_event',
              event_name: 'RUN_FINISHED',
              delivery_receipt: 'client_observed_sse_event',
            },
          },
        ]
      }
      throw new Error(`unexpected keeper ${keeperName}`)
    })
    fetchKeeperToolCalls.mockImplementation(async (keeperName?: string) => {
      if (keeperName === 'alpha') {
        return {
          entries: [
            {
              ts: 1_783_267_221,
              keeper: 'alpha',
              tool: 'keeper_context_status',
              input: {},
              output: 'alpha output joined from tool_calls_endpoint',
              success: true,
              duration_ms: 31,
              tool_use_id: 'tc-alpha-scope',
            },
          ],
        }
      }
      if (keeperName === 'beta') {
        throw new Error('HTTP 503 beta')
      }
      throw new Error(`unexpected keeper ${keeperName}`)
    })

    render(
      html`
        <div>
          <section data-testid="alpha-panel">
            <${KeeperConversationPanel} keeperName="alpha" placeholder="alpha message" layout="workspace" />
          </section>
          <section data-testid="beta-panel">
            <${KeeperConversationPanel} keeperName="beta" placeholder="beta message" layout="workspace" />
          </section>
        </div>
      `,
      container,
    )

    await waitFor(() => {
      expect(fetchKeeperChatHistory).toHaveBeenCalledWith('alpha')
      expect(fetchKeeperChatHistory).toHaveBeenCalledWith('beta')
      expect(fetchKeeperToolCalls).toHaveBeenCalledWith('alpha', 200)
      expect(fetchKeeperToolCalls).toHaveBeenCalledWith('beta', 200)
    })
    await waitFor(() => {
      expect(toolCallOutputHydrationStatus('alpha')).toBe('hydrated')
      expect(toolCallOutputHydrationFailureReason('alpha')).toBeNull()
      expect(toolCallOutputHydrationStatus('beta')).toBe('failed')
      expect(toolCallOutputHydrationFailureReason('beta')).toBe('HTTP 503 beta')
      expect(lookupToolCallOutput('tool-tc-alpha-scope')?.output).toBe(
        'alpha output joined from tool_calls_endpoint',
      )
      expect(lookupToolCallOutput('tool-tc-beta-scope')).toBeNull()
    })

    const alphaPanel = container.querySelector('[data-testid="alpha-panel"]') as HTMLElement
    const betaPanel = container.querySelector('[data-testid="beta-panel"]') as HTMLElement
    const alphaCoveredThrough = toolCallOutputsCoveredThroughMs('alpha')

    await waitFor(() => {
      const alphaTrace = alphaPanel.querySelector('[data-chat-work-trace]')
      expect(alphaTrace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('hydrated')
      expect(alphaTrace?.getAttribute('data-chat-tool-output-hydration-failure')).toBeNull()
      expect(alphaTrace?.getAttribute('data-chat-tool-output-covered-since')).toBe('1783267221000')
      expect(alphaTrace?.getAttribute('data-chat-tool-output-covered-through')).toBe(String(alphaCoveredThrough))
      expect(alphaTrace?.getAttribute('data-chat-turn-stream-contract-event')).toBe('RUN_FINISHED')

      const betaTrace = betaPanel.querySelector('[data-chat-work-trace]')
      expect(betaTrace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('failed')
      expect(betaTrace?.getAttribute('data-chat-tool-output-hydration-failure')).toBe('HTTP 503 beta')
      expect(betaTrace?.getAttribute('data-chat-tool-output-covered-since')).toBeNull()
      expect(betaTrace?.getAttribute('data-chat-tool-output-covered-through')).toBeNull()
      expect(betaTrace?.getAttribute('data-chat-turn-stream-contract-event')).toBe('RUN_FINISHED')

      const alphaStep = alphaPanel.querySelector(
        '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-alpha-scope"]',
      ) as HTMLElement
      expect(alphaStep.getAttribute('data-chat-trace-link-state')).toBe('joined')
      expect(alphaStep.getAttribute('data-chat-trace-output-state')).toBe('ok')
      expect(alphaStep.getAttribute('data-chat-trace-output-coverage')).toBe('covered')
      expect(alphaStep.querySelector('.chat-block-tstep-status.ok')).not.toBeNull()

      const betaStep = betaPanel.querySelector(
        '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-beta-scope"]',
      ) as HTMLElement
      expect(betaStep.getAttribute('data-chat-trace-link-state')).toBe('joined')
      expect(betaStep.getAttribute('data-chat-trace-output-state')).toBe('hydration-failed')
      expect(betaStep.getAttribute('data-chat-trace-output-coverage')).toBe('hydration-failed')
      expect(betaStep.querySelector('.chat-block-tstep-status.hydration-failed')).not.toBeNull()
      expect(betaStep.querySelector('.chat-block-tstep-status.ok')).toBeNull()
      expect(betaPanel.textContent).toContain('출력 hydration 실패 1')
      expect(betaPanel.textContent).not.toContain('alpha output joined from tool_calls_endpoint')
    })

    const alphaStep = alphaPanel.querySelector(
      '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-alpha-scope"]',
    ) as HTMLElement
    const betaStep = betaPanel.querySelector(
      '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-beta-scope"]',
    ) as HTMLElement

    fireEvent.click(alphaStep.querySelector('.chat-block-tstep-row') as HTMLElement)
    fireEvent.click(betaStep.querySelector('.chat-block-tstep-row') as HTMLElement)

    await waitFor(() => {
      expect(alphaStep.textContent).toContain('alpha output joined from tool_calls_endpoint')
      expect(alphaStep.textContent).not.toContain('HTTP 503 beta')
      expect(betaStep.textContent).toContain('출력 hydration 실패 — HTTP 503 beta')
      expect(betaStep.textContent).not.toContain('alpha output joined from tool_calls_endpoint')
      expect(betaStep.textContent).not.toContain('result')
    })

    consoleWarn.mockRestore()
  })

  it('recovers stale hydration-failed DOM after a forced live refresh succeeds', async () => {
    const consoleWarn = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    const recoveryHistory = [
      {
        id: 'tool-history-refresh-recovery',
        role: 'tool',
        content: '{}',
        ts: 1_783_267_241,
        tool_call_id: 'tc-refresh-recovery',
        tool_call_name: 'keeper_context_status',
        source: 'dashboard',
        turn_ref: 'trace-refresh-recovery#1',
      },
      {
        id: 'assistant-history-refresh-recovery',
        role: 'assistant',
        content: 'force refresh 이후 도구 출력 조인이 복구되었습니다.',
        ts: 1_783_267_242,
        source: 'dashboard',
        turn_ref: 'trace-refresh-recovery#1',
        stream_contract: {
          source: 'sse_event',
          status: 'backend_terminal_event',
          event_name: 'RUN_FINISHED',
          delivery_receipt: 'client_observed_sse_event',
        },
      },
    ]
    fetchKeeperChatHistory.mockResolvedValueOnce(recoveryHistory)
    fetchKeeperToolCalls.mockRejectedValueOnce(new Error('HTTP 504 first refresh'))

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
      expect(toolCallOutputHydrationFailureReason('sangsu')).toBe('HTTP 504 first refresh')
    })

    let step = container.querySelector(
      '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-refresh-recovery"]',
    ) as HTMLElement
    fireEvent.click(step.querySelector('.chat-block-tstep-row') as HTMLElement)
    await waitFor(() => {
      expect(step.getAttribute('data-chat-trace-output-state')).toBe('hydration-failed')
      expect(step.getAttribute('data-chat-trace-output-coverage')).toBe('hydration-failed')
      expect(step.textContent).toContain('출력 hydration 실패 — HTTP 504 first refresh')
      expect(container.textContent).toContain('출력 hydration 실패 1')
    })

    fetchKeeperChatHistory.mockResolvedValueOnce(recoveryHistory)
    fetchKeeperToolCalls.mockResolvedValueOnce({
      entries: [
        {
          ts: 1_783_267_241,
          keeper: 'sangsu',
          tool: 'keeper_context_status',
          input: {},
          output: 'recovered output joined from forced refresh',
          success: true,
          duration_ms: 37,
          tool_use_id: 'tc-refresh-recovery',
        },
      ],
    })

    await hydrateKeeperChatHistory('sangsu', { force: true })

    await waitFor(() => {
      expect(fetchKeeperChatHistory).toHaveBeenCalledTimes(2)
      expect(fetchKeeperToolCalls).toHaveBeenCalledTimes(2)
      expect(toolCallOutputHydrationStatus('sangsu')).toBe('hydrated')
      expect(toolCallOutputHydrationFailureReason('sangsu')).toBeNull()
      expect(lookupToolCallOutput('tool-tc-refresh-recovery')?.output).toBe(
        'recovered output joined from forced refresh',
      )
      expect(toolCallOutputsCoveredSinceMs('sangsu')).toBe(1_783_267_241_000)
      expect(toolCallOutputsCoveredThroughMs('sangsu')).not.toBeNull()
    })

    const coveredThrough = toolCallOutputsCoveredThroughMs('sangsu')
    await waitFor(() => {
      const trace = container.querySelector('[data-chat-work-trace]')
      expect(trace?.getAttribute('data-chat-tool-output-hydration-status')).toBe('hydrated')
      expect(trace?.getAttribute('data-chat-tool-output-hydration-failure')).toBeNull()
      expect(trace?.getAttribute('data-chat-tool-output-covered-since')).toBe('1783267241000')
      expect(trace?.getAttribute('data-chat-tool-output-covered-through')).toBe(String(coveredThrough))
      expect(trace?.getAttribute('data-chat-turn-stream-contract-event')).toBe('RUN_FINISHED')

      step = container.querySelector(
        '[data-chat-trace-step="tool"][data-chat-trace-tool-call-id="tc-refresh-recovery"]',
      ) as HTMLElement
      expect(step.getAttribute('data-chat-trace-link-state')).toBe('joined')
      expect(step.getAttribute('data-chat-trace-output-state')).toBe('ok')
      expect(step.getAttribute('data-chat-trace-output-coverage')).toBe('covered')
      expect(step.querySelector('.chat-block-tstep-status.ok')).not.toBeNull()
      expect(step.querySelector('.chat-block-tstep-status.hydration-failed')).toBeNull()
      expect(container.textContent).not.toContain('출력 hydration 실패 1')
      expect(container.textContent).not.toContain('HTTP 504 first refresh')
      expect(container.textContent).not.toContain('출력 대기 중')
      expect(container.textContent).not.toContain('결과 없음')
    })

    await waitFor(() => {
      expect(step.textContent).toContain('result')
      expect(step.textContent).toContain('recovered output joined from forced refresh')
      expect(step.textContent).not.toContain('출력 hydration 실패')
      expect(step.textContent).not.toContain('HTTP 504 first refresh')
      expect(step.textContent).not.toContain('출력 tail 범위 밖')
    })

    consoleWarn.mockRestore()
  })
})
