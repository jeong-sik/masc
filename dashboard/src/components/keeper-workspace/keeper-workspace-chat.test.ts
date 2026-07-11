// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { act, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardGovernanceResponse, Keeper, KeeperApprovalQueueItem } from '../../types'

const mockKeeper: Keeper = {
  name: 'sangsu',
  koreanName: '상수',
  status: 'running',
}

// The pending-approval cue reads the governance approval_queue (the HITL SSOT)
// via governanceData — NOT keeper.trust.approval_state (#23678). Tests drive the
// cue by setting this signal, which loadChat() injects in place of the real
// computed. Reset in beforeEach so it never leaks across cases.
const mockGovernanceData = signal<DashboardGovernanceResponse | undefined>(undefined)

function approvalItem(id: string, keeperName: string, toolName: string): KeeperApprovalQueueItem {
  return {
    id,
    keeper_name: keeperName,
    tool_name: toolName,
    risk_level: 'critical',
    waiting_s: 10,
    input_preview: 'x',
    task_id: 'T-1',
  } as KeeperApprovalQueueItem
}

function governanceResponse(queue: KeeperApprovalQueueItem[]): DashboardGovernanceResponse {
  return {
    generated_at: '2026-07-08T00:00:00Z',
    summary: { judge_online: false },
    items: [],
    activity: [],
    judgments: [],
    pending_actions: [],
    approval_queue: queue,
  } as DashboardGovernanceResponse
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
    KeeperConversationPanel: ({ onInspectTurn, workspaceToolbarOpen }: { onInspectTurn?: (entry: unknown) => void; workspaceToolbarOpen?: boolean }) => html`
      <div data-testid="kw-conversation-panel" data-toolbar-open=${workspaceToolbarOpen ? 'true' : 'false'}>
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
    }: {
      keeperName: string
      initialTurnTimestamp?: string | null
    }) =>
      html`
        <div
          data-testid="kw-turn-inspector"
          data-keeper=${keeperName}
          data-initial-turn-timestamp=${initialTurnTimestamp ?? ''}
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
  vi.doMock('../keeper-action-panel', async (importOriginal) => ({
    // Keep the real KEEPER_ACTION_LABELS (label/icon/title SSOT); only the
    // side-effecting action runner is stubbed.
    ...(await importOriginal<typeof import('../keeper-action-panel')>()),
    runKeeperAction: vi.fn(async () => undefined),
  }))
  vi.doMock('../keeper-detail-state', () => ({
    keeperMobilePane: signal<'roster' | 'chat'>('chat'),
  }))
  // Preserve the real router but capture navigate() so the compact approval
  // badge link can be asserted.
  vi.doMock('../../router', async (importOriginal) => ({
    ...(await importOriginal<typeof import('../../router')>()),
    navigate: vi.fn(),
  }))
  // The badge reads governanceData.approval_queue; inject a controllable signal in
  // place of the real computed so a test can populate the queue directly.
  vi.doMock('../governance-signals', async (importOriginal) => ({
    ...(await importOriginal<typeof import('../governance-signals')>()),
    governanceData: mockGovernanceData,
  }))
  return import('./keeper-workspace-chat')
}

