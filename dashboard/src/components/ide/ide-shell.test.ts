import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { IdeShell } from './ide-shell'
import { navigate, route } from '../../router'

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
    vi.unstubAllGlobals()
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
    expect(container.textContent).toContain('PERSISTENCE MAP')
    expect(container.textContent).toContain('Active overlays')
    expect(container.textContent).toContain('Time')
    expect(container.textContent).toContain('Approve')
  })

  it('persists layer toggles back to the route', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'split-diff', layers: 'time,approve' },
      postId: null,
    }

    render(h(IdeShell, {}), container)
    expect(container.querySelector('[aria-label="Split diff preview"]')).not.toBeNull()
    fireEvent.click(buttonByText(container, 'Tools'))

    expect(route.value.params.view).toBe('split-diff')
    expect(route.value.params.layers).toBe('approve,time,tools')

    fireEvent.click(buttonByText(container, 'EXPLODE'))
    expect(route.value.params.layers).toBe('explode')
  })

  it('renders the Cascade layer button and toggles it via URL', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    const btn = buttonByText(container, 'Cascade')
    expect(btn.getAttribute('aria-pressed')).toBe('false')

    fireEvent.click(btn)
    expect(route.value.params.layers).toBe('cascade')
    expect(btn.getAttribute('aria-pressed')).toBe('true')

    fireEvent.click(btn)
    expect(route.value.params.layers).toBeUndefined()
    expect(btn.getAttribute('aria-pressed')).toBe('false')
  })

  it('hydrates cascade layer button from the ?layers=cascade URL param', () => {
    route.value = {
      tab: 'code',
      params: { section: 'ide-shell', view: 'source', layers: 'cascade' },
      postId: null,
    }

    render(h(IdeShell, {}), container)

    expect(buttonByText(container, 'Cascade').getAttribute('aria-pressed')).toBe('true')
    expect(container.textContent).toContain('Active overlays')
    expect(container.textContent).toContain('Cascade')
  })

  it('opens the keeper shell drawer from the terminal route param', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        'event: shell\ndata: {"type":"snapshot","keeper":"sangsu","task_id":"bgt-1","stdout_since":"hello\\\\n","stderr_since":"","closed":true}\n\n',
        {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        },
      ),
    )
    vi.stubGlobal('fetch', fetchMock)
    navigate('code', {
      section: 'ide-shell',
      view: 'source',
      terminal: 'open',
      keeper: 'sangsu',
    })

    render(h(IdeShell, {}), container)

    await waitFor(() => expect(container.textContent).toContain('hello'))
    expect(container.querySelector('[data-testid="keeper-shell-drawer"]')).not.toBeNull()
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/dashboard/keeper-shell/sangsu',
      expect.objectContaining({
        headers: expect.objectContaining({ Accept: 'text/event-stream' }),
      }),
    )
  })
})
