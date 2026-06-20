// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { act } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Keeper } from '../../types'

const mockKeeper: Keeper = {
  name: 'sangsu',
  koreanName: '상수',
  status: 'running',
}

async function loadChat() {
  vi.resetModules()
  vi.doMock('./keeper-workspace-shared', () => ({
    WorkspaceSigil: ({ id }: { id: string }) => html`<span data-testid="kw-sigil">${id}</span>`,
    StatusDot: ({ tone }: { tone: string }) => html`<span data-testid="kw-status-dot" data-tone=${tone}></span>`,
    keeperBucket: () => 'running',
    keeperStatusTone: () => 'ok',
    keeperPhaseLabel: () => '실행 중',
    statePillTone: () => 'run',
  }))
  vi.doMock('../keeper-detail-lifecycle', () => ({
    KeeperLifecycleButtons: () => html`<span data-testid="kw-lifecycle-buttons">Lifecycle</span>`,
  }))
  vi.doMock('../keeper-shared', () => ({
    KeeperConversationPanel: ({ onInspectTurn }: { onInspectTurn?: (entry: unknown) => void }) => html`
      <div data-testid="kw-conversation-panel">
        Conversation
        ${onInspectTurn
          ? html`
              <button
                type="button"
                data-testid="kw-message-turn-action"
                onClick=${() => onInspectTurn({
                  id: 'msg-turn-1',
                  role: 'assistant',
                  source: 'direct_assistant',
                  label: 'sangsu',
                  text: 'done',
                  timestamp: '2026-03-24T00:02:00.000Z',
                  delivery: 'history',
                  turnRef: 'trace-xyz#3',
                })}
              >턴 상세</button>
            `
          : null}
      </div>
    `,
  }))
  vi.doMock('../keeper-turn-inspector', () => ({
    KeeperTurnInspector: ({
      keeperName,
      initialTurnTimestamp,
      initialTurnRef,
    }: {
      keeperName: string
      initialTurnTimestamp?: string | null
      initialTurnRef?: string | null
    }) =>
      html`
        <div
          data-testid="kw-turn-inspector"
          data-keeper=${keeperName}
          data-initial-turn-timestamp=${initialTurnTimestamp ?? ''}
          data-initial-turn-ref=${initialTurnRef ?? ''}
        >TurnInspector</div>
      `,
  }))
  vi.doMock('../../lib/keeper-runtime-display', () => ({
    keeperDisplayStatus: () => 'running',
  }))
  vi.doMock('../../lib/keeper-predicates', () => ({
    keeperActionVisibility: () => ({
      canBoot: false,
      canPause: true,
      canResume: false,
      canShutdown: true,
      canWake: false,
    }),
  }))
  vi.doMock('../keeper-action-panel', () => ({
    runKeeperAction: vi.fn(async () => undefined),
  }))
  vi.doMock('../chat/artifact-panel', () => ({
    ChatArtifactPanel: ({ entries }: { entries: unknown[] }) =>
      html`<div data-testid="kw-artifact-panel" data-artifact-count=${entries.length}>Artifacts</div>`,
  }))
  vi.doMock('../keeper-detail-state', () => ({
    keeperMobilePane: signal<'roster' | 'chat'>('chat'),
  }))
  return import('./keeper-workspace-chat')
}

