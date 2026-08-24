// The palette is event-driven DOM (arrows, typing, focus), so this file uses
// one static module graph with top-level vi.mock — the repo's earlier
// resetModules-per-test pattern splits the preact instance between the test's
// render() and the component's hooks, and DOM events then never propagate.

import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const m = vi.hoisted(() => ({
  navigate: vi.fn(),
  navigateToPost: vi.fn(),
  requestConfirm: vi.fn(),
  runGarbageCollection: vi.fn().mockResolvedValue(undefined),
  toggleCopilotDock: vi.fn(),
}))
const navigate = m.navigate
const requestConfirm = m.requestConfirm
const runGarbageCollection = m.runGarbageCollection
const toggleCopilotDock = m.toggleCopilotDock

vi.mock('../../router', async () => {
  const { signal } = await import('@preact/signals')
  return {
    navigate: m.navigate,
    navigateToPost: m.navigateToPost,
    route: signal<{ tab: string; params: Record<string, string> }>({
      tab: 'code',
      params: { section: 'ide-shell' },
    }),
  }
})

vi.mock('./confirm-dialog', () => ({ requestConfirm: m.requestConfirm }))
vi.mock('../flow-control/flow-control-state', () => ({ runGarbageCollection: m.runGarbageCollection }))
vi.mock('../copilot-dock', () => ({ toggleCopilotDock: m.toggleCopilotDock }))
vi.mock('../../lib/global-shortcut-manager', () => ({
  globalShortcutManager: { register: () => () => {} },
}))
vi.mock('../connector-status', () => ({
  KNOWN_CONNECTOR_IDS: ['discord', 'slack'],
  CONNECTOR_DISPLAY_NAMES: { discord: 'Discord', slack: 'Slack' },
}))

vi.mock('../../mission-signals', async () => {
  const { signal } = await import('@preact/signals')
  return {
    missionAgentBriefs: signal<any[]>([]),
    missionKeeperBriefs: signal<any[]>([]),
  }
})
vi.mock('../../store', async () => {
  const { signal } = await import('@preact/signals')
  return {
    shellAuthSummary: signal<any>({
      effective_role: 'worker',
      auth_error_code: null,
      auth_error_detail: null,
    }),
    boardPosts: signal<any[]>([]),
    fusionRuns: signal<any[]>([]),
  }
})
vi.mock('../gate-signals', async () => {
  const { signal } = await import('@preact/signals')
  return { gateData: signal<any>(null) }
})
vi.mock('../../goal-tree-state', async () => {
  const { signal } = await import('@preact/signals')
  return { goalTreeData: signal<any>(null) }
})

import { CommandPalette } from './command-palette'
import { missionAgentBriefs, missionKeeperBriefs } from '../../mission-signals'
import { shellAuthSummary, boardPosts, fusionRuns } from '../../store'
import { gateData } from '../gate-signals'
import { goalTreeData } from '../../goal-tree-state'
import { route } from '../../router'

