import { render } from 'preact'
import { html } from 'htm/preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../router', async (orig) => ({
  ...(await orig<typeof import('../../router')>()),
  navigate: vi.fn(),
}))

import { navigate } from '../../router'
import { keepers } from '../../store'
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

  it('navigates to the keeper route on row click', () => {
    const onSelect = vi.fn()
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" onSelect=${onSelect} />`, host)
    const rows = Array.from(host.querySelectorAll('.kw-kp-row')) as HTMLElement[]
    const sangsuRow = rows.find(r => r.textContent?.includes('sangsu'))
    sangsuRow?.click()
    expect(navigate).toHaveBeenCalledWith('monitoring', { section: 'agents', keeper: 'sangsu' })
    expect(onSelect).toHaveBeenCalledWith('sangsu')
  })

  it('filters by search query', () => {
    render(html`<${KeeperWorkspaceRoster} activeName="masc-improver" />`, host)
    const search = host.querySelector('.kw-roster-search') as HTMLInputElement
    fireEvent.input(search, { target: { value: 'rama' } })
    const rows = host.querySelectorAll('.kw-kp-row')
    expect(rows.length).toBe(1)
    expect(rows[0]?.textContent).toContain('rama')
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

  it('renders the empty-work fallback when no preview source exists', () => {
    keepers.value = [mk({ name: 'bare', status: 'stopped' })]
    render(html`<${KeeperWorkspaceRoster} activeName="bare" />`, host)
    const work = host.querySelector('.kw-kp-work') as HTMLElement
    expect(work?.textContent).toBe('최근 작업 요약 없음')
    expect(work?.getAttribute('title')).toBe('')
  })
})
