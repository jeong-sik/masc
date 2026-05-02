// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { IdeInterjectMock } from './ide-interject-mock'

describe('IdeInterjectMock a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders the interject input and action rail accessibly', async () => {
    render(html`<${IdeInterjectMock} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
