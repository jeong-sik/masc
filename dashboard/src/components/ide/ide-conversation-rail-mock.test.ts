import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { IdeConversationRailMock } from './ide-conversation-rail-mock'

describe('IdeConversationRailMock', () => {
  it('renders the conversation rail with board posts', () => {
    const container = document.createElement('div')
    render(h(IdeConversationRailMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('CONVERSATION')
    expect(container.textContent).toContain('CONVERSATION')
    expect(container.textContent).toContain('5')
    expect(container.textContent).toContain('FLAG')
    expect(container.textContent).toContain('nick0cave')
    expect(container.textContent).toContain('operator')
    expect(container.textContent).toContain('masc-improver')
  })

  it('focuses a post card when clicked', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeConversationRailMock, {}), container)
    })

    const button = container.querySelector('button')
    expect(button?.getAttribute('aria-current')).toBe(null)
    await act(async () => {
      button?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    })
    expect(button?.getAttribute('aria-current')).toBe('true')
  })

  it('shows kind labels from board post content', () => {
    const container = document.createElement('div')
    render(h(IdeConversationRailMock, {}), container)

    expect(container.textContent).toContain('APPROVE')
    expect(container.textContent).toContain('SUGGEST')
    expect(container.textContent).toContain('QUESTION')
  })
})
