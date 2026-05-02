import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { IdeActivityMock } from './ide-activity-mock'

describe('IdeActivityMock', () => {
  it('renders the run activity store backed pane', () => {
    const container = document.createElement('div')
    render(h(IdeActivityMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('ACTIVITY THIS RUN (run activity store mock)')
    expect(container.textContent).toContain('13 events · 3 keepers')
    expect(container.textContent).toContain('nick0cave')
    expect(container.textContent).toContain('flagged')
    expect(container.textContent).toContain('router.ts:34')
  })
})
