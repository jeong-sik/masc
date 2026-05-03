import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { IdeConversationRailMock } from './ide-conversation-rail-mock'
import { IDE_MOCK_RELATED_LINE, IDE_MOCK_THREADS } from './ide-mock-data'

describe('IdeConversationRailMock', () => {
  it('renders the RFC 0021 anchored thread rail mock', () => {
    const container = document.createElement('div')
    render(h(IdeConversationRailMock, {}), container)

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('CONVERSATION (RFC 0021 anchored thread rail mock)')
    expect(container.textContent).toContain('CONVERSATION')
    expect(container.textContent).toContain(String(IDE_MOCK_THREADS.length))
    expect(container.textContent).toContain(`router.ts:${IDE_MOCK_RELATED_LINE}`)
    expect(container.textContent).toContain('2 related')
    expect(container.textContent).toContain('FLAG')
    expect(container.textContent).toContain('nick0cave')
  })

  it('focuses a thread card when clicked', async () => {
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
})
