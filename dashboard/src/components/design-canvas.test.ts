import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { DesignCanvas } from './design-canvas'

describe('DesignCanvas', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    delete document.documentElement.dataset.theme
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    delete document.documentElement.dataset.theme
  })

  it('renders the root container and category tabs', async () => {
    await act(async () => {
      render(html`<${DesignCanvas} />`, container)
    })

    expect(container.querySelector('[data-design-canvas]')).not.toBeNull()
    expect(container.querySelector('[data-testid="design-canvas-tab-primitives"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="design-canvas-tab-molecules"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="design-canvas-tab-organisms"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="design-canvas-tab-surfaces"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="design-canvas-tab-motion"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="design-canvas-tab-fixtures"]')).not.toBeNull()
  })

  it('renders the primitives gallery by default', async () => {
    await act(async () => {
      render(html`<${DesignCanvas} />`, container)
    })

    const stage = container.querySelector('[data-testid="design-canvas-stage"]')
    expect(stage).not.toBeNull()
    expect(stage!.querySelectorAll('[data-design-canvas-artboard]').length).toBeGreaterThanOrEqual(6)
    expect(stage!.querySelectorAll('[role="progressbar"]').length).toBeGreaterThan(0)
  })

  it('switches tabs when clicked', async () => {
    await act(async () => {
      render(html`<${DesignCanvas} />`, container)
    })

    const organismsTab = container.querySelector('[data-testid="design-canvas-tab-organisms"]') as HTMLButtonElement
    await act(async () => {
      organismsTab.click()
    })

    expect(organismsTab.getAttribute('aria-selected')).toBe('true')
    const stage = container.querySelector('[data-testid="design-canvas-stage"]')
    expect(stage!.querySelector('[data-design-canvas-organism="keeper-card"]')).not.toBeNull()
  })

  it('toggles data-theme attribute when theme button is clicked', async () => {
    await act(async () => {
      render(html`<${DesignCanvas} />`, container)
    })

    const toggle = container.querySelector('[data-testid="design-canvas-theme-toggle"]') as HTMLButtonElement
    expect(toggle).not.toBeNull()
    expect(document.documentElement.dataset.theme).toBeUndefined()

    await act(async () => {
      toggle.click()
    })
    expect(document.documentElement.dataset.theme).toBe('paper')

    await act(async () => {
      toggle.click()
    })
    expect(document.documentElement.dataset.theme).toBeUndefined()
  })

  it('switches to the fixtures gallery and renders fixture data', async () => {
    await act(async () => {
      render(html`<${DesignCanvas} />`, container)
    })

    const fixturesTab = container.querySelector('[data-testid="design-canvas-tab-fixtures"]') as HTMLButtonElement
    await act(async () => {
      fixturesTab.click()
    })

    expect(fixturesTab.getAttribute('aria-selected')).toBe('true')
    const stage = container.querySelector('[data-testid="design-canvas-stage"]')
    expect(stage).not.toBeNull()
    expect(stage!.querySelector('[data-design-canvas-fixture="keeper-card"]')).not.toBeNull()
    expect(stage!.querySelector('[data-design-canvas-fixture="post-card"]')).not.toBeNull()
    expect(stage!.querySelector('[data-design-canvas-fixture="episode-card"]')).not.toBeNull()
  })
})
