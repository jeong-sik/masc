import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { IdeActivityMock } from './ide-activity-mock'

describe('IdeActivityMock', () => {
  it('renders the activity pane with empty state when no API data', () => {
    const container = document.createElement('div')
    render(h(IdeActivityMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('EVENT TIMELINE')
    expect(container.textContent).toContain('0 events · 0 keepers')
  })
})
