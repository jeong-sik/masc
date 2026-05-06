// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import type { RouteState } from '../types'
import {
  isWidgetSoloRoute,
  WidgetSoloBar,
  widgetSoloExitHashForRoute,
  widgetSoloHashForRoute,
  widgetSoloLabelForRoute,
  widgetSoloUrlForRoute,
  withWidgetSoloParam,
  withoutWidgetSoloParam,
} from './widget-solo'

function routeState(params: Record<string, string> = {}): RouteState {
  return {
    tab: 'monitoring',
    params,
    postId: null,
  }
}

describe('widget solo routing', () => {
  it('sets and detects the solo route param without dropping existing params', () => {
    const params = withWidgetSoloParam({ section: 'runtime', view: 'cost' })

    expect(params).toEqual({ section: 'runtime', view: 'cost', solo: '1' })
    expect(isWidgetSoloRoute(routeState(params))).toBe(true)
  })

  it('removes only the solo route param for the exit link', () => {
    const params = withoutWidgetSoloParam({ section: 'runtime', view: 'cost', solo: '1' })

    expect(params).toEqual({ section: 'runtime', view: 'cost' })
    expect(isWidgetSoloRoute(routeState(params))).toBe(false)
  })

  it('builds solo and exit hashes for the current dashboard surface', () => {
    const route = routeState({ section: 'runtime', view: 'cost' })

    expect(widgetSoloHashForRoute(route)).toBe('#monitoring?section=runtime&view=cost&solo=1')
    expect(widgetSoloExitHashForRoute({ ...route, params: { ...route.params, solo: '1' } }))
      .toBe('#monitoring?section=runtime&view=cost')
  })

  it('preserves the current dashboard pathname and query when building a popout url', () => {
    const route = routeState({ section: 'runtime', view: 'cost' })

    expect(widgetSoloUrlForRoute(route, { pathname: '/dashboard/', search: '?theme=paper' }))
      .toBe('/dashboard/?theme=paper#monitoring?section=runtime&view=cost&solo=1')
  })

  it('labels the solo surface from the active section and view', () => {
    expect(widgetSoloLabelForRoute(routeState({ section: 'runtime', view: 'cost' }))).toEqual({
      title: 'Cascade',
      id: 'monitoring:runtime:cost',
    })
  })

  it('renders a compact solo bar with an exit route back to the full dashboard', () => {
    const container = document.createElement('div')
    render(h(WidgetSoloBar, {
      routeState: routeState({ section: 'runtime', view: 'cost', solo: '1' }),
    }), container)

    const bar = container.querySelector('[data-testid="dashboard-widget-solo-bar"]')
    const exit = container.querySelector('a[aria-label="Return to full dashboard"]')

    expect(bar?.textContent).toContain('Cascade')
    expect(bar?.textContent).toContain('monitoring:runtime:cost')
    expect(exit?.getAttribute('href')).toBe('#monitoring?section=runtime&view=cost')
  })
})
