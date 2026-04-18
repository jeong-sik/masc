import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { bootKeeper, shutdownKeeper } = vi.hoisted(() => ({
  bootKeeper: vi.fn(),
  shutdownKeeper: vi.fn(),
}))

const { invalidateDashboardCache, refreshDashboard } = vi.hoisted(() => ({
  invalidateDashboardCache: vi.fn(),
  refreshDashboard: vi.fn(async () => undefined),
}))

vi.mock('../keeper-runtime', async () => {
  const { signal } = await import('@preact/signals')
  return {
    abortKeeperThreadMessage: vi.fn(),
    hydrateKeeperStatus: vi.fn(async () => null),
    loadFullKeeperHistory: vi.fn(async () => null),
    keeperActionErrors: signal({}),
    keeperHydrating: signal({}),
    keeperProbing: signal({}),
    keeperRecovering: signal({}),
    keeperSending: signal({}),
    keeperStatusDetails: signal({}),
    keeperStreamStartedAt: signal({}),
    keeperThreads: signal({}),
    probeKeeperRuntime: vi.fn(),
    recoverKeeperRuntime: vi.fn(),
    sendKeeperThreadMessage: vi.fn(async () => null),
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

import { keeperActionErrors, keeperHydrating, keeperSending, keeperStreamStartedAt, keeperThreads } from '../keeper-runtime'
import { keeperStatusDetails } from '../keeper-runtime'
import { hydrateKeeperStatus } from '../keeper-runtime'
import { shellAuthSummary } from '../store'
import { KeeperConversationPanel, KeeperDiagnosticSummary, KeeperRuntimeActions } from './keeper-shared'

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
  })

  afterEach(() => {
    render(null, container)
    container.remove()
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
    expect(container.textContent).toContain('메타데이터 표시')
    expect(container.textContent).toContain('내부 메시지 숨김')
    expect(container.textContent).toContain('## Current World State')
    expect(container.textContent).not.toContain('Conversation Lane')
    expect(container.textContent).not.toContain('Visible thread')
    expect(container.textContent).not.toContain('Hidden internal')
    expect(container.textContent).not.toContain('Lane state')
    expect(container.querySelector('[data-chat-variant="messenger"]')).not.toBeNull()
    expect(container.querySelector('textarea')?.getAttribute('placeholder')).toBe('메시지 입력...')
    expect(hydrateKeeperStatus).not.toHaveBeenCalled()
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
    expect(buttons).toContain('Probe')
    expect(buttons).toContain('Recover')
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