describe('KeeperWorkspaceChat', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mockGovernanceData.value = undefined
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    mockGovernanceData.value = undefined
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
    vi.doUnmock('../keeper-detail-state')
    vi.doUnmock('../../router')
    vi.doUnmock('../governance-signals')
  })

  it('links the compact pending-approval header badge to the approvals queue', async () => {
    const { KeeperWorkspaceChat } = await loadChat()
    const { navigate } = await import('../../router')
    // The badge derives from the governance approval_queue (HITL SSOT), not
    // keeper.trust.approval_state (#23678).
    mockGovernanceData.value = governanceResponse([approvalItem('appr-1', 'sangsu', 'fs_write')])

    await act(async () => {
      render(html`<${KeeperWorkspaceChat} keeper=${mockKeeper} />`, container)
    })

    const queueLink = container.querySelector('[data-testid="keeper-pending-approval-link"]') as HTMLButtonElement
    expect(queueLink).not.toBeNull()
    expect(queueLink.textContent).toContain('1')
    expect(queueLink.getAttribute('aria-label')).toContain('결재 대기 1건')
    expect(container.querySelector('[data-testid="keeper-pending-approval-cue"]')).toBeNull()
    await act(async () => {
      queueLink.click()
    })
    expect(navigate).toHaveBeenCalledWith('approvals')
  })

  it('hides the pending-approval badge when the keeper has no pending decision', async () => {
    const { KeeperWorkspaceChat } = await loadChat()

    await act(async () => {
      render(html`<${KeeperWorkspaceChat} keeper=${mockKeeper} />`, container)
    })

    expect(container.querySelector('[data-testid="keeper-pending-approval-link"]')).toBeNull()
  })

  it('renders the chat header and conversation panel', async () => {
    const { KeeperWorkspaceChat } = await loadChat()

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
        />
      `, container)
    })

    expect(container.querySelector('[data-testid="kw-sigil"]')?.textContent).toBe('sangsu')
    expect(container.querySelector('[data-testid="kw-conversation-panel"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="kw-chat-command-icons"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="kw-chat-command-config"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="kw-chat-command-search"]')).toBeNull()
    expect(container.querySelector('[data-testid="kw-conversation-panel"]')?.getAttribute('data-toolbar-open')).toBe('false')

    await act(async () => {
      ;(container.querySelector('[data-testid="kw-chat-command-menu-toggle"]') as HTMLButtonElement).click()
    })
    expect(container.querySelector('[data-testid="kw-chat-command-turn"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="kw-chat-command-artifacts"]')).not.toBeNull()
    const search = container.querySelector('[data-testid="kw-chat-command-search"]') as HTMLButtonElement
    expect(search).not.toBeNull()
    await act(async () => {
      search.click()
    })
    expect(container.querySelector('[data-testid="kw-conversation-panel"]')?.getAttribute('data-toolbar-open')).toBe('true')
  })

  it('keeps utility commands usable while a lifecycle command is pending', async () => {
    const { KeeperWorkspaceChat } = await loadChat()
    const { runKeeperAction } = await import('../keeper-action-panel')
    let resolveAction: () => void = () => {}
    vi.mocked(runKeeperAction).mockImplementationOnce(async () => new Promise<void>(resolve => {
      resolveAction = resolve
    }))

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
        />
      `, container)
    })

    const pause = container.querySelector('[data-testid="kw-chat-command-pause"]') as HTMLButtonElement
    const menuToggle = container.querySelector('[data-testid="kw-chat-command-menu-toggle"]') as HTMLButtonElement
    expect(pause).not.toBeNull()
    expect(menuToggle).not.toBeNull()

    await act(async () => {
      pause.click()
      await Promise.resolve()
    })

    expect(runKeeperAction).toHaveBeenCalledWith('sangsu', 'pause')
    expect(pause.disabled).toBe(true)
    await act(async () => {
      menuToggle.click()
    })
    const turn = container.querySelector('[data-testid="kw-chat-command-turn"]') as HTMLButtonElement
    expect(turn).not.toBeNull()
    expect(turn.disabled).toBe(false)

    await act(async () => {
      turn.click()
    })

    expect(container.querySelector('[role="dialog"]')?.textContent).toContain('턴 검사')

    await act(async () => {
      resolveAction()
      await Promise.resolve()
    })
  })

  it('keeps runtime scope/path out of the slim chat header', async () => {
    const { KeeperWorkspaceChat } = await loadChat()
    const keeperWithSlug = { ...mockKeeper, sandbox_target: '~/wt/sangsu', skill_primary: 'skill-primary' }

    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${keeperWithSlug}
        />
      `, container)
    })

    const slug = container.querySelector('.chat-head .sub .sub-ns') as HTMLElement | null
    expect(slug).toBeNull()
    expect(container.querySelector('.kw-chat-name')?.textContent).toContain('상수')
    expect(container.querySelector('.kw-chat-name')?.textContent).not.toContain('~/wt/sangsu')
    expect(container.querySelector('.kw-chat-name')?.textContent).not.toContain('skill-primary')
  })

  it('switches the mobile pane to roster when the back button is clicked', async () => {
    const { KeeperWorkspaceChat } = await loadChat()
    const { keeperMobilePane } = await import('../keeper-detail-state')
    keeperMobilePane.value = 'chat'

    // The back button is mobile-only in the reskinned ChatHeader (desktop keeps
    // the roster visible), so render in mobile mode to exercise the same behavior.
    await act(async () => {
      render(html`
        <${KeeperWorkspaceChat}
          keeper=${mockKeeper}
          mobile=${true}
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
        />
      `, container)
    })

    const action = container.querySelector('[data-testid="kw-message-turn-action"]') as HTMLButtonElement
    expect(action).not.toBeNull()

    await act(async () => {
      action.click()
    })

    await waitFor(() => {
      expect(container.querySelector('[data-testid="kw-chat-turn-inspector-drawer"]')).not.toBeNull()
    })
    const drawer = container.querySelector('[data-testid="kw-chat-turn-inspector-drawer"]')
    expect(drawer).not.toBeNull()
    expect(drawer?.textContent).toContain('메시지 sangsu')
    expect(drawer?.textContent).toContain('2026-03-24T00:02:00.000Z')
    expect(container.querySelector('[data-testid="kw-turn-inspector"]')?.getAttribute('data-keeper')).toBe('sangsu')
    expect(container.querySelector('[data-testid="kw-turn-inspector"]')?.getAttribute('data-initial-turn-timestamp')).toBe('2026-03-24T00:02:00.000Z')
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
    // Config lives inside the mobile overflow menu, not as a top-level icon.
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
