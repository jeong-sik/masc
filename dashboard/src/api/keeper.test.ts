import { afterEach, describe, expect, it, vi } from 'vitest'

const { runOperatorAction, currentDashboardActor, callMcpTool } = vi.hoisted(() => ({
  runOperatorAction: vi.fn(),
  currentDashboardActor: vi.fn(() => 'dashboard'),
  callMcpTool: vi.fn(),
}))

vi.mock('./core', () => ({
  currentDashboardActor,
  runOperatorAction,
}))

vi.mock('./mcp', () => ({
  callMcpTool,
}))

import { sendKeeperMessageDetailed, streamKeeperMessage } from './keeper'

afterEach(() => {
  vi.clearAllMocks()
  vi.unstubAllGlobals()
  try {
    window.localStorage?.removeItem?.('masc_dashboard_agent_name')
  } catch {
    // Ignore storage cleanup failures in the test environment.
  }
})

describe('sendKeeperMessageDetailed', () => {
  it('forces direct reply mode for operator-mediated direct chats', async () => {
    runOperatorAction.mockResolvedValueOnce({
      result: {
        reply: 'pong',
        model_used: 'test-model',
      },
    })

    const reply = await sendKeeperMessageDetailed('sangsu', 'ping')

    expect(currentDashboardActor).toHaveBeenCalled()
    expect(runOperatorAction).toHaveBeenCalledWith({
      actor: 'dashboard',
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'sangsu',
      payload: {
        message: 'ping',
        direct_reply: true,
        timeout_sec: 120,
      },
    })
    expect(reply.text).toBe('pong')
  })

  it('forces direct reply mode for raw keeper tool calls', async () => {
    callMcpTool.mockResolvedValueOnce(JSON.stringify({ reply: 'pong' }))

    const reply = await sendKeeperMessageDetailed('sangsu', 'ping')

    expect(callMcpTool).toHaveBeenCalledWith('masc_keeper_msg', {
      name: 'sangsu',
      message: 'ping',
      direct_reply: true,
      timeout_sec: 120,
    })
    expect(reply.text).toBe('pong')
  })
})

describe('streamKeeperMessage', () => {
  it('posts direct reply mode to the keeper chat stream endpoint', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('data: {"type":"RUN_FINISHED"}\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const events: string[] = []
    await streamKeeperMessage('sangsu', 'ping', {
      onEvent: event => {
        events.push(event.type)
      },
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toEqual({
      name: 'sangsu',
      message: 'ping',
      direct_reply: true,
      timeout_sec: 120,
    })
    expect(events).toEqual(['RUN_FINISHED'])
  })
})
