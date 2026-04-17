// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { CopyableCode } from './copyable-code'

const flushUi = async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve()
}

describe('CopyableCode', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    vi.restoreAllMocks()
  })

  it('renders the command text inside a <code> element', () => {
    render(html`<${CopyableCode} command="ls -la" />`, container)
    const code = container.querySelector('code')
    expect(code).toBeTruthy()
    expect(code!.textContent).toBe('ls -la')
  })

  it('renders the optional label uppercase tag when provided', () => {
    render(html`<${CopyableCode} command="npm test" label="test cmd" />`, container)
    expect(container.textContent).toContain('test cmd')
  })

  it('default aria-label is "Copy command"; customized when label or ariaLabel provided', () => {
    render(html`<${CopyableCode} command="x" />`, container)
    expect(container.querySelector('[data-copy-button]')!.getAttribute('aria-label')).toBe('Copy command')
  })

  it('aria-label uses "Copy <label>" when label set but ariaLabel missing', () => {
    render(html`<${CopyableCode} command="x" label="start" />`, container)
    expect(container.querySelector('[data-copy-button]')!.getAttribute('aria-label')).toBe('Copy start')
  })

  it('explicit ariaLabel overrides the default computation', () => {
    render(html`<${CopyableCode} command="x" label="start" ariaLabel="override-me" />`, container)
    expect(container.querySelector('[data-copy-button]')!.getAttribute('aria-label')).toBe('override-me')
  })

  it('root carries data-copied="false" before any click', () => {
    render(html`<${CopyableCode} command="x" />`, container)
    expect(container.querySelector('[data-copyable-code]')!.getAttribute('data-copied')).toBe('false')
    expect(container.querySelector('[data-copied-badge]')).toBeNull()
  })

  it('clicking the copy button calls navigator.clipboard.writeText with the command', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(globalThis.navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    })
    render(html`<${CopyableCode} command="echo hello" />`, container)
    const btn = container.querySelector('[data-copy-button]') as HTMLButtonElement
    btn.click()
    await flushUi()

    expect(writeText).toHaveBeenCalledWith('echo hello')
  })

  it('after successful copy: data-copied=true, badge rendered, icon swapped', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(globalThis.navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    })
    render(html`<${CopyableCode} command="echo hi" label="greet" />`, container)
    const btn = container.querySelector('[data-copy-button]') as HTMLButtonElement
    btn.click()
    await flushUi()

    const root = container.querySelector('[data-copyable-code]')!
    expect(root.getAttribute('data-copied')).toBe('true')
    const badge = container.querySelector('[data-copied-badge]')
    expect(badge).toBeTruthy()
    expect(badge!.textContent).toContain('Copied')
    // aria-live=polite so screen readers get the state change
    expect(badge!.getAttribute('aria-live')).toBe('polite')
  })

  it('falls back to execCommand when navigator.clipboard.writeText rejects', async () => {
    const writeText = vi.fn().mockRejectedValue(new Error('permission denied'))
    Object.defineProperty(globalThis.navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    })
    // happy-dom doesn't define execCommand as an own property; install
    // a stub first so vi.spyOn can see it.
    ;(document as any).execCommand = () => true
    const execSpy = vi.spyOn(document, 'execCommand').mockReturnValue(true)

    render(html`<${CopyableCode} command="fallback" />`, container)
    ;(container.querySelector('[data-copy-button]') as HTMLButtonElement).click()
    await flushUi()

    expect(writeText).toHaveBeenCalledWith('fallback')
    expect(execSpy).toHaveBeenCalledWith('copy')
    // Fallback still counts as success → data-copied flips to true
    expect(container.querySelector('[data-copyable-code]')!.getAttribute('data-copied')).toBe('true')
  })

  it('leaves data-copied="false" when both clipboard paths fail', async () => {
    const writeText = vi.fn().mockRejectedValue(new Error('denied'))
    Object.defineProperty(globalThis.navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    })
    ;(document as any).execCommand = () => false
    vi.spyOn(document, 'execCommand').mockReturnValue(false)

    render(html`<${CopyableCode} command="x" />`, container)
    ;(container.querySelector('[data-copy-button]') as HTMLButtonElement).click()
    await flushUi()

    expect(container.querySelector('[data-copyable-code]')!.getAttribute('data-copied')).toBe('false')
    expect(container.querySelector('[data-copied-badge]')).toBeNull()
  })
})
