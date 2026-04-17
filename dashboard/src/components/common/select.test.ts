// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Select } from './select'

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

describe('Select', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a <select> with string options', () => {
    render(html`<${Select} options=${['a', 'b', 'c']} />`, container)
    const sel = container.querySelector('select') as HTMLSelectElement
    expect(sel).toBeTruthy()
    const opts = Array.from(sel.querySelectorAll('option')).map(o => o.value)
    expect(opts).toEqual(['a', 'b', 'c'])
  })

  it('renders {value, label} options with distinct display text', () => {
    render(
      html`<${Select} options=${[{ value: 'x', label: 'Extra' }, { value: 'y', label: 'Yankee' }]} />`,
      container,
    )
    const opts = Array.from(container.querySelectorAll('option'))
    expect(opts.map(o => o.value)).toEqual(['x', 'y'])
    expect(opts.map(o => o.textContent)).toEqual(['Extra', 'Yankee'])
  })

  it('placeholder renders as a disabled+hidden option when provided', () => {
    render(html`<${Select} options=${['a']} placeholder="-- pick --" />`, container)
    const first = container.querySelector('option')!
    expect(first.textContent).toBe('-- pick --')
    expect(first.hasAttribute('disabled')).toBe(true)
    expect(first.hasAttribute('hidden')).toBe(true)
  })

  it('no placeholder option is rendered when placeholder is absent', () => {
    render(html`<${Select} options=${['a', 'b']} />`, container)
    expect(container.querySelectorAll('option').length).toBe(2)
  })

  it('forwards id so <label for> can resolve (a11y contract)', () => {
    // Regression guard — Select previously dropped `id` silently,
    // making `<label for="...">` orphan.
    render(html`<${Select} options=${['a']} id="role" />`, container)
    const sel = container.querySelector('select') as HTMLSelectElement
    expect(sel.id).toBe('role')

    const label = document.createElement('label')
    label.setAttribute('for', 'role')
    label.textContent = 'Role'
    container.appendChild(label)
    expect(container.querySelector(`#${label.getAttribute('for')}`)).toBe(sel)
  })

  it('forwards name for FormData serialization', () => {
    render(html`<${Select} options=${['a']} name="role" />`, container)
    expect(container.querySelector('select')!.getAttribute('name')).toBe('role')
  })

  it('aria-label and aria-labelledby are forwarded', () => {
    render(html`<${Select} options=${['a']} ariaLabel="role" ariaLabelledby="hdr-role" />`, container)
    const sel = container.querySelector('select')!
    expect(sel.getAttribute('aria-label')).toBe('role')
    expect(sel.getAttribute('aria-labelledby')).toBe('hdr-role')
  })

  it('testId renders as data-testid (E2E stable hook, avoids i18n coupling)', () => {
    render(html`<${Select} options=${['a']} testId="role-picker" />`, container)
    expect(container.querySelector('select')!.getAttribute('data-testid')).toBe('role-picker')
  })

  it('required is forwarded (native form validation hook)', () => {
    render(html`<${Select} options=${['a']} required=${true} />`, container)
    expect((container.querySelector('select') as HTMLSelectElement).required).toBe(true)
  })

  it('disabled disables the <select>', () => {
    render(html`<${Select} options=${['a']} disabled=${true} />`, container)
    expect((container.querySelector('select') as HTMLSelectElement).disabled).toBe(true)
  })

  it('onInput fires with the new value on change', async () => {
    const spy = vi.fn()
    render(html`<${Select} options=${['a', 'b', 'c']} onInput=${spy} />`, container)
    const sel = container.querySelector('select') as HTMLSelectElement
    sel.value = 'b'
    sel.dispatchEvent(new Event('change', { bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
    expect(spy.mock.calls[0]![0]).toBe('b')
  })

  it('onBlur fires when focus leaves the select (validate-on-blur contract)', async () => {
    const spy = vi.fn()
    render(html`<${Select} options=${['a']} onBlur=${spy} />`, container)
    const sel = container.querySelector('select') as HTMLSelectElement
    sel.focus()
    sel.blur()
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
  })

  it('extra `class` prop is appended to the base class string', () => {
    render(html`<${Select} options=${['a']} class="extra-hook" />`, container)
    expect(container.querySelector('select')!.className).toContain('extra-hook')
  })

  it('base classes preserved even when `class` extension is given', () => {
    render(html`<${Select} options=${['a']} class="extra-hook" />`, container)
    const cn = container.querySelector('select')!.className
    expect(cn).toContain('rounded-lg')
    expect(cn).toContain('appearance-none')
  })
})
