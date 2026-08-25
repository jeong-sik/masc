import { afterEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardWorkspaceMessages: vi.fn(),
}))

vi.mock('./api/dashboard-workspace', () => ({
  fetchDashboardWorkspaceMessages: apiMocks.fetchDashboardWorkspaceMessages,
}))

vi.mock('./sse', () => ({
  journal: {
    log: vi.fn(),
  },
}))

afterEach(() => {
  vi.clearAllMocks()
  vi.resetModules()
})

describe('durable workspace message authority', () => {
  it('does not let a lower-fidelity execution snapshot duplicate or regress it', async () => {
    const durableMessage = {
      id: 'msg-000000007',
      requestId: 'wmsg-0123456789abcdef0123456789abcdef',
      seq: 7,
      from: 'claude',
      content: '@gemini recovered',
      timestamp: '2026-08-14T00:00:00Z',
      type: 'broadcast',
      workspace: 'workspace',
      mentionDelivery: 'accepted' as const,
      mentions: ['gemini'],
    }
    apiMocks.fetchDashboardWorkspaceMessages.mockResolvedValue([durableMessage])

    const store = await import('./store')
    store.serverStatus.value = { project: 'me' }
    await store.refreshDashboardWorkspaceMessages('me')

    store.hydrateExecutionSnapshot({
      status: { project: 'me' },
      messages: [{
        seq: 7,
        from: 'claude',
        content: '@gemini recovered',
        timestamp: '2026-08-14T00:00:00Z',
        type: 'broadcast',
      }],
    })

    expect(store.messages.value).toEqual([durableMessage])
  })
})
