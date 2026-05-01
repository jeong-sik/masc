// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KeeperBDIPanel } from './keeper-bdi-panel'

describe('KeeperBDIPanel', () => {
  const makeContainer = () => document.createElement('div')

  it('returns null when no data provided', () => {
    const container = makeContainer()
    render(html`<${KeeperBDIPanel} />`, container)
    expect(container.innerHTML).toBe('')
    render(null, container)
  })

  it('renders BDI fields when provided', () => {
    const container = makeContainer()
    render(html`<${KeeperBDIPanel} will="test will" needs="test needs" desires="test desires" />`, container)
    expect(container.textContent).toContain('의지')
    expect(container.textContent).toContain('test will')
    expect(container.textContent).toContain('필요')
    expect(container.textContent).toContain('test needs')
    expect(container.textContent).toContain('염망')
    expect(container.textContent).toContain('test desires')
    render(null, container)
  })

  it('renders goal horizons from short_goal/mid_goal/long_goal', () => {
    const container = makeContainer()
    render(html`<${KeeperBDIPanel} short_goal="s" mid_goal="m" long_goal="l" />`, container)
    expect(container.textContent).toContain('goal horizons')
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
    render(html`<${KeeperBDIPanel} goal_horizons=${{ short: 'gs', mid: 'gm', long: 'gl' }} />`, container)
    expect(container.textContent).toContain('gs')
    expect(container.textContent).toContain('gm')
    expect(container.textContent).toContain('gl')
    render(null, container)
  })

  it('prefers direct goals over goal_horizons', () => {
    const container = makeContainer()
    render(html`<${KeeperBDIPanel} short_goal="direct" goal_horizons=${{ short: 'indirect' }} />`, container)
    expect(container.textContent).toContain('direct')
    expect(container.textContent).not.toContain('indirect')
    render(null, container)
  })

  it('renders card title', () => {
    const container = makeContainer()
    render(html`<${KeeperBDIPanel} will="w" />`, container)
    expect(container.textContent).toContain('BDI & Horizons')
    render(null, container)
  })

  it('does not render BDI section when only goals provided', () => {
    const container = makeContainer()
    render(html`<${KeeperBDIPanel} short_goal="only goal" />`, container)
    expect(container.textContent).not.toContain('의지')
    expect(container.textContent).not.toContain('필요')
    expect(container.textContent).toContain('only goal')
    render(null, container)
  })

  it('does not render goals section when only BDI provided', () => {
    const container = makeContainer()
    render(html`<${KeeperBDIPanel} will="only will" />`, container)
    expect(container.textContent).toContain('의지')
    expect(container.textContent).not.toContain('goal horizons')
    render(null, container)
  })
})
