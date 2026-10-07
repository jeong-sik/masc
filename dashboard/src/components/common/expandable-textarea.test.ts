import { afterEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { useState } from 'preact/hooks'
import { ExpandableTextarea } from './expandable-textarea'

let host: HTMLDivElement | undefined

afterEach(() => {
  if (host) {
    render(null, host)
    host.remove()
    host = undefined
  }
})

function editor(value: string, onChange = vi.fn()) {
  host ??= document.body.appendChild(document.createElement('div'))
  // Mount without act: a user can type before passive mount effects run.
  render(html`<${ExpandableTextarea}
    value=${value} label="Instructions" onChange=${onChange}
  />`, host)
  return host.querySelector('textarea')!
}

function input(el: HTMLTextAreaElement, value: string) {
  el.focus()
  el.value = value
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

describe('ExpandableTextarea draft synchronization', () => {
  it('preserves the first input before passive mount effects run', async () => {
    const onChange = vi.fn()
    const el = editor('Original instructions', onChange)
    input(el, 'First instructions')
    await act(async () => {})
    expect(el.value).toBe('First instructions')
    act(() => el.blur())
    expect(onChange).toHaveBeenCalledWith('First instructions')
  })

  it('preserves input immediately after the parent resets its value', async () => {
    const onChange = vi.fn()
    editor('Original instructions', onChange)
    await act(async () => {})
    const el = editor('Server reset', onChange)
    input(el, 'Edited after reset')
    await act(async () => {})
    expect(el.value).toBe('Edited after reset')
    act(() => el.blur())
    expect(onChange).toHaveBeenCalledWith('Edited after reset')
  })

  it('still replaces a local draft when the parent resets its value', async () => {
    act(() => { editor('Original instructions') })
    const el = host!.querySelector('textarea')!
    act(() => input(el, 'Unsaved local draft'))
    expect(el.value).toBe('Unsaved local draft')
    act(() => { editor('Server reset') })
    expect(el.value).toBe('Server reset')
  })

  it.each(['취소', '닫기', 'backdrop'])('restores the parent draft on %s', async (close) => {
    const onChange = vi.fn()
    const onInput = vi.fn()
    function Parent() {
      const [value, setValue] = useState('Original instructions')
      return html`<${ExpandableTextarea}
        value=${value} label="Instructions"
        onChange=${(next: string) => { onChange(next); setValue(next) }}
        onInput=${(next: string) => { onInput(next); setValue(next) }}
      />`
    }
    host = document.body.appendChild(document.createElement('div'))
    act(() => render(html`<${Parent} />`, host!))
    act(() => input(host!.querySelector('textarea')!, 'Before expansion'))
    act(() => host!.querySelector('button')!.click())
    act(() => input(host!.querySelectorAll('textarea')[1]!, 'Cancelled fullscreen draft'))
    expect(onInput).toHaveBeenLastCalledWith('Cancelled fullscreen draft')
    const closer = close === 'backdrop'
      ? host!.querySelector<HTMLElement>('.fixed')!
      : Array.from(host!.querySelectorAll('button'))
        .find(button => button.textContent?.trim() === close)!
    act(() => closer.click())
    expect(host!.querySelectorAll('textarea')).toHaveLength(1)
    const inline = host!.querySelector('textarea')!
    expect(inline.value).toBe('Before expansion')
    expect(onInput).toHaveBeenLastCalledWith('Before expansion')
    act(() => { inline.focus(); inline.blur() })
    expect(onChange).toHaveBeenLastCalledWith('Before expansion')
  })

  it('keeps a parent reset when fullscreen editing is cancelled', async () => {
    act(() => { editor('Original instructions') })
    act(() => host!.querySelector('button')!.click())
    act(() => input(host!.querySelectorAll('textarea')[1]!, 'Local modal draft'))
    act(() => { editor('New parent value') })
    const cancel = Array.from(host!.querySelectorAll('button'))
      .find(button => button.textContent?.trim() === '취소')!
    act(() => cancel.click())
    expect(host!.querySelector('textarea')!.value).toBe('New parent value')
  })

  it('confirms the current fullscreen draft', async () => {
    const onChange = vi.fn()
    editor('Original instructions', onChange)
    await act(async () => {})
    act(() => host!.querySelector('button')!.click())
    const expanded = host!.querySelectorAll('textarea')[1]!
    act(() => input(expanded, 'Fullscreen draft'))
    const confirm = Array.from(host!.querySelectorAll('button'))
      .find(button => button.textContent?.trim() === '확인')!
    act(() => confirm.click())
    expect(onChange).toHaveBeenCalledWith('Fullscreen draft')
    expect(host!.querySelector('textarea')!.value).toBe('Fullscreen draft')
  })
})
