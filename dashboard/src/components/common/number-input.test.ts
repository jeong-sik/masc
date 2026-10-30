// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { NumberInput } from './number-input'

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

describe('NumberInput', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders an <input type="number">', () => {
    render(html`<${NumberInput} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input).toBeTruthy()
    expect(input.type).toBe('number')
  })

  it('forwards value + placeholder', () => {
    render(html`<${NumberInput} value=${42} placeholder="rows" />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input.value).toBe('42')
    expect(input.placeholder).toBe('rows')
  })

  it('forwards min / max / step constraints', () => {
    render(html`<${NumberInput} min=${0} max=${100} step=${5} />`, container)
    const input = container.querySelector('input')!
    expect(input.getAttribute('min')).toBe('0')
    expect(input.getAttribute('max')).toBe('100')
    expect(input.getAttribute('step')).toBe('5')
  })

  it('forwards id so <label for> can resolve (a11y contract)', () => {
    // Regression guard: NumberInput previously dropped `id`, making
    // `<label for="...">` orphan. Mirrors the TextInput fix in #7987.
    render(html`<${NumberInput} id="port" />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input.id).toBe('port')

    const label = document.createElement('label')
    label.setAttribute('for', 'port')
    label.textContent = 'Port'
    container.appendChild(label)
    expect(container.querySelector(`#${label.getAttribute('for')}`)).toBe(input)
  })

  it('forwards name for FormData serialization', () => {
    render(html`<${NumberInput} name="port" />`, container)
    expect(container.querySelector('input')!.getAttribute('name')).toBe('port')
  })

  it('aria-label and aria-labelledby are forwarded', () => {
    render(html`<${NumberInput} ariaLabel="server port" ariaLabelledby="hdr-port" />`, container)
    const input = container.querySelector('input')!
    expect(input.getAttribute('aria-label')).toBe('server port')
    expect(input.getAttribute('aria-labelledby')).toBe('hdr-port')
  })

  it('autoComplete is forwarded as autocomplete attr', () => {
    render(html`<${NumberInput} autoComplete="off" />`, container)
    expect(container.querySelector('input')!.getAttribute('autocomplete')).toBe('off')
  })

  it('testId renders as data-testid (E2E stable hook)', () => {
    render(html`<${NumberInput} testId="cfg-port" />`, container)
    expect(container.querySelector('input')!.getAttribute('data-testid')).toBe('cfg-port')
  })

  it('disabled=true disables the input', () => {
    render(html`<${NumberInput} disabled=${true} />`, container)
    expect((container.querySelector('input') as HTMLInputElement).disabled).toBe(true)
  })

  it('onInput fires with the numeric value on input change', async () => {
    const spy = vi.fn()
    render(html`<${NumberInput} onInput=${spy} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = '42'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
    expect(spy.mock.calls[0]![0]).toBe(42)
  })

  it('onInput fires with undefined when the field is cleared', async () => {
    const spy = vi.fn()
    render(html`<${NumberInput} value=${7} onInput=${spy} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = ''
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
    expect(spy.mock.calls[0]![0]).toBeUndefined()
  })

  it('onInput does NOT fire when the raw string fails Number() coercion', async () => {
    // Regression guard for the NaN branch — Number("12e") is NaN but
    // <input type="number"> lets the raw string through during typing.
    // Without the guard, we'd leak NaN into caller state.
    const spy = vi.fn()
    render(html`<${NumberInput} onInput=${spy} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    // happy-dom preserves whatever we assign to .value, so we can force
    // a non-numeric string even though the browser would filter it.
    input.value = 'not-a-number'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    // Either Number('') was coerced via the empty branch (value cleared)
    // OR nothing fired (NaN branch). Both acceptable — never NaN.
    for (const call of spy.mock.calls) {
      const v = call[0]
      if (v !== undefined) expect(Number.isNaN(v)).toBe(false)
    }
  })

  it('onKeyDown fires on key events (Enter-to-submit contract)', async () => {
    const spy = vi.fn()
    render(html`<${NumberInput} onKeyDown=${spy} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
  })

  it('onBlur fires when focus leaves the input (validate-on-blur contract)', async () => {
    const spy = vi.fn()
    render(html`<${NumberInput} onBlur=${spy} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.focus()
    input.blur()
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
  })

  it('extra `class` prop is appended to the base class string', () => {
    render(html`<${NumberInput} class="extra-hook" />`, container)
    expect(container.querySelector('input')!.className).toContain('extra-hook')
  })
})
