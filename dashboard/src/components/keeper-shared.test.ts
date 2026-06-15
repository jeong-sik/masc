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
    hydrateKeeperChatHistory: vi.fn(async () => undefined),
    loadFullKeeperHistory: vi.fn(async () => null),
    keeperActionErrors: signal({}),
    keeperHydrating: signal({}),
    keeperProbing: signal({}),
    keeperRecovering: signal({}),
    keeperSending: signal({}),
    keeperStatusDetails: signal({}),
    keeperStreamStartedAt: signal({}),
    keeperStreamLastEventAt: signal({}),
    keeperThreads: signal({}),
    probeKeeperRuntime: vi.fn(),
    recoverKeeperRuntime: vi.fn(),
    resumePendingKeeperChatRequests: vi.fn(async () => undefined),
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
    expect(container.querySelector('.min-h-30')).not.toBeNull()
    expect(container.textContent).toContain('@sangsu')
    expect(container.textContent).not.toContain('Enter로 전송')
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

    // The former secondary KeeperChatPanel owned search + attachments;
    // after unification the shared panel must expose both.
    expect(container.querySelector('[data-chat-attach-button]')).not.toBeNull()
    expect(container.querySelector('input[name="keeper_chat_search"]')).not.toBeNull()
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
