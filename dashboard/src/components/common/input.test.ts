// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { TextInput, TextArea, summarizeTextInput, summarizeTextArea } from './input'

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

  it('onBlur fires when the input loses focus (commit-on-blur pattern)', async () => {
    const spy = vi.fn()
    render(html`<${TextInput} value="draft" onBlur=${spy} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    input.dispatchEvent(new FocusEvent('blur', { bubbles: false }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
    const ev = spy.mock.calls[0]![0] as FocusEvent
    expect((ev.target as HTMLInputElement).value).toBe('draft')
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

  it('testId renders as data-testid (E2E target without coupling to placeholder text)', () => {
    render(html`<${TextInput} testId="search-filter" />`, container)
    expect(container.querySelector('input')!.getAttribute('data-testid')).toBe('search-filter')
  })

  it('autoFocus=true sets the autofocus attribute', () => {
    render(html`<${TextInput} autoFocus=${true} />`, container)
    expect(container.querySelector('input')!.hasAttribute('autofocus')).toBe(true)
  })

  it('inputRef.current points to the inner <input> after mount', () => {
    const ref: { current: HTMLInputElement | null } = { current: null }
    render(html`<${TextInput} inputRef=${ref} />`, container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(ref.current).toBe(input)
  })

  it('stamps design-system metadata on the input element', () => {
    render(
      html`<${TextInput}
        id="my-input"
        value="hello"
        placeholder="type here"
        disabled=${true}
        required=${true}
        class="extra-hook"
        type="search"
        name="query"
        ariaLabel="Search query"
        autoComplete="off"
        testId="search-filter"
        autoFocus=${true}
      />`,
      container,
    )
    const input = container.querySelector('[data-text-input]')!

    expect(input.getAttribute('data-text-input-kind')).toBe('text-input')
    expect(input.getAttribute('data-text-input-type')).toBe('search')
    expect(input.getAttribute('data-text-input-has-value')).toBe('true')
    expect(input.getAttribute('data-text-input-value-length')).toBe('5')
    expect(input.getAttribute('data-text-input-has-placeholder')).toBe('true')
    expect(input.getAttribute('data-text-input-placeholder-length')).toBe('9')
    expect(input.getAttribute('data-text-input-disabled')).toBe('true')
    expect(input.getAttribute('data-text-input-required')).toBe('true')
    expect(input.getAttribute('data-text-input-has-custom-class')).toBe('true')
    expect(input.getAttribute('data-text-input-class-length')).toBe('10')
    expect(input.getAttribute('data-text-input-has-id')).toBe('true')
    expect(input.getAttribute('data-text-input-has-name')).toBe('true')
    expect(input.getAttribute('data-text-input-has-aria-label')).toBe('true')
    expect(input.getAttribute('data-text-input-has-autocomplete')).toBe('true')
    expect(input.getAttribute('data-text-input-has-test-id')).toBe('true')
    expect(input.getAttribute('data-text-input-autofocus')).toBe('true')
  })

  it('summarizes default text input state', () => {
    expect(summarizeTextInput({})).toMatchObject({
      kind: 'text-input',
      type: 'text',
      hasValue: false,
      valueLength: 0,
      hasPlaceholder: false,
      disabled: false,
      required: false,
      hasCustomClass: false,
      hasId: false,
      hasName: false,
      hasAriaLabel: false,
      hasAutoComplete: false,
      hasTestId: false,
      autoFocus: false,
      ariaExpandedState: 'unset',
      autocompleteState: 'none',
    })
  })

  it('summarizes populated text input state without exposing the value text', () => {
    expect(summarizeTextInput({
      value: 'token',
      placeholder: 'secret',
      class: 'extra-hook',
      type: 'password',
      testId: 'token-input',
    })).toMatchObject({
      kind: 'text-input',
      type: 'password',
      hasValue: true,
      valueLength: 5,
      hasPlaceholder: true,
      placeholderLength: 6,
      hasCustomClass: true,
      classNameLength: 10,
      hasTestId: true,
    })
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

  it('onKeyDown fires on key events', async () => {
    const spy = vi.fn()
    render(html`<${TextArea} onKeyDown=${spy} />`, container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    ta.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushUi()
    expect(spy).toHaveBeenCalledOnce()
  })

  it('inputRef.current points to the inner <textarea> after mount', () => {
    const ref: { current: HTMLTextAreaElement | null } = { current: null }
    render(html`<${TextArea} inputRef=${ref} />`, container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ref.current).toBe(ta)
  })

  it('stamps design-system metadata on the textarea element', () => {
    const ref: { current: HTMLTextAreaElement | null } = { current: null }
    render(
      html`<${TextArea}
        id="prompt"
        value=${'multi\nline'}
        placeholder="Write"
        rows=${4}
        class="grow"
        name="prompt"
        ariaLabel="Prompt"
        ariaAutocomplete="list"
        ariaControls="prompt-list"
        ariaExpanded="true"
        ariaActiveDescendant="prompt-option-1"
        role="combobox"
        required=${true}
        inputRef=${ref}
        onInput=${vi.fn()}
        onKeyDown=${vi.fn()}
      />`,
      container,
    )
    const textarea = container.querySelector('[data-textarea]')!

    expect(textarea.getAttribute('data-textarea-kind')).toBe('textarea')
    expect(textarea.getAttribute('data-textarea-rows')).toBe('4')
    expect(textarea.getAttribute('data-textarea-has-rows')).toBe('true')
    expect(textarea.getAttribute('data-textarea-has-value')).toBe('true')
    expect(textarea.getAttribute('data-textarea-value-length')).toBe('10')
    expect(textarea.getAttribute('data-textarea-has-placeholder')).toBe('true')
    expect(textarea.getAttribute('data-textarea-placeholder-length')).toBe('5')
    expect(textarea.getAttribute('data-textarea-required')).toBe('true')
    expect(textarea.getAttribute('data-textarea-has-custom-class')).toBe('true')
    expect(textarea.getAttribute('data-textarea-class-length')).toBe('4')
    expect(textarea.getAttribute('data-textarea-has-id')).toBe('true')
    expect(textarea.getAttribute('data-textarea-has-name')).toBe('true')
    expect(textarea.getAttribute('data-textarea-has-aria-label')).toBe('true')
    expect(textarea.getAttribute('data-textarea-aria-expanded-state')).toBe('true')
    expect(textarea.getAttribute('data-textarea-autocomplete-state')).toBe('complete')
  })

  it('summarizes textarea autocomplete state', () => {
    expect(summarizeTextArea({
      rows: 3,
      ariaExpanded: 'mixed',
      ariaControls: 'listbox',
      role: 'combobox',
      onKeyDown: vi.fn(),
    })).toMatchObject({
      kind: 'textarea',
      rows: 3,
      hasRows: true,
      ariaExpandedState: 'other',
      autocompleteState: 'partial',
    })
  })
})
