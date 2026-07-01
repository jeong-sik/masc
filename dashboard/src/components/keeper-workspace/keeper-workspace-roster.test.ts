import { render } from 'preact'
import { html } from 'htm/preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../router', async (orig) => ({
  ...(await orig<typeof import('../../router')>()),
  navigate: vi.fn(),
}))
vi.mock('../keeper-action-panel', () => ({
  runKeeperAction: vi.fn(async () => undefined),
}))
vi.mock('../keeper-detail-helpers', () => ({
  refreshAfterRuntimeAction: vi.fn(async () => undefined),
}))

import { navigate } from '../../router'
import { keepers } from '../../store'
import { keeperMobilePane } from '../keeper-detail-state'
import { runKeeperAction } from '../keeper-action-panel'
import { KeeperWorkspaceRoster, rosterFleetSummary } from './keeper-workspace-roster'
import type { Keeper } from '../../types'

function mk(partial: Partial<Keeper>): Keeper {
  return { name: 'k', status: 'running', ...partial } as Keeper
}

const FIXTURE: Keeper[] = [
  mk({ name: 'masc-improver', status: 'running', lifecycle_phase: 'Running' }),
  mk({ name: 'sangsu', status: 'running', paused: true, lifecycle_phase: 'Paused' }),
  mk({ name: 'rama', status: 'stopped', lifecycle_phase: 'Stopped', needs_attention: true }),
]

let host: HTMLElement

beforeEach(() => {
  keepers.value = FIXTURE
  vi.mocked(navigate).mockClear()
  vi.mocked(runKeeperAction).mockClear()
  host = document.createElement('div')
  document.body.appendChild(host)
})

afterEach(() => {
  render(null, host)
  host.remove()
  keepers.value = []
})

