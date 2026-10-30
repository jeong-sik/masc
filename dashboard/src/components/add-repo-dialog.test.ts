// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { AddRepoDialog } from './add-repo-dialog'
import { showAddRepoDialog } from './repo-sidebar'

describe('AddRepoDialog rendering', () => {
  let container: HTMLElement

  beforeEach(() => {
    showAddRepoDialog.value = true
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    showAddRepoDialog.value = false
    document.body.removeChild(container)
  })

  it('renders the connector surface marker', () => {
    render(html`<${AddRepoDialog} />`, container)

    expect(container.querySelector('.v2-connector-surface')).not.toBeNull()
  })
})
