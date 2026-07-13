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
    render(html`<${NavRailV2} badges=${{ approvals: 3 }} />`, container)

    expect(scheduleNavItem(container)).toBeTruthy()
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
