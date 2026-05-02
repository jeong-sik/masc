import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { KeeperDetailSection } from './keeper-detail-shell'

describe('KeeperDetailSection', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders eyebrow, title, description, and children', () => {
    render(
      html`<${KeeperDetailSection}
        id="keeper-summary"
        eyebrow="OVERVIEW"
        title="Status Overview"
        description="Summary of keeper state."
      >
        <div data-testid="child">Child</div>
      <//>`,
      container,
    )

    expect(container.textContent).toContain('OVERVIEW')
    expect(container.textContent).toContain('Status Overview')
    expect(container.textContent).toContain('Summary of keeper state.')
    expect(container.querySelector('[data-testid="child"]')).not.toBeNull()
  })

  it('sets section id and aria-label', () => {
    render(
      html`<${KeeperDetailSection}
        id="keeper-debug"
        eyebrow="DEBUG"
        title="Debug"
        description="Debug info."
      >
        <span>content</span>
      <//>`,
      container,
    )

    const section = container.querySelector('section')
    expect(section?.getAttribute('id')).toBe('keeper-debug')
    expect(section?.getAttribute('aria-label')).toBe('Debug')
  })

  it('applies scroll margin and rounded styling', () => {
    render(
      html`<${KeeperDetailSection}
        id="keeper-config"
        eyebrow="CONFIG"
        title="Configuration"
        description="Config details."
      >
        <div>inner</div>
      <//>`,
      container,
    )

    const section = container.querySelector('section')
    expect(section?.classList.contains('scroll-mt-24')).toBe(true)
    expect(section?.classList.contains('rounded-[var(--r-6)]')).toBe(true)
  })
})
