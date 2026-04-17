// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { TextInput, TextArea } from './input'

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

describe('TextInput', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders an <input> with the given value + placeholder', () => {
    render(html`<${TextInput} value="hello" placeholder="type here" />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input).toBeTruthy()
    expect(input.value).toBe('hello')
    expect(input.placeholder).toBe('type here')
  })

  it('defaults type to "text" when not provided', () => {
    render(html`<${TextInput} />`, container)
    expect(container.querySelector('input')!.getAttribute('type')).toBe('text')
  })

  it('type="password" is forwarded', () => {
    render(html`<${TextInput} type="password" />`, container)
    expect(container.querySelector('input')!.getAttribute('type')).toBe('password')
  })

  it('forwards id to the <input> so <label for> resolves (accessibility contract)', () => {
    // This is the regression guard: TextInput previously dropped `id`
    // silently, making <label for="..."> labels orphan. See the
    // whitelist warning in input.ts.
    render(html`<${TextInput} id="my-input" />`, container)
    const input = container.querySelector('input')!
    expect(input.id).toBe('my-input')

    // And the end-to-end label lookup works:
    const label = document.createElement('label')
    label.setAttribute('for', 'my-input')
    label.textContent = 'Click me'
    container.appendChild(label)
    const target = container.querySelector(`#${label.getAttribute('for')}`)
    expect(target).toBe(input)
  })

  it('disabled=true sets the attribute so clicks/focus are no-ops', () => {
    render(html`<${TextInput} disabled=${true} />`, container)
    expect((container.querySelector('input') as HTMLInputElement).disabled).toBe(true)
  })

  it('aria-label is forwarded', () => {
    render(html`<${TextInput} ariaLabel="search keeper" />`, container)
    expect(container.querySelector('input')!.getAttribute('aria-label')).toBe('search keeper')
  })

  it('onInput fires with the current input value', async () => {
    const spy = vi.fn()
    render(html`<${TextInput} onInput=${spy} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'typed'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
    const ev = spy.mock.calls[0]![0] as Event
    expect((ev.target as HTMLInputElement).value).toBe('typed')
  })

  it('onKeyDown fires on key events', async () => {
    const spy = vi.fn()
    render(html`<${TextInput} onKeyDown=${spy} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
  })

  it('forwards name + autoComplete attributes', () => {
    render(
      html`<${TextInput} name="channel" autoComplete="off" />`,
      container,
    )
    const input = container.querySelector('input')!
    expect(input.getAttribute('name')).toBe('channel')
    expect(input.getAttribute('autocomplete')).toBe('off')
  })

  it('extra `class` prop is appended to the base class string', () => {
    render(html`<${TextInput} class="extra-hook" />`, container)
    expect(container.querySelector('input')!.className).toContain('extra-hook')
  })
})

describe('TextArea', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a <textarea> with the given value + rows', () => {
    render(html`<${TextArea} value="body" rows=${5} />`, container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta).toBeTruthy()
    expect(ta.value).toBe('body')
    expect(ta.getAttribute('rows')).toBe('5')
  })

  it('forwards id for <label for> accessibility', () => {
    render(html`<${TextArea} id="notes" />`, container)
    expect(container.querySelector('textarea')!.id).toBe('notes')
  })

  it('disabled=true renders disabled textarea', () => {
    render(html`<${TextArea} disabled=${true} />`, container)
    expect((container.querySelector('textarea') as HTMLTextAreaElement).disabled).toBe(true)
  })

  it('onInput fires with the current textarea value', async () => {
    const spy = vi.fn()
    render(html`<${TextArea} onInput=${spy} />`, container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    ta.value = 'multi\nline'
    ta.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
  })
})
