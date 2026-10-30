// @vitest-environment happy-dom
//
// Tests for headless-preact/useFocusScope. Verifies the Preact-side
// lifecycle wiring (mount → activate, unmount → deactivate, active
// toggle → re-activate) on top of the unit-tested FocusScope core.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useRef, useEffect } from 'preact/hooks'
import { useFocusScope } from './use-focus-scope'

// Flush Preact's useEffect macrotasks. Preact 10 schedules effects via
// the host's queueMicrotask + a follow-up timer in happy-dom; a single
// setTimeout wait covers both phases reliably.
// The focus move lands after the render, so the assertion waits for the id it
// expects rather than for a duration. A fixed window is a bet on how much CPU
// the worker gets: 20ms held on an idle machine and lost one run in three under
// the full parallel suite (#35032).
const expectFocus = (id: string): Promise<void> =>
  vi.waitFor(() => { expect(document.activeElement?.id).toBe(id) })

let container: HTMLElement
let outsideButton: HTMLButtonElement

beforeEach(() => {
  document.body.innerHTML = ''
  outsideButton = document.createElement('button')
  outsideButton.id = 'outside'
  outsideButton.textContent = 'outside'
  document.body.appendChild(outsideButton)

  container = document.createElement('div')
  document.body.appendChild(container)
})

afterEach(() => {
  render(null, container)
  document.body.innerHTML = ''
})

interface ProbeProps {
  active?: boolean
}

function Probe({ active = true }: ProbeProps): unknown {
  const ref = useRef<HTMLDivElement | null>(null)
  useFocusScope({ containerRef: ref, active })
  return html`
    <div ref=${ref} tabIndex=${-1} data-testid="scope">
      <button id="b1">first</button>
      <input id="i1" />
      <button id="b2">last</button>
    </div>
  `
}

describe('useFocusScope', () => {
  it('activates on mount: focus moves to first tabbable inside the container', async () => {
    render(html`<${Probe} />`, container)
    // Allow Preact's effect to flush.
    await expectFocus('b1')
  })

  it('restores focus on unmount', async () => {
    outsideButton.focus()
    expect(document.activeElement?.id).toBe('outside')
    render(html`<${Probe} />`, container)
    await expectFocus('b1')

    render(null, container)
    expect(document.activeElement?.id).toBe('outside')
  })

  it('active=false at mount does not move focus', async () => {
    outsideButton.focus()
    render(html`<${Probe} active=${false} />`, container)
    await expectFocus('outside')
  })

  it('toggling active false → true activates the scope', async () => {
    outsideButton.focus()
    render(html`<${Probe} active=${false} />`, container)
    await expectFocus('outside')

    render(html`<${Probe} active=${true} />`, container)
    await expectFocus('b1')
  })

  it('toggling active true → false deactivates and restores focus', async () => {
    outsideButton.focus()
    render(html`<${Probe} active=${true} />`, container)
    await expectFocus('b1')

    render(html`<${Probe} active=${false} />`, container)
    await expectFocus('outside')
  })

  it('Tab cycles inside the container while active (loop default true)', async () => {
    render(html`<${Probe} />`, container)
    // Waiting for the scope element is not enough: it exists as soon as render
    // returns, while the Tab handler arrives with the activation effect. The
    // effect's own observable is the initial focus move, so that is what this
    // waits on -- which is what the 20ms window was buying.
    await expectFocus('b1')
    const scopeEl = container.querySelector('[data-testid="scope"]')! as HTMLElement
    const last = scopeEl.querySelector('#b2') as HTMLButtonElement
    last.focus()
    expect(document.activeElement?.id).toBe('b2')
    scopeEl.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }),
    )
    expect(document.activeElement?.id).toBe('b1')
  })

  it('exposes the underlying FocusScope handle for imperative use', async () => {
    let captured: ReturnType<typeof useFocusScope> | null = null
    function Capturing(): unknown {
      const ref = useRef<HTMLDivElement | null>(null)
      const result = useFocusScope({ containerRef: ref, active: true })
      useEffect(() => {
        captured = result
      })
      return html`
        <div ref=${ref} tabIndex=${-1}>
          <button id="x1">x1</button>
          <button id="x2">x2</button>
        </div>
      `
    }
    render(html`<${Capturing} />`, container)
    await vi.waitFor(() => { expect(captured).not.toBeNull() })
    expect(typeof captured!.scope.focusLast).toBe('function')
    captured!.scope.focusLast()
    expect(document.activeElement?.id).toBe('x2')
  })
})
