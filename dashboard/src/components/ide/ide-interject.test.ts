import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { fireEvent } from '@testing-library/preact'
import { activeKeeperName } from '../../keeper-state'
import { IdeInterject, interjectContextRouteLinks } from './ide-interject'
import { routeHashParams } from './ide-test-helpers'
import { cursorOverlaySignal } from './keeper-cursor-overlay'

describe('IdeInterject', () => {
  beforeEach(() => {
    activeKeeperName.value = 'nick0cave'
  })

  afterEach(() => {
    activeKeeperName.value = ''
    cursorOverlaySignal.value = {
      cursors: new Map(),
      heatmap: new Map(),
      collisions: [],
      active_file: null,
    }
    window.location.hash = ''
  })

  it('builds code and keeper context routes for the active interject target', () => {
    const links = interjectContextRouteLinks('sangsu', {
      keeper_id: 'sangsu',
      file_path: 'lib/runtime.ml',
      line: 42,
      column: 2,
      focus_mode: 'reviewing',
      last_update: Date.now(),
      tool_name: 'ocamllsp',
    })

    expect(links.map(link => link.label)).toEqual(['Code', 'Telemetry', 'Keeper'])
    expect(links.find(link => link.label === 'Code')).toMatchObject({
      params: {
        section: 'ide-shell',
        view: 'source',
        file: 'lib/runtime.ml',
        line: '42',
        surface: 'Interject',
        label: 'ocamllsp',
        source_id: 'interject:sangsu',
        keeper: 'sangsu',
      },
      evidence: 'Code lib/runtime.ml:42',
    })
    expect(links.find(link => link.label === 'Telemetry')).toMatchObject({
      params: {
        section: 'fleet-health',
        view: 'event-log',
        q: 'interject keeper:sangsu mode:reviewing tool:ocamllsp',
      },
      evidence: 'Fleet telemetry event log · query interject keeper:sangsu mode:reviewing tool:ocamllsp',
    })
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

  it('renders cursor context links and routes back to the IDE code surface', async () => {
    cursorOverlaySignal.value = {
      cursors: new Map([['sangsu', {
        keeper_id: 'sangsu',
        file_path: 'lib/runtime.ml',
        line: 42,
        column: 2,
        focus_mode: 'reviewing',
        last_update: Date.now(),
        tool_name: 'ocamllsp',
      }]]),
      heatmap: new Map(),
      collisions: [],
      active_file: 'lib/runtime.ml',
    }

    const container = document.createElement('div')
    await act(async () => {
      render(h(IdeInterject, { keeperName: 'sangsu' }), container)
    })

    const contextButtons = [...container.querySelectorAll<HTMLButtonElement>('.ide-interject-context-links button')]
    expect(container.querySelector('.ide-interject-context-count')?.textContent).toBe('CTX 3')
    expect(contextButtons.map(button => button.textContent)).toEqual(['Code', 'Telemetry', 'Keeper'])

    fireEvent.click(contextButtons.find(button => button.textContent === 'Code')!)
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=42&surface=Interject&label=ocamllsp&source_id=interject%3Asangsu&keeper=sangsu')

    fireEvent.click(contextButtons.find(button => button.textContent === 'Telemetry')!)
    expect(routeHashParams().get('q')).toBe('interject keeper:sangsu mode:reviewing tool:ocamllsp')
  })
})
