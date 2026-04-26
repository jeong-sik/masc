// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  CopyableCode,
  copyableWrapperClasses,
  copyableLabelClasses,
} from './copyable-code'

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

  it('default aria-label is "명령 복사"; customized when label or ariaLabel provided', () => {
    render(html`<${CopyableCode} command="x" />`, container)
    expect(container.querySelector('[data-copy-button]')!.getAttribute('aria-label')).toBe('명령 복사')
  })

  it('aria-label uses "<label> 복사" when label set but ariaLabel missing', () => {
    render(html`<${CopyableCode} command="x" label="start" />`, container)
    expect(container.querySelector('[data-copy-button]')!.getAttribute('aria-label')).toBe('start 복사')
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

  it('default variant is secondary — quiet muted chrome, non-accented border', () => {
    render(html`<${CopyableCode} label="tail" command="./run.sh tail" />`, container)
    const wrap = container.querySelector('[data-copyable-code]')!
    expect(wrap.getAttribute('data-copyable-variant')).toBe('secondary')
    expect(wrap.className).toContain('border-[var(--white-8)]')
    expect(wrap.className).not.toContain('border-[var(--accent-30)]')
  })

  it('variant="primary" uses accented border + brighter label (Vercel next-steps CTA)', () => {
    // Regression guard: "primary" must read as the hero command in a
    // sequence — accent border + accented label tone — so the operator
    // knows which command to reach for first. Vercel "Deploy your
    // project" and Railway deploy-log next-steps use this hierarchy.
    render(html`<${CopyableCode} label="start" command="./run.sh" variant="primary" />`, container)
    const wrap = container.querySelector('[data-copyable-code]')!
    expect(wrap.getAttribute('data-copyable-variant')).toBe('primary')
    expect(wrap.className).toContain('border-[var(--accent-30)]')
    expect(wrap.className).toContain('bg-[var(--accent-12)]')
    const label = wrap.querySelector('span')!
    expect(label.className).toContain('text-[var(--color-accent-fg)]')
    expect(label.className).toContain('font-semibold')
  })

  it('variant="primary" label weight is bolder than secondary (visual hierarchy)', () => {
    // Semantic guard — secondary uppercase chip has no font-semibold;
    // primary does. If this reverses, the hierarchy inverts silently.
    render(html`<${CopyableCode} label="tail" command="x" variant="secondary" />`, container)
    const secondaryLabel = container.querySelector('[data-copyable-code] span')!
    expect(secondaryLabel.className).not.toContain('font-semibold')
  })
})

describe('copyableWrapperClasses (pure)', () => {
  it('primary returns accent-colored border + background tokens', () => {
    const cls = copyableWrapperClasses('primary')
    expect(cls).toContain('border-[var(--accent-30)]')
    expect(cls).toContain('bg-[var(--accent-12)]')
  })

  it('secondary returns muted white-channel tokens', () => {
    const cls = copyableWrapperClasses('secondary')
    expect(cls).toContain('border-[var(--white-8)]')
    expect(cls).toContain('bg-[var(--white-2)]')
  })

  it('primary has tighter padding than secondary (hero command reads larger)', () => {
    // py-2 vs py-1.5 — small but intentional. Regression guard against
    // a cleanup flattening the two variants to identical padding.
    expect(copyableWrapperClasses('primary')).toContain('py-2')
    expect(copyableWrapperClasses('secondary')).toContain('py-1.5')
  })
})

describe('copyableLabelClasses (pure)', () => {
  it('primary label uses accent color + font-semibold', () => {
    const cls = copyableLabelClasses('primary')
    expect(cls).toContain('text-[var(--color-accent-fg)]')
    expect(cls).toContain('font-semibold')
  })

  it('secondary label uses muted text-dim + no bold', () => {
    const cls = copyableLabelClasses('secondary')
    expect(cls).toContain('text-[var(--color-fg-disabled)]')
    expect(cls).not.toContain('font-semibold')
  })
})
