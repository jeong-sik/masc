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
    render(html`<${NavRailV2} badges=${{ approvals: 0, schedule: 3 }} />`, container)

    const item = scheduleNavItem(container)
    expect(item).toBeTruthy()
    expect(item?.querySelector('.nav-badge')?.textContent).toBe('3')
  })

  it('omits the schedule badge when there are no pending schedules', () => {
    render(html`<${NavRailV2} badges=${{ approvals: 0, schedule: 0 }} />`, container)

    expect(scheduleNavItem(container)?.querySelector('.nav-badge')).toBeNull()
  })
})
