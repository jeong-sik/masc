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

import { navigate } from '../../router'
import { keepers } from '../../store'
import { keeperMobilePane } from '../keeper-detail-state'
import { runKeeperAction } from '../keeper-action-panel'
import { KeeperWorkspaceRoster } from './keeper-workspace-roster'
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
  it('renders status groups with keeper rows', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const groups = Array.from(host.querySelectorAll('.kw-roster-group')).map(g => g.textContent)
    expect(groups).toContain('실행 중')
    expect(groups).toContain('대기 · 일시정지')
    expect(groups).toContain('중지 · 종료됨')
    expect(host.querySelectorAll('.kw-kp-row').length).toBe(3)
  })

  it('marks the active keeper row', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const active = host.querySelector('.kw-kp-row[aria-current="true"]') as HTMLElement
    expect(active?.textContent).toContain('masc-improver')
  })

  it('shows filter chip counts (all / running / attention)', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const chips = Array.from(host.querySelectorAll('.kw-rfilter')).map(c => c.textContent)
    // 전체 3, 실행중 1 (only masc-improver), 주의 1 (rama)
    expect(chips.some(c => c?.includes('전체') && c?.includes('3'))).toBe(true)
    expect(chips.some(c => c?.includes('실행중') && c?.includes('1'))).toBe(true)
    expect(chips.some(c => c?.includes('주의') && c?.includes('1'))).toBe(true)
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

  it('filters by search query', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
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

  it('shows a work-preview line per row, preferring recent output', () => {
    keepers.value = [
      mk({ name: 'with-output', status: 'running', recent_output_preview: '리뷰 코멘트 정리 중' }),
    ]
    render(html`<${KeeperWorkspaceRoster} activeName="with-output" />`, host)
    const work = host.querySelector('.kw-kp-work') as HTMLElement
    expect(work?.textContent).toBe('리뷰 코멘트 정리 중')
    // title mirrors the text so truncated previews stay inspectable on hover
    expect(work?.getAttribute('title')).toBe('리뷰 코멘트 정리 중')
  })

  it('falls through the work-preview precedence chain', () => {
    keepers.value = [
      // recent_output/input absent -> short_goal wins over goal/current_task
      mk({ name: 'goal-only', status: 'running', short_goal: 'WIP 게이트 수정', goal: '무시됨' }),
    ]
    render(html`<${KeeperWorkspaceRoster} activeName="goal-only" />`, host)
    const work = host.querySelector('.kw-kp-work') as HTMLElement
    expect(work?.textContent).toBe('WIP 게이트 수정')
  })

  it('surfaces last_proactive_preview for a proactive-only keeper', () => {
    // A proactive keeper never broadcasts, so the message-bus previews
    // (recent_output/input) and goal/current_task stay empty; its work lives
    // only in last_proactive_preview. The roster must read it rather than
    // rendering the bare placeholder.
    keepers.value = [
      mk({
        name: 'executor',
        status: 'running',
        last_proactive_preview: 'Continuation checkpoint saved; scheduled next cycle.',
      }),
    ]
    render(html`<${KeeperWorkspaceRoster} activeName="executor" />`, host)
    const work = host.querySelector('.kw-kp-work') as HTMLElement
    expect(work?.textContent).toBe('Continuation checkpoint saved; scheduled next cycle.')
  })

  it('renders the empty-work fallback when no preview source exists', () => {
    keepers.value = [mk({ name: 'bare', status: 'stopped' })]
    render(html`<${KeeperWorkspaceRoster} activeName="bare" />`, host)
    const work = host.querySelector('.kw-kp-work') as HTMLElement
    expect(work?.textContent).toBe('최근 작업 요약 없음')
    expect(work?.getAttribute('title')).toBe('')
  })

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
    expect(host.querySelector('.virtual-list-spacer')).not.toBeNull()
    expect(host.querySelector('.kw-roster-list')).not.toBeNull()
  })

  it('renders the sort select defaulting to status order', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const sortSel = host.querySelector('.kw-roster-sort') as HTMLSelectElement
    expect(sortSel).not.toBeNull()
    expect(sortSel.value).toBe('status')
    expect(Array.from(sortSel.options).map(o => o.value)).toEqual(['status', 'name', 'att'])
    // status mode keeps the bucket group headers
    expect(host.querySelectorAll('.kw-roster-group').length).toBeGreaterThan(0)
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
})
