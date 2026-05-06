// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Checkbox, summarizeCheckbox } from './checkbox'

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

describe('summarizeCheckbox', () => {
  it('summarizes default checkbox state', () => {
    expect(summarizeCheckbox({})).toEqual({
      checkedState: 'unset',
      checked: false,
      disabled: false,
      hasCustomClass: false,
      classNameLength: 0,
      hasId: false,
      idLength: 0,
      hasName: false,
      nameLength: 0,
      a11yHook: 'none',
      hasAriaLabel: false,
      ariaLabelLength: 0,
      hasAriaLabelledby: false,
      ariaLabelledbyLength: 0,
      hasValue: false,
      valueLength: 0,
      hasTestId: false,
      testIdLength: 0,
      hasOnChange: false,
      hasOnClick: false,
    })
  })

  it('summarizes populated checkbox state', () => {
    const onChange = vi.fn()
    const onClick = vi.fn()
    expect(summarizeCheckbox({
      checked: true,
      disabled: true,
      class: 'extra-hook',
      id: 'opt-in',
      name: 'newsletter',
      ariaLabel: 'Accept terms',
      ariaLabelledby: 'tos-heading',
      value: 'yes',
      testId: 'optin-newsletter',
      onChange,
      onClick,
    })).toEqual({
      checkedState: 'true',
      checked: true,
      disabled: true,
      hasCustomClass: true,
      classNameLength: 10,
      hasId: true,
      idLength: 6,
      hasName: true,
      nameLength: 10,
      a11yHook: 'aria-labelledby',
      hasAriaLabel: true,
      ariaLabelLength: 12,
      hasAriaLabelledby: true,
      ariaLabelledbyLength: 11,
      hasValue: true,
      valueLength: 3,
      hasTestId: true,
      testIdLength: 16,
      hasOnChange: true,
      hasOnClick: true,
    })
  })

  it('falls back to aria-labelledby and id as a11y hooks', () => {
    expect(
      summarizeCheckbox({ ariaLabel: 'Label', ariaLabelledby: 'label-id' }).a11yHook,
    ).toBe('aria-labelledby')
    expect(summarizeCheckbox({ ariaLabelledby: 'label-id' }).a11yHook).toBe('aria-labelledby')
    expect(summarizeCheckbox({ id: 'field-id' }).a11yHook).toBe('id')
  })
})

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
    expect(cb.hasAttribute('data-checkbox')).toBe(true)
    expect(cb.getAttribute('data-checkbox-checked-state')).toBe('unset')
    expect(cb.getAttribute('data-checkbox-checked')).toBe('false')
    expect(cb.getAttribute('data-checkbox-a11y-hook')).toBe('none')
  })

  it('checked=true renders a checked input', () => {
    render(html`<${Checkbox} checked=${true} />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    expect(cb.checked).toBe(true)
    expect(cb.getAttribute('data-checkbox-checked-state')).toBe('true')
    expect(cb.getAttribute('data-checkbox-checked')).toBe('true')
  })

  it('checked=false renders explicit false metadata', () => {
    render(html`<${Checkbox} checked=${false} />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    expect(cb.checked).toBe(false)
    expect(cb.getAttribute('data-checkbox-checked-state')).toBe('false')
    expect(cb.getAttribute('data-checkbox-checked')).toBe('false')
  })

  it('disabled=true disables the input', () => {
    render(html`<${Checkbox} disabled=${true} />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    expect(cb.disabled).toBe(true)
    expect(cb.getAttribute('data-checkbox-disabled')).toBe('true')
  })

  it('forwards id so <label for> can resolve (accessibility contract)', () => {
    // Regression guard: Checkbox previously dropped `id`, making
    // <label for="..."> orphan. A sighted-but-screen-reader user would
    // hear "checkbox" with no name.
    render(html`<${Checkbox} id="opt-in" />`, container)
    const cb = container.querySelector('input') as HTMLInputElement
    expect(cb.id).toBe('opt-in')
    expect(cb.getAttribute('data-checkbox-has-id')).toBe('true')
    expect(cb.getAttribute('data-checkbox-id-length')).toBe('6')
    expect(cb.getAttribute('data-checkbox-a11y-hook')).toBe('id')

    // End-to-end label association works:
    const label = document.createElement('label')
    label.setAttribute('for', 'opt-in')
    label.textContent = 'Send me emails'
    container.appendChild(label)
    expect(container.querySelector(`#${label.getAttribute('for')}`)).toBe(cb)
  })

  it('forwards name for FormData serialization', () => {
    render(html`<${Checkbox} name="newsletter" checked=${true} />`, container)
    const cb = container.querySelector('input')!
    expect(cb.getAttribute('name')).toBe('newsletter')
    expect(cb.getAttribute('data-checkbox-has-name')).toBe('true')
    expect(cb.getAttribute('data-checkbox-name-length')).toBe('10')
  })

  it('forwards value — the string submitted when checked', () => {
    render(html`<${Checkbox} name="tier" value="pro" checked=${true} />`, container)
    const cb = container.querySelector('input')!
    expect(cb.getAttribute('value')).toBe('pro')
    expect(cb.getAttribute('data-checkbox-has-value')).toBe('true')
    expect(cb.getAttribute('data-checkbox-value-length')).toBe('3')
  })

  it('aria-label is forwarded (accessible name without external <label>)', () => {
    render(html`<${Checkbox} ariaLabel="Accept terms" />`, container)
    const cb = container.querySelector('input')!
    expect(cb.getAttribute('aria-label')).toBe('Accept terms')
    expect(cb.getAttribute('data-checkbox-a11y-hook')).toBe('aria-label')
    expect(cb.getAttribute('data-checkbox-has-aria-label')).toBe('true')
    expect(cb.getAttribute('data-checkbox-aria-label-length')).toBe('12')
  })

  it('aria-labelledby is forwarded (external-id label reference)', () => {
    render(html`<${Checkbox} ariaLabelledby="tos-heading" />`, container)
    const cb = container.querySelector('input')!
    expect(cb.getAttribute('aria-labelledby')).toBe('tos-heading')
    expect(cb.getAttribute('data-checkbox-a11y-hook')).toBe('aria-labelledby')
    expect(cb.getAttribute('data-checkbox-has-aria-labelledby')).toBe('true')
    expect(cb.getAttribute('data-checkbox-aria-labelledby-length')).toBe('11')
  })

  it('testId renders as data-testid (E2E stable hook)', () => {
    render(html`<${Checkbox} testId="optin-newsletter" />`, container)
    const cb = container.querySelector('input')!
    expect(cb.getAttribute('data-testid')).toBe('optin-newsletter')
    expect(cb.getAttribute('data-checkbox-has-test-id')).toBe('true')
    expect(cb.getAttribute('data-checkbox-test-id-length')).toBe('16')
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
    expect(cb.getAttribute('data-checkbox-has-change-handler')).toBe('true')
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
    expect(cb.getAttribute('data-checkbox-has-click-handler')).toBe('true')
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
    const cb = container.querySelector('input')!
    expect(cb.className).toContain('extra-hook')
    expect(cb.getAttribute('data-checkbox-has-custom-class')).toBe('true')
    expect(cb.getAttribute('data-checkbox-class-length')).toBe('10')
  })

  it('base classes are still present even when `class` extension is given', () => {
    render(html`<${Checkbox} class="extra-hook" />`, container)
    const cn = container.querySelector('input')!.className
    // Accent + rounded-[var(--r-1)] are part of CHECKBOX_BASE; regression would strip them.
    expect(cn).toContain('rounded-[var(--r-1)]')
    expect(cn).toContain('accent-[var(--color-accent-fg)]')
  })
})
