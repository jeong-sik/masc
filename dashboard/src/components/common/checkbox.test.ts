// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Checkbox } from './checkbox'

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

describe('Checkbox', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders an <input type="checkbox">', () => {
    render(html`<${Checkbox} />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    expect(cb).toBeTruthy()
    expect(cb.type).toBe('checkbox')
  })

  it('checked=true renders a checked input', () => {
    render(html`<${Checkbox} checked=${true} />`, container)
    expect((container.querySelector('input') as HTMLInputElement).checked).toBe(true)
  })

  it('disabled=true disables the input', () => {
    render(html`<${Checkbox} disabled=${true} />`, container)
    expect((container.querySelector('input') as HTMLInputElement).disabled).toBe(true)
  })

  it('forwards id so <label for> can resolve (accessibility contract)', () => {
    // Regression guard: Checkbox previously dropped `id`, making
    // <label for="..."> orphan. A sighted-but-screen-reader user would
    // hear "checkbox" with no name.
    render(html`<${Checkbox} id="opt-in" />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    expect(cb.id).toBe('opt-in')

    // End-to-end label association works:
    const label = document.createElement('label')
    label.setAttribute('for', 'opt-in')
    label.textContent = 'Send me emails'
    container.appendChild(label)
    expect(container.querySelector(`#${label.getAttribute('for')}`)).toBe(cb)
  })

  it('forwards name for FormData serialization', () => {
    render(html`<${Checkbox} name="newsletter" checked=${true} />`, container)
    expect(container.querySelector('input')!.getAttribute('name')).toBe('newsletter')
  })

  it('forwards value — the string submitted when checked', () => {
    render(html`<${Checkbox} name="tier" value="pro" checked=${true} />`, container)
    expect(container.querySelector('input')!.getAttribute('value')).toBe('pro')
  })

  it('aria-label is forwarded (accessible name without external <label>)', () => {
    render(html`<${Checkbox} ariaLabel="Accept terms" />`, container)
    expect(container.querySelector('input')!.getAttribute('aria-label')).toBe('Accept terms')
  })

  it('aria-labelledby is forwarded (external-id label reference)', () => {
    render(html`<${Checkbox} ariaLabelledby="tos-heading" />`, container)
    expect(container.querySelector('input')!.getAttribute('aria-labelledby')).toBe('tos-heading')
  })

  it('testId renders as data-testid (E2E stable hook)', () => {
    render(html`<${Checkbox} testId="optin-newsletter" />`, container)
    expect(container.querySelector('input')!.getAttribute('data-testid')).toBe('optin-newsletter')
  })

  it('onChange fires with the new checked boolean when user toggles on', async () => {
    const spy = vi.fn()
    render(html`<${Checkbox} onChange=${spy} />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    cb.checked = true
    cb.dispatchEvent(new Event('change', { bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
    expect(spy.mock.calls[0]![0]).toBe(true)
  })

  it('onChange fires with false when user toggles off', async () => {
    const spy = vi.fn()
    render(html`<${Checkbox} checked=${true} onChange=${spy} />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    cb.checked = false
    cb.dispatchEvent(new Event('change', { bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
    expect(spy.mock.calls[0]![0]).toBe(false)
  })

  it('onClick fires with the raw Event (for stopPropagation in clickable parents)', async () => {
    // The motivating case: a checkbox inside a row whose row-onClick
    // navigates somewhere. Without onClick + stopPropagation, toggling
    // the checkbox would also navigate. This test verifies the prop
    // forwards and the event reaches the handler with target intact.
    const spy = vi.fn((e: Event) => { e.stopPropagation() })
    render(html`<${Checkbox} onClick=${spy} />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    const ev = new MouseEvent('click', { bubbles: true, cancelable: true })
    cb.dispatchEvent(ev)
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
    const passed = spy.mock.calls[0]![0] as Event
    expect(passed.target).toBe(cb)
  })

  it('onClick does not block onChange — both fire independently', async () => {
    // Regression guard: forwarding onClick must not steal the change event.
    const onClickSpy = vi.fn()
    const onChangeSpy = vi.fn()
    render(html`<${Checkbox} onClick=${onClickSpy} onChange=${onChangeSpy} />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    cb.checked = true
    cb.dispatchEvent(new Event('change', { bubbles: true }))
    await flushUi()
    expect(onChangeSpy).toHaveBeenCalledOnce()
    expect(onChangeSpy.mock.calls[0]![0]).toBe(true)
  })

  it('extra `class` prop is appended to the base class string', () => {
    render(html`<${Checkbox} class="extra-hook" />`, container)
    expect(container.querySelector('input')!.className).toContain('extra-hook')
  })

  it('base classes are still present even when `class` extension is given', () => {
    render(html`<${Checkbox} class="extra-hook" />`, container)
    const cn = container.querySelector('input')!.className
    // Accent + rounded-[var(--r-1)] are part of CHECKBOX_BASE; regression would strip them.
    expect(cn).toContain('rounded-[var(--r-1)]')
    expect(cn).toContain('accent-[var(--color-accent-fg)]')
  })
})
