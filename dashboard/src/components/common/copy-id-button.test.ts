import { describe, it, expect, vi, afterEach } from 'vitest'
import { copyToClipboard } from './copyable-code'

// happy-dom does not expose `document.execCommand` by default. Assign/delete
// directly rather than spying on an undefined property.

type ExecCommandFn = (cmd: string) => boolean
// Loose-type escape hatch — `Document.execCommand` is declared non-optional
// in lib.dom.d.ts, but happy-dom omits it, so we need to both assign and
// delete the property through a typed-any reference.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const doc = document as any

describe('copyToClipboard', () => {
  const realClipboard = typeof navigator !== 'undefined' ? navigator.clipboard : undefined
  const realExec: ExecCommandFn | undefined = doc.execCommand

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
    setClipboard(realClipboard as unknown as { writeText: (t: string) => Promise<void> } | undefined)
    setExec(realExec)
    vi.restoreAllMocks()
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