describe('KeeperWorkspaceRoster', () => {
  // The default sort is now '최근순' (flat, no headers); status grouping is opt-in.
  const selectStatusSort = () =>
    fireEvent.change(host.querySelector('.kw-roster-sort') as HTMLSelectElement, { target: { value: 'status' } })

  it('renders attention first while preserving status groups', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    selectStatusSort()
    const labels = Array.from(host.querySelectorAll('.kw-roster-group-label')).map(g => g.textContent)
    expect(labels).toEqual(['주의 필요', '실행 중', '대기 · 일시정지'])
    expect(host.querySelectorAll('.kw-kp-row').length).toBe(3)
  })

  it('preserves legacy roster selector aliases used by detail shells', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)

    expect(host.querySelector('.kw-roster.roster')).not.toBeNull()
    selectStatusSort()
    const firstHeader = host.querySelector('.kw-roster-group.roster-group') as HTMLElement
    expect(firstHeader?.getAttribute('title')).toBe('주의 필요')

    const toggle = host.querySelector('.rfilter-icon') as HTMLButtonElement
    expect(toggle).not.toBeNull()
    expect(host.querySelector('.roster-search')).toBeNull()

    fireEvent.click(toggle)

    expect(toggle.getAttribute('aria-expanded')).toBe('true')
    expect(host.querySelector('.kw-roster-search.roster-search')).not.toBeNull()
  })

  it('marks the active keeper row', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const active = host.querySelector('.kw-kp-row[aria-current="true"]') as HTMLElement
    expect(active?.textContent).toContain('masc-improver')
  })

  it('uses visible row content for the selectable row name', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const active = host.querySelector('.kw-kp-row[aria-current="true"]') as HTMLElement

    expect(active?.getAttribute('aria-label')).toBeNull()
    expect(active?.textContent).toContain('masc-improver')
    expect(active?.textContent).toContain('실행 중')
  })

  it('keeps row actions behind one explicit command menu target', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)

    expect(host.querySelector('.kw-kp-chat')).toBeNull()
    expect(host.querySelector('.kw-kp-inline-actions')).toBeNull()
    expect(host.querySelectorAll('.kw-kp-more').length).toBe(host.querySelectorAll('.kw-kp-row').length)
  })

  it('shows filter chip counts (all / running / attention)', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const chips = Array.from(host.querySelectorAll('.kw-rfilter')).map(c => c.textContent)
    // 전체 3, 실행 1 (only masc-improver), 주의 1 (rama)
    expect(chips.some(c => c?.includes('전체') && c?.includes('3'))).toBe(true)
    expect(chips.some(c => c?.includes('실행') && c?.includes('1'))).toBe(true)
    expect(chips.some(c => c?.includes('주의') && c?.includes('1'))).toBe(true)
  })

  it('shows the total keeper count on the 전체 filter chip', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    // v2 dropped the standalone "Keepers" title; the total count now lives on
    // the 전체 filter chip in the .roster-filters band.
    const allChip = Array.from(host.querySelectorAll('.kw-rfilter')).find(c => c.textContent?.includes('전체'))
    expect(allChip).not.toBeUndefined()
    expect(allChip?.textContent).toContain('3')
  })

  it('shows explicit recent activity age instead of a creation-date fallback', () => {
    keepers.value = [
      mk({
        name: 'recent-turn',
        status: 'running',
        lifecycle_phase: 'Running',
        last_turn_ago_s: 180,
      }),
      mk({
        name: 'created-only',
        status: 'running',
        lifecycle_phase: 'Running',
        created_at: '2026-03-28T18:00:00Z',
      }),
    ]

    render(html`<${KeeperWorkspaceRoster} activeName="recent-turn" />`, host)

    const rows = Array.from(host.querySelectorAll('.kp-row')) as HTMLElement[]
    const recent = rows.find(row => row.textContent?.includes('recent-turn')) as HTMLElement
    const createdOnly = rows.find(row => row.textContent?.includes('created-only')) as HTMLElement
    expect(recent.textContent).toContain('마지막 턴')
    expect(recent.textContent).toContain('3분 전')
    expect(createdOnly.textContent).not.toContain('생성')
  })

  it('labels attention as an attention signal rather than a bare count', () => {
    keepers.value = [
      mk({ name: 'blocked', status: 'running', lifecycle_phase: 'Running', blocked_task_count: 1 }),
    ]

    render(html`<${KeeperWorkspaceRoster} activeName="blocked" />`, host)

    const attention = host.querySelector('.kp-att') as HTMLElement
    expect(attention?.textContent).toBe('주의 1')
    expect(attention?.getAttribute('title')).toContain('메시지 수가 아니라')
  })

  // The fleet-summary band ([data-testid="kw-roster-summary"] with total/running/
  // paused/offline + 주의/승인/CTX aggregates) was removed in the v2 reskin — the
  // prototype roster opens straight into the .roster-filters band (전체/실행/주의
  // chips). The two band-rendering tests that lived here are dropped with the
  // feature. The underlying rosterFleetSummary() logic is still covered by the
  // unit test below.

  it('computes fleet summary from live keeper fields without local-only fleet actions', () => {
    const result = rosterFleetSummary([
      mk({ name: 'run', status: 'running', lifecycle_phase: 'Running', context_ratio: 0.8 }),
      mk({ name: 'pause', status: 'running', paused: true, lifecycle_phase: 'Paused', needs_attention: true }),
      mk({ name: 'off', status: 'stopped', lifecycle_phase: 'Stopped' }),
      mk({
        name: 'gate',
        status: 'running',
        lifecycle_phase: 'Running',
        current_gate: { kind: 'approval_required', tool: 'shell', risk: 'high' },
      }),
    ])

    expect(result).toEqual({
      total: 4,
      running: 2,
      paused: 1,
      offline: 1,
      attention: 1,
      approvalGate: 1,
      highContext: 1,
    })
  })

  it('navigates to the keeper route and reveals the chat pane on row click', () => {
    const onSelect = vi.fn()
    // Simulate the mobile roster pane being open; selecting a keeper must
    // switch the single-pane mobile layout over to that keeper's chat.
    keeperMobilePane.value = 'roster'
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" onSelect=${onSelect} />`, host)
    const rows = Array.from(host.querySelectorAll('.kw-kp-row')) as HTMLElement[]
    const sangsuRow = rows.find(r => r.textContent?.includes('sangsu'))
    sangsuRow?.click()
    expect(navigate).toHaveBeenCalledWith('monitoring', { section: 'agents', keeper: 'sangsu' })
    expect(onSelect).toHaveBeenCalledWith('sangsu')
    expect(keeperMobilePane.value).toBe('chat')
  })

  it('opens a row command menu without selecting the row', () => {
    const onSelect = vi.fn()
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" onSelect=${onSelect} />`, host)

    fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-sangsu"]') as HTMLButtonElement)

    expect(host.querySelector('[data-testid="kw-roster-menu"]')).not.toBeNull()
    expect(host.querySelector('[data-testid="kw-roster-menu"]')?.textContent).toContain('sangsu')
    expect(host.querySelector('[data-testid="kw-roster-menu-open-chat"]')).not.toBeNull()
    expect(host.querySelector('[data-testid="kw-roster-menu-config"]')).not.toBeNull()
    expect(navigate).not.toHaveBeenCalled()
    expect(onSelect).not.toHaveBeenCalled()
  })

  it('opens chat from a row command menu', () => {
    const onSelect = vi.fn()
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" onSelect=${onSelect} />`, host)

    fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-sangsu"]') as HTMLButtonElement)
    fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-open-chat"]') as HTMLButtonElement)

    expect(navigate).toHaveBeenCalledWith('monitoring', { section: 'agents', keeper: 'sangsu' })
    expect(onSelect).toHaveBeenCalledWith('sangsu')
    expect(host.querySelector('[data-testid="kw-roster-menu"]')).toBeNull()
  })

  it('runs lifecycle actions from a row command menu', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)

    fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-masc-improver"]') as HTMLButtonElement)
    fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-pause"]') as HTMLButtonElement)

    expect(runKeeperAction).toHaveBeenCalledWith('masc-improver', 'pause')
    expect(host.querySelector('[data-testid="kw-roster-menu"]')).toBeNull()
  })

  it('routes and opens config from a row command menu', () => {
    const onOpenConfig = vi.fn()
    render(html`
      <${KeeperWorkspaceRoster}
        activeName="masc-improver"
        onOpenConfig=${onOpenConfig}
      />
    `, host)

    fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-rama"]') as HTMLButtonElement)
    fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-config"]') as HTMLButtonElement)

    expect(navigate).toHaveBeenCalledWith('monitoring', { section: 'agents', keeper: 'rama' })
    expect(onOpenConfig).toHaveBeenCalledWith('rama')
    expect(host.querySelector('[data-testid="kw-roster-menu"]')).toBeNull()
  })

  it('opens the command menu on right-click (contextmenu) without selecting the row', () => {
    const onSelect = vi.fn()
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" onSelect=${onSelect} />`, host)
    const rows = Array.from(host.querySelectorAll('.kw-kp-row')) as HTMLElement[]
    const sangsuRow = rows.find(r => r.textContent?.includes('sangsu')) as HTMLElement

    // fireEvent returns false when the (cancelable) event had preventDefault
    // called — i.e. the native browser context menu is suppressed.
    const notPrevented = fireEvent.contextMenu(sangsuRow, { clientX: 120, clientY: 80 })
    expect(notPrevented).toBe(false)

    expect(host.querySelector('[data-testid="kw-roster-menu"]')).not.toBeNull()
    expect(host.querySelector('[data-testid="kw-roster-menu"]')?.textContent).toContain('sangsu')
    expect(host.querySelector('[data-testid="kw-roster-menu-open-chat"]')).not.toBeNull()
    expect(navigate).not.toHaveBeenCalled()
    expect(onSelect).not.toHaveBeenCalled()
  })

  it('opens the command menu on right-click of a mini-roster sigil', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" mini=${true} />`, host)
    const minis = Array.from(host.querySelectorAll('.kw-kp-mini')) as HTMLElement[]
    const ramaMini = minis.find(b => (b.getAttribute('aria-label') ?? '').includes('rama')) as HTMLElement

    fireEvent.contextMenu(ramaMini, { clientX: 60, clientY: 200 })

    expect(host.querySelector('[data-testid="kw-roster-menu"]')).not.toBeNull()
    expect(host.querySelector('[data-testid="kw-roster-menu"]')?.textContent).toContain('rama')
  })

  it('renders the v2.3 attention-first group headers with counts', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    selectStatusSort()
    const headers = Array.from(host.querySelectorAll('.kw-roster-group'))
    expect(headers.map(h => h.textContent)).toEqual([
      expect.stringContaining('주의 필요'),
      expect.stringContaining('실행 중'),
      expect.stringContaining('대기 · 일시정지'),
    ])
    expect(Array.from(host.querySelectorAll('.kw-roster-group-n')).map(n => n.textContent)).toEqual(['1', '1', '1'])
  })

  it('filters by search query', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    fireEvent.click(host.querySelector('.kw-rfilter-icon') as HTMLButtonElement)
    const search = host.querySelector('.kw-roster-search') as HTMLInputElement
    fireEvent.input(search, { target: { value: 'rama' } })
    const rows = host.querySelectorAll('.kw-kp-row')
    expect(rows.length).toBe(1)
    expect(rows[0]?.textContent).toContain('rama')
  })

  it('sorts the roster by name and attention count', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const sort = host.querySelector('.kw-roster-sort') as HTMLSelectElement

    fireEvent.change(sort, { target: { value: 'name' } })
    let rows = Array.from(host.querySelectorAll('.kw-kp-row')) as HTMLElement[]
    expect(rows.map(r => r.textContent ?? '')).toEqual([
      expect.stringContaining('masc-improver'),
      expect.stringContaining('rama'),
      expect.stringContaining('sangsu'),
    ])

    fireEvent.change(sort, { target: { value: 'att' } })
    rows = Array.from(host.querySelectorAll('.kw-kp-row')) as HTMLElement[]
    expect(rows[0]?.textContent).toContain('rama')
  })

  it('renders a compact sigil-only roster in mini mode', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" mini=${true} />`, host)
    expect(host.querySelector('.kw-roster-search')).toBeNull()
    expect(host.querySelector('.kw-roster-sort')).toBeNull()
    expect(host.querySelectorAll('.kw-kp-mini').length).toBe(3)
    expect(host.querySelector('.kw-kp-mini[aria-current="true"]')).not.toBeNull()
  })

  // The per-row work-preview line (.kw-kp-work — recent_output >
  // goal/current_task > last_proactive_preview > empty fallback) was removed in
  // the v2 reskin: the prototype roster row is a compact picker (name + FSM state
  // + basepath handle + activity time/attention), and a selected keeper's work
  // is shown in the chat pane. The 4 work-preview rendering tests are dropped with
  // the line. The precedence logic itself (keeperWorkPreview) is still rendered +
  // covered on the Monitor Fleet roster (agent-roster). See PR notes — restore the
  // workspace-roster preview line if operators want it back.

  it('uses content-visibility:auto on plain-list rows below the virtualization threshold', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    expect(host.querySelector('.virtual-list-spacer')).toBeNull()
    const rows = Array.from(host.querySelectorAll('.kw-kp-row')) as HTMLElement[]
    expect(rows.length).toBeGreaterThan(0)
    expect(rows.every(r => r.style.contentVisibility === 'auto')).toBe(true)
  })

  it('switches to VirtualList once the flattened roster exceeds the threshold', () => {
    // 60 rows plus 1 group header = 61 items, which is over WINDOW_AT (60).
    keepers.value = Array.from({ length: 60 }, (_, i) =>
      mk({ name: `keeper-${i}`, status: 'running', lifecycle_phase: 'Running' }),
    )
    render(html`<${KeeperWorkspaceRoster} activeName="keeper-0" />`, host)
    // status mode adds a group header (60 rows + 1 header = 61 > WINDOW_AT).
    selectStatusSort()
    expect(host.querySelector('.virtual-list-spacer')).not.toBeNull()
    expect(host.querySelector('.kw-roster-list')).not.toBeNull()
    // The windowed path renders the group header through the same renderHeader().
    expect(host.querySelector('.kw-roster-group .kw-roster-group-label')?.textContent).toBe('실행 중')
  })

  it('renders the sort select defaulting to 최근순 (recent) order', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const sortSel = host.querySelector('.kw-roster-sort') as HTMLSelectElement
    expect(sortSel).not.toBeNull()
    expect(sortSel.value).toBe('recent')
    expect(Array.from(sortSel.options).map(o => o.value)).toEqual(['recent', 'status', 'name', 'att'])
    // recent mode is a flat list: no status/attention group headers by default
    expect(host.querySelectorAll('.kw-roster-group').length).toBe(0)
    // switching to 상태순 brings the bucket group headers back
    selectStatusSort()
    expect(host.querySelectorAll('.kw-roster-group').length).toBeGreaterThan(0)
  })

  it('defaults to most-recent-first order (activity, not name)', () => {
    keepers.value = [
      mk({ name: 'albini', status: 'running', last_activity_ago_s: 3600 }),
      mk({ name: 'zed', status: 'running', last_activity_ago_s: 5 }),
      mk({ name: 'mara', status: 'running', last_activity_ago_s: 120 }),
    ]
    render(html`<${KeeperWorkspaceRoster} activeName="zed" />`, host)
    const order = Array.from(host.querySelectorAll('.kw-kp-row')).map(r =>
      r.textContent?.includes('zed') ? 'zed' : r.textContent?.includes('mara') ? 'mara' : 'albini',
    )
    // zed (5s) > mara (120s) > albini (3600s) — alphabetically-first albini is last
    expect(order).toEqual(['zed', 'mara', 'albini'])
  })

  it('sorts by name into a flat alphabetical list with no group headers', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    fireEvent.change(host.querySelector('.kw-roster-sort') as HTMLSelectElement, {
      target: { value: 'name' },
    })
    // flat list → status group headers disappear
    expect(host.querySelectorAll('.kw-roster-group').length).toBe(0)
    const order = Array.from(host.querySelectorAll('.kw-kp-row')).map(r =>
      r.textContent?.includes('masc-improver') ? 'masc-improver' : r.textContent?.includes('rama') ? 'rama' : 'sangsu',
    )
    expect(order).toEqual(['masc-improver', 'rama', 'sangsu'])
  })

  it('sorts by attention, ranking attention-needing keepers first', () => {
    keepers.value = [
      mk({ name: 'calm', status: 'running' }),
      mk({ name: 'blocked-3', status: 'running', blocked_task_count: 3 }),
      mk({ name: 'flagged', status: 'running', needs_attention: true }),
    ]
    render(html`<${KeeperWorkspaceRoster} activeName="calm" />`, host)
    fireEvent.change(host.querySelector('.kw-roster-sort') as HTMLSelectElement, {
      target: { value: 'att' },
    })
    const order = Array.from(host.querySelectorAll('.kw-kp-row')).map(r =>
      r.textContent?.includes('blocked-3') ? 'blocked-3' : r.textContent?.includes('flagged') ? 'flagged' : 'calm',
    )
    // blocked-3 (score 3) > flagged (flag → score 1) > calm (score 0)
    expect(order).toEqual(['blocked-3', 'flagged', 'calm'])
  })

  it('shows the keeper basepath (sandbox_target) as the row sub-line, shortened with a full-path title', () => {
    keepers.value = [mk({ name: 'miso', status: 'running', sandbox_target: '/workspace/keepers/keeper-miso' })]
    render(html`<${KeeperWorkspaceRoster} activeName="miso" />`, host)
    const handle = host.querySelector('.kw-kp-handle') as HTMLElement
    expect(handle?.textContent).toBe('…/keepers/keeper-miso')
    expect(handle?.getAttribute('title')).toBe('/workspace/keepers/keeper-miso')
  })

  it('falls back to the scope proxy when a keeper has no sandbox_target', () => {
    keepers.value = [mk({ name: 'nobase', status: 'running', model: 'anthropic/claude-x' })]
    render(html`<${KeeperWorkspaceRoster} activeName="nobase" />`, host)
    const handle = host.querySelector('.kw-kp-handle') as HTMLElement
    expect(handle?.textContent).toBe('anthropic/claude-x')
  })

  it('matches a search query against the basepath', () => {
    keepers.value = [
      mk({ name: 'alpha', status: 'running', sandbox_target: '/srv/worktrees/alpha-tree' }),
      mk({ name: 'beta', status: 'running', sandbox_target: '/srv/worktrees/beta-tree' }),
    ]
    render(html`<${KeeperWorkspaceRoster} activeName="alpha" />`, host)
    fireEvent.click(host.querySelector('.kw-rfilter-icon') as HTMLButtonElement)
    fireEvent.input(host.querySelector('.kw-roster-search') as HTMLInputElement, { target: { value: 'beta-tree' } })
    const rows = host.querySelectorAll('.kw-kp-row')
    expect(rows.length).toBe(1)
    expect(rows[0]?.textContent).toContain('beta')
  })

  it('renders a per-group keeper count in the status group header', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    selectStatusSort()
    const counts = Array.from(host.querySelectorAll('.kw-roster-group-n')).map(n => n.textContent)
    // FIXTURE: 1 attention row (rama), then running and paused status buckets.
    expect(counts).toEqual(['1', '1', '1'])
  })

  it('does not label calm offline keepers as normal', () => {
    keepers.value = [
      mk({ name: 'run', status: 'running', lifecycle_phase: 'Running' }),
      mk({ name: 'off', status: 'stopped', lifecycle_phase: 'Stopped' }),
    ]
    render(html`<${KeeperWorkspaceRoster} activeName="run" />`, host)
    selectStatusSort()

    const labels = Array.from(host.querySelectorAll('.kw-roster-group-label')).map(g => g.textContent)
    expect(labels).toEqual(['실행 중', '중지 · 종료됨'])
  })

  it('closes the row command menu on Escape only (not on any keypress) and on scroll', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const open = () => fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-sangsu"]') as HTMLButtonElement)

    open()
    expect(host.querySelector('[data-testid="kw-roster-menu"]')).not.toBeNull()
    fireEvent.keyDown(document, { key: 'a' })
    expect(host.querySelector('[data-testid="kw-roster-menu"]')).not.toBeNull() // a non-Esc key must NOT close it
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(host.querySelector('[data-testid="kw-roster-menu"]')).toBeNull()

    open()
    expect(host.querySelector('[data-testid="kw-roster-menu"]')).not.toBeNull()
    fireEvent.scroll(document)
    expect(host.querySelector('[data-testid="kw-roster-menu"]')).toBeNull()
  })

  // Regression coverage for the iter-4 PHASE_PULSE SSOT migration. The
  // row head sigil and the row StatusDot must derive their pulse/beat state
  // from `phasePulse(lifecycle_phase)` (closed-sum SSOT in keeper-fsm.ts),
  // NOT from the coarse `status === 'running'` predicate. The Draining case
  // is the load-bearing one: status='running' but lifecycle_phase='Draining'
  // — the old coarse predicate would have incorrectly pulsed it.
  it('does not pulse the row StatusDot or head sigil for a Draining keeper', () => {
    keepers.value = [mk({ name: 'draining', status: 'running', lifecycle_phase: 'Draining' })]
    render(html`<${KeeperWorkspaceRoster} activeName="draining" />`, host)

    const row = host.querySelector('.kw-kp-row.kp-row') as HTMLElement
    expect(row).not.toBeNull()

    const dot = row.querySelector('.kw-kp-state > span') as HTMLElement
    expect(dot).not.toBeNull()
    expect(dot.className).toMatch(/\bkw-dot\b/)
    expect(dot.className).not.toMatch(/\bpulse\b/)

    const headSigil = row.querySelector(':scope > .kw-sigil') as HTMLElement
    expect(headSigil).not.toBeNull()
    expect(headSigil.className).toMatch(/\bkw-sigil\b/)
    expect(headSigil.className).not.toMatch(/kw-sigil-beat/)
  })

  it('does not beat the menu-head WorkspaceSigil for a Draining keeper', () => {
    keepers.value = [mk({ name: 'draining', status: 'running', lifecycle_phase: 'Draining' })]
    render(html`<${KeeperWorkspaceRoster} activeName="draining" />`, host)

    fireEvent.click(host.querySelector('[data-testid="kw-roster-menu-draining"]') as HTMLButtonElement)

    const menuHead = host.querySelector('[data-testid="kw-roster-menu"] .kw-kp-menu-head') as HTMLElement
    expect(menuHead).not.toBeNull()
    const sigil = menuHead.querySelector('.kw-sigil') as HTMLElement
    expect(sigil).not.toBeNull()
    expect(sigil.className).toMatch(/\bkw-sigil\b/)
    expect(sigil.className).not.toMatch(/kw-sigil-beat/)
  })

  it('pulses the row sigil and StatusDot for an actively Running keeper (positive control)', () => {
    keepers.value = [mk({ name: 'active', status: 'running', lifecycle_phase: 'Running' })]
    render(html`<${KeeperWorkspaceRoster} activeName="active" />`, host)

    const row = host.querySelector('.kw-kp-row.kp-row') as HTMLElement
    expect(row).not.toBeNull()

    const headSigil = row.querySelector(':scope > .kw-sigil') as HTMLElement
    expect(headSigil.className).toMatch(/kw-sigil-beat/)

    const dot = row.querySelector('.kw-kp-state > span') as HTMLElement
    expect(dot.className).toMatch(/\bpulse\b/)
  })
})
