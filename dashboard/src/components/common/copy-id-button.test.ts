// @vitest-environment happy-dom
import { describe, it, expect, vi, afterEach } from 'vitest'
import { h, render } from 'preact'
import { copyToClipboard } from './copyable-code'
import {
  CopyIdButton,
  copyIdButtonAriaLabel,
  summarizeCopyIdButton,
} from './copy-id-button'
import { _testGetToasts, _testResetToasts } from './toast'

// happy-dom does not expose `document.execCommand` by default. Assign/delete
// directly rather than spying on an undefined property.

type ExecCommandFn = (cmd: string) => boolean
type HappyDomDocument = { execCommand?: ExecCommandFn }
const doc = document as unknown as HappyDomDocument
const flushUi = async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve()
}

describe('copyToClipboard', () => {
  const realClipboard = typeof navigator !== 'undefined' ? navigator.clipboard : undefined
  const realExec: ExecCommandFn | undefined = doc.execCommand
  const mounted: HTMLElement[] = []

  function renderCopyButton(props: Parameters<typeof CopyIdButton>[0]): HTMLElement {
    const container = document.createElement('div')
    mounted.push(container)
    render(h(CopyIdButton, props), container)
    return container
  }

  function setClipboard(value: { writeText: (t: string) => Promise<void> } | undefined): void {
    Object.defineProperty(navigator, 'clipboard', {
      value,
      configurable: true,
      writable: true,
    })
  }

  function setExec(fn: ExecCommandFn | undefined): void {
    if (fn === undefined) {
      delete doc.execCommand
    } else {
      doc.execCommand = fn
    }
  }

  afterEach(() => {
    for (const container of mounted.splice(0)) {
      render(null, container)
      container.remove()
    }
    setClipboard(realClipboard as unknown as { writeText: (t: string) => Promise<void> } | undefined)
    setExec(realExec)
    _testResetToasts()
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it('derives accessible labels through the same fallback chain as the component', () => {
    expect(copyIdButtonAriaLabel()).toBe('복사')
    expect(copyIdButtonAriaLabel('Session ID')).toBe('Session ID 복사')
    expect(copyIdButtonAriaLabel('Session ID', 'Copy session')).toBe('Copy session')
  })

  it('summarizes copy button metadata without reading the DOM', () => {
    expect(
      summarizeCopyIdButton({
        value: 'abc-123',
        label: 'Session ID',
        size: 14,
        copied: true,
      }),
    ).toEqual({
      state: 'copied',
      hasLabel: true,
      hasExplicitAriaLabel: false,
      size: 14,
      valueLength: 7,
      ariaLabel: 'Session ID 복사',
    })
  })

  it('renders stable summary hooks on the icon-only button', () => {
    const container = renderCopyButton({ value: 'abc-123', label: 'Session ID', size: 14 })
    const button = container.querySelector('[data-copy-id-button]')!
    expect(button.getAttribute('data-copy-id-state')).toBe('idle')
    expect(button.getAttribute('data-copy-id-has-label')).toBe('true')
    expect(button.getAttribute('data-copy-id-has-explicit-aria-label')).toBe('false')
    expect(button.getAttribute('data-copy-id-size')).toBe('14')
    expect(button.getAttribute('data-copy-id-value-length')).toBe('7')
    expect(button.getAttribute('aria-label')).toBe('Session ID 복사')
    expect(button.className).toContain('size-6')
    expect(button.className).toContain('rounded-[var(--r-0)]')
    expect(container.querySelector('[data-copy-id-icon]')).toBeTruthy()
  })

  it('flips copied metadata and emits a success toast after a successful click', async () => {
    vi.useFakeTimers()
    const writeText = vi.fn(async () => {})
    setClipboard({ writeText })
    const container = renderCopyButton({ value: 'abc-123', label: 'Session ID' })
    const button = container.querySelector('[data-copy-id-button]') as HTMLButtonElement

    button.click()
    await flushUi()

    expect(writeText).toHaveBeenCalledWith('abc-123')
    expect(button.getAttribute('data-copy-id-state')).toBe('copied')
    expect(button.getAttribute('data-copied')).toBe('true')
    expect(_testGetToasts()).toContainEqual(
      expect.objectContaining({ message: '복사됨: Session ID', type: 'success' }),
    )
    vi.runOnlyPendingTimers()
  })

  it('uses navigator.clipboard.writeText when available and returns true on success', async () => {
    const writeText = vi.fn(async () => {})
    setClipboard({ writeText })

    const ok = await copyToClipboard('abc-123')
    expect(ok).toBe(true)
    expect(writeText).toHaveBeenCalledWith('abc-123')
  })

  it('falls back to execCommand when clipboard API throws and reports execCommand result', async () => {
    const writeText = vi.fn(async () => {
      throw new Error('permission denied')
    })
    setClipboard({ writeText })
    const execFn = vi.fn<ExecCommandFn>(() => true)
    setExec(execFn)

    const ok = await copyToClipboard('fallback-value')
    expect(ok).toBe(true)
    expect(execFn).toHaveBeenCalledWith('copy')
  })

  it('returns false when execCommand fails in the fallback path', async () => {
    const writeText = vi.fn(async () => {
      throw new Error('permission denied')
    })
    setClipboard({ writeText })
    setExec(() => false)

    const ok = await copyToClipboard('x')
    expect(ok).toBe(false)
  })

  it('returns false when execCommand itself throws', async () => {
    setClipboard(undefined)
    setExec(() => {
      throw new Error('not allowed')
    })

    const ok = await copyToClipboard('x')
    expect(ok).toBe(false)
  })

  it('removes the temporary textarea after use', async () => {
    setClipboard(undefined)
    setExec(() => true)
    const before = document.querySelectorAll('textarea').length

    await copyToClipboard('cleanup-test')
    const after = document.querySelectorAll('textarea').length
    expect(after).toBe(before)
  })
})
