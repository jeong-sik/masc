// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  CopyableCode,
  copyableCodeAriaLabel,
  summarizeCopyableCode,
} from './copyable-code'
import { _testResetToasts } from './toast'

const flushUi = async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve()
}

type ExecCommandFn = (cmd: string) => boolean
type HappyDomDocument = { execCommand?: ExecCommandFn }
const doc = document as unknown as HappyDomDocument

describe('CopyableCode', () => {
  let container: HTMLElement
  const realClipboard = typeof navigator !== 'undefined' ? navigator.clipboard : undefined
  const realExec: ExecCommandFn | undefined = doc.execCommand

  function setClipboard(value: { writeText: (t: string) => Promise<void> } | undefined): void {
    Object.defineProperty(globalThis.navigator, 'clipboard', {
      configurable: true,
      value,
    })
  }

  function setExec(fn: ExecCommandFn | undefined): void {
    if (fn === undefined) {
      delete doc.execCommand
    } else {
      doc.execCommand = fn
    }
  }

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    setClipboard(realClipboard as unknown as { writeText: (t: string) => Promise<void> } | undefined)
    setExec(realExec)
    _testResetToasts()
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it('derives copy button labels through the shared fallback chain', () => {
    expect(copyableCodeAriaLabel()).toBe('명령 복사')
    expect(copyableCodeAriaLabel('start')).toBe('start 복사')
    expect(copyableCodeAriaLabel('start', 'Copy start command')).toBe('Copy start command')
  })

  it('summarizes copyable command metadata without reading the DOM', () => {
    expect(
      summarizeCopyableCode({
        command: 'pnpm test',
        label: 'test',
        variant: 'primary',
        copied: true,
      }),
    ).toEqual({
      variant: 'primary',
      state: 'copied',
      hasLabel: true,
      hasExplicitAriaLabel: false,
      commandLength: 9,
      ariaLabel: 'test 복사',
    })
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
    const root = container.querySelector('[data-copyable-code]')!
    expect(root.getAttribute('data-copied')).toBe('false')
    expect(root.getAttribute('data-copyable-state')).toBe('idle')
    expect(root.getAttribute('data-copyable-command-length')).toBe('1')
    expect(root.getAttribute('data-copyable-has-label')).toBe('false')
    expect(container.querySelector('[data-copied-badge]')).toBeNull()
  })

  it('clicking the copy button calls navigator.clipboard.writeText with the command', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    setClipboard({ writeText })
    render(html`<${CopyableCode} command="echo hello" />`, container)
    const btn = container.querySelector('[data-copy-button]') as HTMLButtonElement
    btn.click()
    await flushUi()

    expect(writeText).toHaveBeenCalledWith('echo hello')
  })

  it('after successful copy: data-copied=true, badge rendered, icon swapped', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    setClipboard({ writeText })
    render(html`<${CopyableCode} command="echo hi" label="greet" />`, container)
    const btn = container.querySelector('[data-copy-button]') as HTMLButtonElement
    btn.click()
    await flushUi()

    const root = container.querySelector('[data-copyable-code]')!
    expect(root.getAttribute('data-copied')).toBe('true')
    expect(root.getAttribute('data-copyable-state')).toBe('copied')
    expect(root.getAttribute('data-copyable-has-label')).toBe('true')
    const badge = container.querySelector('[data-copied-badge]')
    expect(badge).toBeTruthy()
    expect(badge!.textContent).toContain('Copied')
    // aria-live=polite so screen readers get the state change
    expect(badge!.getAttribute('aria-live')).toBe('polite')
  })

  it('falls back to execCommand when navigator.clipboard.writeText rejects', async () => {
    const writeText = vi.fn().mockRejectedValue(new Error('permission denied'))
    setClipboard({ writeText })
    const execFn = vi.fn<ExecCommandFn>(() => true)
    setExec(execFn)

    render(html`<${CopyableCode} command="fallback" />`, container)
    ;(container.querySelector('[data-copy-button]') as HTMLButtonElement).click()
    await flushUi()

    expect(writeText).toHaveBeenCalledWith('fallback')
    expect(execFn).toHaveBeenCalledWith('copy')
    // Fallback still counts as success → data-copied flips to true
    expect(container.querySelector('[data-copyable-code]')!.getAttribute('data-copied')).toBe('true')
  })

  it('leaves data-copied="false" when both clipboard paths fail', async () => {
    const writeText = vi.fn().mockRejectedValue(new Error('denied'))
    setClipboard({ writeText })
    const execFn = vi.fn<ExecCommandFn>(() => false)
    setExec(execFn)

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
    expect(wrap.className).toContain('border-[var(--color-border-default)]')
    expect(wrap.className).toContain('rounded-[var(--r-0)]')
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
