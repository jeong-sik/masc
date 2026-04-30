import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { RichComposer } from './rich-composer'

vi.mock('../../api/link-previews', () => ({
  fetchLinkPreviews: vi.fn().mockResolvedValue({}),
}))

vi.mock('./markdown', () => ({
  Markdown: function Markdown(props: any) {
    return props.text
  },
}))

describe('RichComposer', () => {
  it('renders write and preview tabs', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn() }), container)
    expect(container.textContent).toContain('Write')
    expect(container.textContent).toContain('Preview')
  })

  it('defaults to write mode showing textarea', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: 'hello', onValueChange: vi.fn() }), container)
    const ta = container.querySelector('textarea')
    expect(ta).not.toBeNull()
    expect(ta?.value).toBe('hello')
  })

  it('calls onValueChange on textarea input', () => {
    const onValueChange = vi.fn()
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    ta.value = 'new text'
    ta.dispatchEvent(new Event('input'))
    expect(onValueChange).toHaveBeenCalledWith('new text')
  })

  it('switches to preview mode on preview tab click', async () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '# heading', onValueChange: vi.fn() }), container)
    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Preview'))
    previewBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.querySelector('textarea')).toBeNull()
    expect(container.textContent).toContain('heading')
  })

  it('shows empty preview message when value is empty', async () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn() }), container)
    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Preview'))
    previewBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.textContent).toContain('미리볼 내용이 아직 없습니다')
  })

  it('shows empty preview message when value is whitespace only', async () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '   ', onValueChange: vi.fn() }), container)
    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Preview'))
    previewBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.textContent).toContain('미리볼 내용이 아직 없습니다')
  })

  it('respects placeholder prop', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), placeholder: 'Type here' }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta?.getAttribute('placeholder')).toBe('Type here')
  })

  it('respects rows prop', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), rows: 10 }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta?.getAttribute('rows')).toBe('10')
  })

  it('respects disabled prop on tabs', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), disabled: true }), container)
    const buttons = container.querySelectorAll('button')
    expect(Array.from(buttons).every((b) => b.hasAttribute('disabled'))).toBe(true)
  })

  it('renders helpText when provided', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), helpText: 'some help' }), container)
    expect(container.textContent).toContain('some help')
  })

  it('renders ariaLabel on textarea', () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: '', onValueChange: vi.fn(), ariaLabel: 'Message body' }), container)
    const ta = container.querySelector('textarea') as HTMLTextAreaElement
    expect(ta?.getAttribute('aria-label')).toBe('Message body')
  })

  it('switches back to write mode on write tab click', async () => {
    const container = document.createElement('div')
    render(h(RichComposer, { value: 'text', onValueChange: vi.fn() }), container)
    const previewBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Preview'))
    previewBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    const writeBtn = Array.from(container.querySelectorAll('button')).find((b) => b.textContent?.includes('Write'))
    writeBtn?.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.querySelector('textarea')).not.toBeNull()
  })
})
