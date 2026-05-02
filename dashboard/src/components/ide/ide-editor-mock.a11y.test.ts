// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { IdeEditorMock } from './ide-editor-mock'

describe('IdeEditorMock a11y', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders the code document and ownership-backed editor mock accessibly', async () => {
    render(html`<${IdeEditorMock} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
