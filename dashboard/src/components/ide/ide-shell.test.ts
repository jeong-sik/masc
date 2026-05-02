import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { IdeShell } from './ide-shell'
import { route } from '../../router'

function buttonByText(container: HTMLElement, text: string): HTMLButtonElement {
  const button = Array.from(container.querySelectorAll('button'))
    .find(candidate => candidate.textContent === text)
  if (!(button instanceof HTMLButtonElement)) {
    throw new Error(`missing button: ${text}`)
  }
  return button
}

describe('IdeShell', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
  })

  afterEach(() => {
    render(null, container)
    window.location.hash = ''
    route.value = { tab: 'overview', params: {}, postId: null }
  })

  it('hydrates layer buttons from the route layers param', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', layers: 'time,approve' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(buttonByText(container, 'Time').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Approve').getAttribute('aria-pressed')).toBe('true')
    expect(buttonByText(container, 'Tools').getAttribute('aria-pressed')).toBe('false')
  })

  it('persists layer toggles back to the route', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'split-diff', layers: 'time,approve' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    fireEvent.click(buttonByText(container, 'Tools'))

    expect(route.value.params.view).toBe('split-diff')
    expect(route.value.params.layers).toBe('approve,time,tools')

    fireEvent.click(buttonByText(container, 'EXPLODE'))
    expect(route.value.params.layers).toBe('explode')
  })
})
