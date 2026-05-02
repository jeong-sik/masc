// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { IdeActivityMock } from './ide-activity-mock'

describe('IdeActivityMock a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders the run activity pane accessibly', async () => {
    render(html`<${IdeActivityMock} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
