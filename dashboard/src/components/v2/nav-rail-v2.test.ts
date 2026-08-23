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

import { NavRailV2 } from './nav-rail-v2'

function scheduleNavItem(container: HTMLElement): Element | undefined {
  return Array.from(container.querySelectorAll('.nav-item')).find(el => el.textContent?.includes('예약'))
}

describe('NavRailV2 schedule item', () => {
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

  it('does not derive a badge from schedule lifecycle state', () => {
    render(html`<${NavRailV2} badges=${{ approvals: { state: 'ready', count: 3 } }} />`, container)

    expect(scheduleNavItem(container)).toBeTruthy()
    expect(scheduleNavItem(container)?.querySelector('.nav-badge')).toBeNull()
  })

  it('renders the typed unavailable approval fact on the mobile rail', () => {
    const unavailable = {
      state: 'unavailable',
      code: 'reset_required',
      title: 'Gate durable queue unavailable · runtime reset required',
      operator_detail: 'pending store requires reset',
      severity: 'bad',
      icon: '!',
    } as const
    render(html`<${NavRailV2} badges=${{ approvals: unavailable }} mobile=${true} />`, container)

    const approval = Array.from(container.querySelectorAll('.nav-item'))
      .find(el => el.textContent?.includes('Gate'))
    const badge = approval?.querySelector('.nav-badge')
    expect(badge?.textContent).toBe('!')
    expect(badge?.getAttribute('data-severity')).toBe('bad')
    expect(badge?.getAttribute('title')).toContain(unavailable.operator_detail)
  })

  // Rail order + group breaks mirror the keeper-v2 prototype (shell.jsx #29046).
  it('renders the prototype rail order including the 명령·Lab group', () => {
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
      'Keepers', '레지스트리', 'Monitor', '|',
      '작업', 'Gate', '예약', '|',
      '보드', 'Fusion', '로그', '|',
      'IDE', '커넥터', '|',
      '명령', 'Lab',
      'spacer',
      '설정',
    ])
  })
})
