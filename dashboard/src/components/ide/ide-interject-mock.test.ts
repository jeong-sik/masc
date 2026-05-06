import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { activeKeeperName } from '../../keeper-state'
import { IdeInterjectMock } from './ide-interject-mock'

describe('IdeInterjectMock', () => {
  beforeEach(() => {
    activeKeeperName.value = 'nick0cave'
  })

  afterEach(() => {
    activeKeeperName.value = ''
  })

  it('renders the interject store backed active keeper controls', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterjectMock, {}), container)
    })

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('INTERJECT (interject store active keeper wiring)')
    expect(container.textContent).toContain('INTERJECT')
    expect(container.textContent).toContain('nick0cave')

    const input = container.querySelector('input')
    expect(input?.readOnly).toBe(false)
    expect(input?.getAttribute('aria-label')).toBe('Interject input')

    const buttons = [...container.querySelectorAll('button')]
    expect(buttons.map(button => button.textContent)).toEqual(['Send', 'Approve', 'Pause', 'Drain'])
    expect(buttons[0]?.disabled).toBe(true)
    expect(buttons[1]?.disabled).toBe(true)
    expect(buttons[2]?.getAttribute('aria-label')).toContain('Keeper-scoped pause')
  })

  it('enables Send after text is entered', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterjectMock, {}), container)
    })

    const input = container.querySelector('input') as HTMLInputElement
    const send = container.querySelector('button') as HTMLButtonElement
    expect(send.disabled).toBe(true)

    await act(async () => {
      input.value = 'please inspect this change'
      input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    })

    expect(send.disabled).toBe(false)
  })

  it('prefers the route keeper over the global active keeper signal', async () => {
    activeKeeperName.value = ''
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterjectMock, { keeperName: 'tech_glutton' }), container)
    })

    expect(container.textContent).toContain('tech_glutton')
    const input = container.querySelector('input') as HTMLInputElement
    const send = container.querySelector('button') as HTMLButtonElement

    await act(async () => {
      input.value = 'inspect the current IDE context'
      input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    })

    expect(send.disabled).toBe(false)
  })

  it('preserves typed message when the route keeper changes', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterjectMock, { keeperName: 'keeper-alpha' }), container)
    })

    const input = container.querySelector('input') as HTMLInputElement
    await act(async () => {
      input.value = 'keep this draft'
      input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    })

    await act(async () => {
      render(h(IdeInterjectMock, { keeperName: 'keeper-beta' }), container)
    })

    expect(container.textContent).toContain('keeper-beta')
    expect((container.querySelector('input') as HTMLInputElement).value).toBe('keep this draft')
  })
})
