// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KeeperGoalHorizonsPanel } from './keeper-goal-horizons-panel'

describe('KeeperGoalHorizonsPanel', () => {
  const makeContainer = () => document.createElement('div')

  it('returns null when no data provided', () => {
    const container = makeContainer()
    render(html`<${KeeperGoalHorizonsPanel} />`, container)
    expect(container.innerHTML).toBe('')
    render(null, container)
  })

  it('renders goal horizons from short_goal/mid_goal/long_goal', () => {
    const container = makeContainer()
    render(html`<${KeeperGoalHorizonsPanel} short_goal="s" mid_goal="m" long_goal="l" />`, container)
    expect(container.textContent).toContain('short')
    expect(container.textContent).toContain('s')
    expect(container.textContent).toContain('mid')
    expect(container.textContent).toContain('m')
    expect(container.textContent).toContain('long')
    expect(container.textContent).toContain('l')
    render(null, container)
  })

  it('renders goal horizons from goal_horizons object', () => {
    const container = makeContainer()
    render(html`<${KeeperGoalHorizonsPanel} goal_horizons=${{ short: 'gs', mid: 'gm', long: 'gl' }} />`, container)
    expect(container.textContent).toContain('gs')
    expect(container.textContent).toContain('gm')
    expect(container.textContent).toContain('gl')
    render(null, container)
  })

  it('prefers direct goals over goal_horizons', () => {
    const container = makeContainer()
    render(html`<${KeeperGoalHorizonsPanel} short_goal="direct" goal_horizons=${{ short: 'indirect' }} />`, container)
    expect(container.textContent).toContain('direct')
    expect(container.textContent).not.toContain('indirect')
    render(null, container)
  })

  it('renders card title', () => {
    const container = makeContainer()
    render(html`<${KeeperGoalHorizonsPanel} short_goal="s" />`, container)
    expect(container.textContent).toContain('Goal Horizons')
    render(null, container)
  })

  it('applies v2-monitoring marker classes', () => {
    const container = makeContainer()
    render(html`<${KeeperGoalHorizonsPanel} short_goal="s" mid_goal="m" long_goal="l" />`, container)
    expect(container.innerHTML).toContain('v2-monitoring-panel')
    expect(container.innerHTML).toContain('v2-monitoring-row')
    render(null, container)
  })
})
