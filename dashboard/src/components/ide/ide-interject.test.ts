import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { fireEvent } from '@testing-library/preact'
import { activeKeeperName } from '../../keeper-state'
import { IdeInterject, interjectContextRouteLinks } from './ide-interject'
import { routeHashParams } from './ide-test-helpers'

describe('IdeInterject', () => {
  beforeEach(() => {
    activeKeeperName.value = 'nick0cave'
  })

  afterEach(() => {
    activeKeeperName.value = ''
    window.location.hash = ''
  })

  it('builds keeper context routes for the active interject target', () => {
    const links = interjectContextRouteLinks('sangsu')

    expect(links.map(link => link.label)).toEqual(['Telemetry', 'Keeper'])
    expect(links.find(link => link.label === 'Telemetry')).toMatchObject({
      params: {
        section: 'fleet-health',
        view: 'event-log',
        q: 'interject keeper:sangsu',
      },
      evidence: 'Fleet telemetry event log · query interject keeper:sangsu',
    })
    expect(interjectContextRouteLinks('   ')).toEqual([])
  })

  it('renders the interject store backed active keeper controls', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterject, {}), container)
    })

    const region = container.querySelector('[role="region"]')
    expect(region?.getAttribute('aria-label')).toBe('INTERJECT (interject store active keeper wiring)')
    expect(container.textContent).toContain('INTERJECT')
    expect(container.textContent).toContain('nick0cave')

    const input = container.querySelector('input')
    expect(input?.readOnly).toBe(false)
    expect(input?.getAttribute('aria-label')).toBe('Interject input')

    const contextButtons = [...container.querySelectorAll('.ide-interject-context-links button')]
    expect(container.querySelector('.ide-interject-context-count')?.textContent).toBe('CTX 2')
    expect(contextButtons.map(button => button.textContent)).toEqual(['Telemetry', 'Keeper'])

    const buttons = [...container.querySelectorAll<HTMLButtonElement>('.ide-interject-actions button')]
    expect(buttons.map(button => button.textContent)).toEqual(['Send', 'Approve', 'Pause', 'Drain'])
    expect(buttons[0]?.disabled).toBe(true)
    expect(buttons[1]?.disabled).toBe(true)
    expect(buttons[2]?.getAttribute('aria-label')).toContain('Keeper-scoped pause')
  })

  it('uses a compact chat entry point until the terminal-first shell expands it', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterject, { compact: true }), container)
    })

    expect(container.querySelector('[data-testid="ide-interject-fab"]')?.textContent).toBe('✦ Chat')
    expect(container.querySelector('input')).toBeNull()

    fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="ide-interject-fab"]')!)
    expect(container.querySelector('input')?.getAttribute('aria-label')).toBe('Interject input')
  })

  it('enables Send after text is entered', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterject, {}), container)
    })

    const input = container.querySelector('input') as HTMLInputElement
    const send = container.querySelector('.ide-interject-actions button') as HTMLButtonElement
    expect(send.disabled).toBe(true)

    await act(async () => {
      input.value = 'please inspect this change'
      input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    })

    expect(send.disabled).toBe(false)
  })

  it('sends on Enter, but not on the Enter that confirms an IME composition', async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ ok: true, data: {} }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }))
    vi.stubGlobal('fetch', fetchMock)
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterject, {}), container)
    })
    const input = container.querySelector('input') as HTMLInputElement

    await act(async () => {
      input.value = '이 변경을 봐 주세요'
      input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    })
    await act(async () => {
      fireEvent.keyDown(input, { key: 'Enter', isComposing: true })
    })
    expect(fetchMock).not.toHaveBeenCalled()

    await act(async () => {
      fireEvent.keyDown(input, { key: 'Enter', shiftKey: true })
    })
    expect(fetchMock).not.toHaveBeenCalled()

    await act(async () => {
      fireEvent.keyDown(input, { key: 'Enter' })
    })
    await vi.waitFor(() => {
      expect(fetchMock.mock.calls.some(call => JSON.stringify(call).includes('nick0cave'))).toBe(true)
    })
    vi.unstubAllGlobals()
  })

  it('collapses the compact chat with Escape or its close button', async () => {
    const container = document.createElement('div')
    document.body.appendChild(container)
    await act(async () => {
      render(h(IdeInterject, { compact: true }), container)
    })

    await act(async () => {
      fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="ide-interject-fab"]')!)
    })
    const input = container.querySelector('input') as HTMLInputElement
    expect(document.activeElement).toBe(input)
    await act(async () => {
      fireEvent.keyDown(input, { key: 'Escape' })
    })
    expect(container.querySelector('input')).toBeNull()

    await act(async () => {
      fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="ide-interject-fab"]')!)
    })
    await act(async () => {
      fireEvent.click(container.querySelector<HTMLButtonElement>('[data-testid="ide-interject-collapse"]')!)
    })
    expect(container.querySelector('[data-testid="ide-interject-fab"]')).not.toBeNull()
    render(null, container)
    container.remove()
  })

  it('prefers the route keeper over the global active keeper signal', async () => {
    activeKeeperName.value = ''
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterject, { keeperName: 'tech_glutton' }), container)
    })

    expect(container.textContent).toContain('tech_glutton')
    const input = container.querySelector('input') as HTMLInputElement
    const send = container.querySelector('.ide-interject-actions button') as HTMLButtonElement

    await act(async () => {
      input.value = 'inspect the current IDE context'
      input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    })

    expect(send.disabled).toBe(false)
  })

  it('preserves typed message when the route keeper changes', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterject, { keeperName: 'keeper-alpha' }), container)
    })

    const input = container.querySelector('input') as HTMLInputElement
    await act(async () => {
      input.value = 'keep this draft'
      input.dispatchEvent(new InputEvent('input', { bubbles: true }))
    })

    await act(async () => {
      render(h(IdeInterject, { keeperName: 'keeper-beta' }), container)
    })

    expect(container.textContent).toContain('keeper-beta')
    expect((container.querySelector('input') as HTMLInputElement).value).toBe('keep this draft')
  })

  it('renders keeper context links and routes into telemetry', async () => {
    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterject, { keeperName: 'sangsu' }), container)
    })

    const contextButtons = [...container.querySelectorAll<HTMLButtonElement>('.ide-interject-context-links button')]
    expect(container.querySelector('.ide-interject-context-count')?.textContent).toBe('CTX 2')
    expect(contextButtons.map(button => button.textContent)).toEqual(['Telemetry', 'Keeper'])

    fireEvent.click(contextButtons.find(button => button.textContent === 'Telemetry')!)
    expect(routeHashParams().get('q')).toBe('interject keeper:sangsu')
  })
})
