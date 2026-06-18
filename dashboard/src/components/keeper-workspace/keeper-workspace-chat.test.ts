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
    KeeperConversationPanel: () => html`<div data-testid="kw-conversation-panel">Conversation</div>`,
  }))
  vi.doMock('../keeper-turn-inspector', () => ({
    KeeperTurnInspector: ({ keeperName }: { keeperName: string }) =>
      html`<div data-testid="kw-turn-inspector" data-keeper=${keeperName}>TurnInspector</div>`,
  }))
  vi.doMock('../../lib/keeper-runtime-display', () => ({
    keeperDisplayStatus: () => 'running',
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
    expect(container.querySelector('[data-testid="kw-chat-turn-inspector-btn"]')).not.toBeNull()
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

    const btn = container.querySelector('[data-testid="kw-chat-turn-inspector-btn"]') as HTMLButtonElement
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

    const btn = container.querySelector('[data-testid="kw-chat-artifacts-toggle"]') as HTMLButtonElement
    expect(btn?.textContent?.trim()).toBe('아티팩트')

    await act(async () => {
      btn.click()
    })

    const panel = container.querySelector('[data-testid="kw-artifact-panel"]')
    expect(panel).not.toBeNull()
    expect(btn?.textContent?.trim()).toBe('아티팩트 숨김')

    await act(async () => {
      btn.click()
    })

    expect(container.querySelector('[data-testid="kw-artifact-panel"]')).toBeNull()
  })
})
