import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { IdeConversationRailMock } from './ide-conversation-rail-mock'

describe('IdeConversationRailMock', () => {
  it('renders the conversation rail with empty state when no API data', () => {
    const container = document.createElement('div')
    render(h(IdeConversationRailMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('CONVERSATION')
    expect(container.textContent).toContain('CONVERSATION')
    expect(container.textContent).toContain('0')
  })
})