describe('CommandPalette', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    ;(missionAgentBriefs as any).value = []
    ;(missionKeeperBriefs as any).value = []
    ;(route as any).value = { tab: 'code', params: { section: 'ide-shell' }, postId: null }
    ;(shellAuthSummary as any).value = {
      effective_role: 'worker',
      auth_error_code: null,
      auth_error_detail: null,
    }
    ;(boardPosts as any).value = []
    ;(fusionRuns as any).value = []
    ;(gateData as any).value = null
    ;(goalTreeData as any).value = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
  })

  it('renders nothing until opened, then shows the design cmdk surface with base groups', async () => {
    render(html`<${CommandPalette} />`, container)
    expect(container.querySelector('.cmdk')).toBeNull()

    render(html`<${CommandPalette} openOnMount=${true} />`, container)
    // preact diffing the existing mount keeps the closed state; unmount first
    // so openOnMount applies.
    render(null, container)
    const open = document.createElement('div')
    document.body.appendChild(open)
    try {
      render(html`<${CommandPalette} openOnMount=${true} />`, open)
      await waitFor(() => {
        expect(open.querySelector('.cmdk')).not.toBeNull()
      })

      const groups = Array.from(open.querySelectorAll('.cmdk-group')).map(el => el.textContent)
      expect(groups).toContain('명령')
      expect(groups).toContain('이동')

      // The 이동 group follows the prototype rail order, now including 명령/Lab.
      const navTitles = Array.from(open.querySelectorAll('.cmdk-item.surface .cmdk-item-t'))
        .map(el => el.textContent)
      expect(navTitles).toContain('명령')
      expect(navTitles).toContain('Lab')
      expect(navTitles).toContain('설정')
    } finally {
      render(null, open)
      open.remove()
    }
  })

  it('Chat 열기 toggles the copilot dock and Gate 큐 열기 shows the live pending count', async () => {
    ;(gateData as any).value = { approval_queue: [{ id: 'a1' }, { id: 'a2' }] }
    render(html`<${CommandPalette} openOnMount=${true} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-entry-id="action-gate-queue"] .cmdk-item-sub')?.textContent)
        .toBe('2건 대기')
    })

    // Each action closes the palette, so capture both nodes up front.
    const chat = container.querySelector('[data-entry-id="action-chat-dock"]') as Element
    const gate = container.querySelector('[data-entry-id="action-gate-queue"]') as Element
    fireEvent.click(chat)
    expect(toggleCopilotDock).toHaveBeenCalledTimes(1)

    fireEvent.click(gate)
    expect(navigate).toHaveBeenCalledWith('approvals')
  })

  it('runs maintenance actions only after confirmation', async () => {
    ;(shellAuthSummary as any).value = {
      effective_role: 'admin',
      auth_error_code: null,
      auth_error_detail: null,
    }
    render(html`<${CommandPalette} openOnMount=${true} />`, container)

    const gc = await waitFor(() => {
      const el = container.querySelector('[data-entry-id="action-gc"]') as Element | null
      expect(el).not.toBeNull()
      return el as Element
    })

    requestConfirm.mockResolvedValueOnce(true)
    fireEvent.click(gc)
    await waitFor(() => expect(runGarbageCollection).toHaveBeenCalledTimes(1))
  })

  it('does not expose admin-only garbage collection to a worker', async () => {
    render(html`<${CommandPalette} openOnMount=${true} />`, container)

    await waitFor(() => {
      expect(container.querySelector('[data-entry-id="action-gc"]')).toBeNull()
    })
  })

  it('registers the IDE rails toggle and flips its label with the route', async () => {
    render(html`<${CommandPalette} openOnMount=${true} />`, container)

    const toggle = await waitFor(() => {
      const el = container.querySelector('[data-entry-id="ide-toggle-rails"]') as Element | null
      expect(el).not.toBeNull()
      return el as Element
    })
    expect(toggle.textContent).toContain('숨기기')

    // The label flip must be observed while the palette is still open —
    // clicking the entry closes it.
    ;(route as any).value = { tab: 'code', params: { section: 'ide-shell', rails: 'hidden' }, postId: null }
    await waitFor(() => {
      expect(container.querySelector('[data-entry-id="ide-toggle-rails"]')?.textContent).toContain('보이기')
    })

    fireEvent.click(toggle)
    // Post-flip the entry reads "보이기": it strips `rails` from the params.
    expect(navigate).toHaveBeenCalledWith('code', { section: 'ide-shell' })
    expect(navigate).not.toHaveBeenCalledWith('code', { section: 'ide-shell', rails: 'hidden' })
  })

  it('merges the deep index only with a query and navigates each hit', { timeout: 15000 }, async () => {
    ;(goalTreeData as any).value = {
      tree: [{
        id: 'goal-1',
        title: 'CI 신뢰성 회복',
        priority: 2,
        tasks: [{ id: 't-1', title: '레이스 재현', assignee: 'keeper-a' }],
        children: [],
      }],
    }
    ;(gateData as any).value = {
      approval_queue: [{ id: 'q1', keeper_name: 'drifter', tool_name: 'Execute', input_preview: 'rm -rf build' }],
    }
    ;(fusionRuns as any).value = [{
      runId: 'fr-9',
      keeper: 'analyst',
      preset: 'triage',
      status: 'running',
      startedAt: 1,
    }]
    ;(boardPosts as any).value = [{
      id: 'p-7',
      title: '승인 큐 SLA',
      author: 'marshal',
      hearth: 'ops',
    }]

    render(html`<${CommandPalette} openOnMount=${true} />`, container)

    // Empty query: base only — no deep groups.
    await waitFor(() => {
      expect(container.querySelector('.cmdk-item.surface')).not.toBeNull()
    })
    expect(container.querySelector('[data-entry-id="goal-goal-1"]')).toBeNull()

    const input = container.querySelector('.cmdk-input') as HTMLInputElement
    fireEvent.input(input, { target: { value: '승인' } })

    await waitFor(() => {
      expect(container.querySelector('[data-entry-id="post-p-7"]')).not.toBeNull()
    })
    const groups = Array.from(container.querySelectorAll('.cmdk-group')).map(el => el.textContent)
    expect(groups).toContain('보드')

    fireEvent.input(input, { target: { value: 'triage' } })
    await waitFor(() => {
      expect(container.querySelector('[data-entry-id="fusion-fr-9"]')).not.toBeNull()
    })

    fireEvent.input(input, { target: { value: 'CI 신뢰성' } })
    await waitFor(() => {
      expect(container.querySelector('[data-entry-id="goal-goal-1"]')).not.toBeNull()
    })

    fireEvent.input(input, { target: { value: '레이스' } })
    const task = await waitFor(() => {
      const el = container.querySelector('[data-entry-id="task-t-1"]') as Element | null
      expect(el).not.toBeNull()
      return el as Element
    })
    expect(task.textContent).toContain('keeper-a')

    // A click closes the palette, so exercise exactly one navigation here and
    // keep the rest as presence assertions (the keyboard test covers firing).
    fireEvent.input(input, { target: { value: 'triage' } })
    const fusion = await waitFor(() => {
      const el = container.querySelector('[data-entry-id="fusion-fr-9"]') as Element | null
      expect(el).not.toBeNull()
      return el as Element
    })
    fireEvent.click(fusion)
    expect(navigate).toHaveBeenCalledWith('fusion', { run_id: 'fr-9' })
  })

  it('keyboard: arrows move the selection, Enter fires and closes', async () => {
    render(html`<${CommandPalette} openOnMount=${true} />`, container)

    const input = await waitFor(() => {
      const el = container.querySelector('.cmdk-input') as HTMLInputElement | null
      expect(el).not.toBeNull()
      return el as Element
    })

    const selected = () => Array.from(container.querySelectorAll('.cmdk-item'))
      .findIndex(el => el.classList.contains('sel'))
    await waitFor(() => expect(selected()).toBe(0))

    fireEvent.keyDown(input, { key: 'ArrowDown' })
    await waitFor(() => expect(selected()).toBe(1))

    fireEvent.keyDown(input, { key: 'ArrowUp' })
    await waitFor(() => expect(selected()).toBe(0))

    fireEvent.keyDown(input, { key: 'Enter' })
    // Base[0] is Chat 열기 — the dock toggle fired and the palette closed.
    await waitFor(() => expect(toggleCopilotDock).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(container.querySelector('.cmdk')).toBeNull())
  })
})