describe('KeeperWorkspaceChat', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock('./keeper-workspace-shared')
    vi.doUnmock('../keeper-detail-lifecycle')
    vi.doUnmock('../keeper-shared')
    vi.doUnmock('../keeper-turn-inspector')
    vi.doUnmock('../../lib/keeper-runtime-display')
    vi.doUnmock('../../lib/keeper-predicates')
    vi.doUnmock('../keeper-action-panel')
    vi.doUnmock('../chat/artifact-panel')
    vi.doUnmock('../keeper-detail-state')
  })

  it('renders the chat header and conversation panel', async () => {
    const { KeeperWorkspaceChat } = await loadChat()

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
          detailOpen=${false}
          onToggleDetail=${vi.fn()}
          onClear=${vi.fn()}
        />
      `, container)
    })

    expect(container.querySelector('[data-testid="kw-sigil"]')?.textContent).toBe('sangsu')
    expect(container.querySelector('[data-testid="kw-conversation-panel"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="kw-chat-command-turn"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="kw-chat-command-icons"]')).not.toBeNull()
  })

  it('opens the turn inspector drawer when the turn inspector button is clicked', async () => {
    const { KeeperWorkspaceChat } = await loadChat()

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
          detailOpen=${false}
          onToggleDetail=${vi.fn()}
          onClear=${vi.fn()}
        />
      `, container)
    })

    expect(container.querySelector('[data-testid="kw-chat-turn-inspector-drawer"]')).toBeNull()

    const btn = container.querySelector('[data-testid="kw-chat-command-turn"]') as HTMLButtonElement
    await act(async () => {
      btn.click()
    })

    const drawer = container.querySelector('[data-testid="kw-chat-turn-inspector-drawer"]')
    expect(drawer).not.toBeNull()
    expect(container.querySelector('[data-testid="kw-turn-inspector"]')?.getAttribute('data-keeper')).toBe('sangsu')

    const close = container.querySelector('[data-testid="kw-chat-turn-inspector-close"]') as HTMLButtonElement
    await act(async () => {
      close.click()
    })

    expect(container.querySelector('[data-testid="kw-chat-turn-inspector-drawer"]')).toBeNull()
  })

  it('switches the mobile pane to roster when the back button is clicked', async () => {
    const { KeeperWorkspaceChat } = await loadChat()
    const { keeperMobilePane } = await import('../keeper-detail-state')
    keeperMobilePane.value = 'chat'

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
          detailOpen=${false}
          onToggleDetail=${vi.fn()}
          onClear=${vi.fn()}
        />
      `, container)
    })

    const back = container.querySelector('[data-testid="kw-chat-back-to-roster"]') as HTMLButtonElement
    expect(back).not.toBeNull()

    await act(async () => {
      back.click()
    })

    expect(keeperMobilePane.value).toBe('roster')
  })

  it('opens the turn inspector drawer from a message-level turn action', async () => {
    const { KeeperWorkspaceChat } = await loadChat()

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
          detailOpen=${false}
          onToggleDetail=${vi.fn()}
          onClear=${vi.fn()}
        />
      `, container)
    })

    const action = container.querySelector('[data-testid="kw-message-turn-action"]') as HTMLButtonElement
    expect(action).not.toBeNull()

    await act(async () => {
      action.click()
    })

    const drawer = container.querySelector('[data-testid="kw-chat-turn-inspector-drawer"]')
    expect(drawer).not.toBeNull()
    expect(drawer?.textContent).toContain('메시지 sangsu')
    expect(drawer?.textContent).toContain('2026-03-24T00:02:00.000Z')
    expect(container.querySelector('[data-testid="kw-turn-inspector"]')?.getAttribute('data-keeper')).toBe('sangsu')
    expect(container.querySelector('[data-testid="kw-turn-inspector"]')?.getAttribute('data-initial-turn-timestamp')).toBe('2026-03-24T00:02:00.000Z')
    // RFC-0233 §7: the triggered entry's turn_ref flows through to the
    // inspector so it can exact-match the turn instead of the timestamp window.
    expect(container.querySelector('[data-testid="kw-turn-inspector"]')?.getAttribute('data-initial-turn-ref')).toBe('trace-xyz#3')
  })

  it('toggles the artifact panel when the artifacts button is clicked', async () => {
    const { KeeperWorkspaceChat } = await loadChat()

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
          detailOpen=${false}
          onToggleDetail=${vi.fn()}
          onClear=${vi.fn()}
        />
      `, container)
    })

    expect(container.querySelector('[data-testid="kw-artifact-panel"]')).toBeNull()

    const btn = container.querySelector('[data-testid="kw-chat-command-artifacts"]') as HTMLButtonElement
    expect(btn?.getAttribute('aria-label')).toBe('아티팩트')

    await act(async () => {
      btn.click()
    })

    const panel = container.querySelector('[data-testid="kw-artifact-panel"]')
    expect(panel).not.toBeNull()
    expect(btn?.getAttribute('aria-label')).toBe('아티팩트 숨김')
    expect(btn?.getAttribute('aria-pressed')).toBe('true')

    await act(async () => {
      btn.click()
    })

    expect(container.querySelector('[data-testid="kw-artifact-panel"]')).toBeNull()
  })

  it('renders mobile roster and context controls when mobile mode is enabled', async () => {
    const { KeeperWorkspaceChat } = await loadChat()
    const onBack = vi.fn()
    const onOpenRail = vi.fn()
    const onOpenConfig = vi.fn()

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
          detailOpen=${false}
          onToggleDetail=${vi.fn()}
          onClear=${vi.fn()}
          mobile=${true}
          onBack=${onBack}
          onOpenRail=${onOpenRail}
          onOpenConfig=${onOpenConfig}
        />
      `, container)
    })

    const back = container.querySelector('[data-testid="kw-chat-back-to-roster"]') as HTMLButtonElement | null
    const context = container.querySelector('[data-testid="kw-chat-mobile-context"]') as HTMLButtonElement | null
    const menuToggle = container.querySelector('[data-testid="kw-chat-command-menu-toggle"]') as HTMLButtonElement | null

    expect(back).not.toBeNull()
    expect(back?.getAttribute('aria-label')).toBe('키퍼 로스터로 돌아가기')
    expect(context).not.toBeNull()
    expect(menuToggle).not.toBeNull()
    expect(container.querySelector('[data-testid="kw-chat-command-config"]')).toBeNull()

    await act(async () => {
      back?.click()
      context?.click()
      menuToggle?.click()
    })

    expect(onBack).toHaveBeenCalledTimes(1)
    expect(onOpenRail).toHaveBeenCalledTimes(1)
    expect(container.querySelector('[data-testid="kw-chat-command-config"]')).not.toBeNull()

    await act(async () => {
      ;(container.querySelector('[data-testid="kw-chat-command-config"]') as HTMLButtonElement).click()
    })

    expect(onOpenConfig).toHaveBeenCalledTimes(1)
  })
})
