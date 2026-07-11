import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  navigate: vi.fn(),
  route: { value: { tab: 'overview', params: {} } as { tab: string; params: Record<string, unknown> } },
}))

vi.mock('../../router', () => ({
  navigate: mocks.navigate,
  route: mocks.route,
}))

import { NavRailV2, type NavBadges } from './nav-rail-v2'

function scheduleNavItem(container: HTMLElement): Element | undefined {
  return Array.from(container.querySelectorAll('.nav-item')).find(el => el.textContent?.includes('예약'))
}

function navItem(container: HTMLElement, label: string): Element | undefined {
  return Array.from(container.querySelectorAll('.nav-item')).find(el => el.textContent?.includes(label))
}

// Every RailBadgeTab present with an explicit value — the type is a closed
// Record, so a real caller (nav-badges.ts) can never omit a key; tests
// exercise the same full-record contract rather than the old partial shape.
function badges(overrides: Partial<NavBadges> = {}): NavBadges {
  return {
    overview: 0,
    keepers: 0,
    monitoring: 0,
    workspace: 0,
    approvals: 0,
    schedule: 0,
    board: 0,
    fusion: 0,
    logs: 0,
    code: 0,
    connectors: 0,
    settings: 0,
    ...overrides,
  }
}

describe('NavRailV2 schedule badge', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.navigate.mockClear()
    mocks.route.value = { tab: 'overview', params: {} }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the pending-schedule count on the schedule nav item', () => {
    render(html`<${NavRailV2} badges=${badges({ schedule: 3 })} />`, container)

    const item = scheduleNavItem(container)
    expect(item).toBeTruthy()
    expect(item?.querySelector('.nav-badge')?.textContent).toBe('3')
  })

  it('omits the schedule badge when there are no pending schedules', () => {
    render(html`<${NavRailV2} badges=${badges({ schedule: 0 })} />`, container)

    expect(scheduleNavItem(container)?.querySelector('.nav-badge')).toBeNull()
  })

  // Rail order + group breaks mirror the 2026-07 keeper-v2 standalone export.
  it('renders the v2 export rail order with Monitor after Keepers', () => {
    render(html`<${NavRailV2} />`, container)

    const rail = container.querySelector('.v2-nav')
    const walk = Array.from(rail?.children ?? []).map(el => {
      if (el.className.includes('nav-div')) return '|'
      if (el.className.includes('nav-brand')) return 'brand'
      if (el.className.includes('nav-spacer')) return 'spacer'
      return el.getAttribute('title')
    })
    expect(walk).toEqual([
      'brand',
      '개요', '|',
      'Keepers', 'Monitor', '|',
      '작업', '승인', '예약', '|',
      '보드', 'Fusion', '로그', '|',
      'IDE', '커넥터',
      'spacer',
      '설정',
    ])
  })
})

describe('NavRailV2 badge record contract', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.navigate.mockClear()
    mocks.route.value = { tab: 'overview', params: {} }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders a count badge on every non-zero tab, including the footer 설정 button', () => {
    render(
      html`<${NavRailV2} badges=${badges({ keepers: 2, workspace: 5, board: 1, connectors: 3, settings: 7 })} />`,
      container,
    )

    expect(navItem(container, 'Keepers')?.querySelector('.nav-badge')?.textContent).toBe('2')
    expect(navItem(container, '작업')?.querySelector('.nav-badge')?.textContent).toBe('5')
    expect(navItem(container, '보드')?.querySelector('.nav-badge')?.textContent).toBe('1')
    expect(navItem(container, '커넥터')?.querySelector('.nav-badge')?.textContent).toBe('3')
    expect(navItem(container, '설정')?.querySelector('.nav-badge')?.textContent).toBe('7')
  })

  it('renders nothing for tabs whose badge is an explicit zero', () => {
    render(html`<${NavRailV2} badges=${badges({ keepers: 4 })} />`, container)

    // overview/monitoring/fusion/logs/code/settings are explicit zeros in the
    // typed record (nav-badges.ts) — the rail must render the same "nothing"
    // as an absent badges prop, not a visible "0".
    for (const label of ['개요', 'Monitor', 'Fusion', '로그', 'IDE', '설정']) {
      expect(navItem(container, label)?.querySelector('.nav-badge')).toBeNull()
    }
    expect(navItem(container, 'Keepers')?.querySelector('.nav-badge')?.textContent).toBe('4')
  })

  it('treats an absent badges prop the same as an all-zero record', () => {
    render(html`<${NavRailV2} />`, container)

    expect(container.querySelectorAll('.nav-badge').length).toBe(0)
  })

  it('adds sr-only count text alongside the visible badge', () => {
    render(html`<${NavRailV2} badges=${badges({ approvals: 9 })} />`, container)

    const approvalsItem = navItem(container, '승인')
    expect(approvalsItem?.querySelector('.sr-only')?.textContent).toBe(' (9건)')
  })

  it('sums hidden-tab badges into the mobile 더보기 tile', () => {
    render(html`<${NavRailV2} mobile=${true} badges=${badges({ board: 2, connectors: 3 })} />`, container)

    const more = Array.from(container.querySelectorAll('.nav-item')).find(el => el.textContent?.includes('더보기'))
    expect(more?.querySelector('.nav-badge')?.textContent).toBe('5')
  })
})
