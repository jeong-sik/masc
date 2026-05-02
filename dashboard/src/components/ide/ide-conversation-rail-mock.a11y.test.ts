// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { IdeConversationRailMock } from './ide-conversation-rail-mock'

describe('IdeConversationRailMock a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders the anchored thread rail mock accessibly', async () => {
    render(html`<${IdeConversationRailMock} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
