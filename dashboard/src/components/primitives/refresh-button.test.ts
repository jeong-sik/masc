import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { REFRESH_AGAIN_HINT, REFRESH_BUSY_LABEL, REFRESH_MIN_BUSY_MS, RefreshButton } from './index'

interface PendingRead {
  readonly promise: Promise<void>
  readonly end: () => void
}

function pendingRead(): PendingRead {
  let end: () => void = () => {}
  const promise = new Promise<void>((resolve) => {
    end = resolve
  })
  return { promise, end }
}

describe('components/primitives RefreshButton', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.useFakeTimers()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.useRealTimers()
  })

  const button = (): HTMLButtonElement => {
    const found = container.querySelector('button')
    if (found === null) throw new Error('the refresh button is not rendered')
    return found
  }
  const shownLabel = (): string => button().textContent?.trim() ?? ''

  const mount = async (onRefresh: () => Promise<unknown>, label?: string): Promise<void> => {
    await act(() => {
      render(html`<${RefreshButton} onRefresh=${onRefresh} label=${label} />`, container)
    })
  }
  const press = async (): Promise<void> => {
    await act(() => {
      button().click()
    })
  }
  /** Lets `ms` pass, with every promise that settles on the way. */
  const pass = async (ms: number): Promise<void> => {
    await act(async () => {
      await vi.advanceTimersByTimeAsync(ms)
    })
  }

  it('says a read is in flight from the press until the read ends', async () => {
    const read = pendingRead()
    let started = 0
    await mount(() => {
      started += 1
      return read.promise
    })
    expect(shownLabel()).toBe('새로고침')
    expect(button().getAttribute('aria-busy')).toBe('false')

    await press()
    expect(started).toBe(1)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)
    expect(button().getAttribute('aria-busy')).toBe('true')
    expect(button().getAttribute('title')).toBe(REFRESH_AGAIN_HINT)
    expect(button().hasAttribute('aria-disabled')).toBe(false)
    expect(button().disabled).toBe(false)

    // The read outlasts the minimum time: the label follows the read.
    await pass(REFRESH_MIN_BUSY_MS * 3)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)

    read.end()
    await pass(0)
    expect(shownLabel()).toBe('새로고침')
    expect(button().getAttribute('aria-busy')).toBe('false')
    expect(button().title).toBe('')
  })

  it('keeps the in-flight label for the minimum time when the read ends at once', async () => {
    await mount(() => Promise.resolve())

    await press()
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)

    await pass(REFRESH_MIN_BUSY_MS - 1)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)
    expect(button().getAttribute('aria-busy')).toBe('true')

    await pass(1)
    expect(shownLabel()).toBe('새로고침')
    expect(button().getAttribute('aria-busy')).toBe('false')
  })

  it('starts the read again on a press while a read is out, and follows the later read', async () => {
    const reads = [pendingRead(), pendingRead()]
    let started = 0
    await mount(() => {
      const read = reads[started]
      started += 1
      if (read === undefined) throw new Error('more reads started than the test prepared')
      return read.promise
    })

    await press()
    expect(started).toBe(1)

    // The first read does not answer. The minimum time of the label is long over.
    await pass(REFRESH_MIN_BUSY_MS * 3)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)
    await press()
    expect(started).toBe(2)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)

    // The later read ends well after its press: the label comes down with it,
    // whether or not the read it replaced ever ends.
    await pass(REFRESH_MIN_BUSY_MS * 2)
    reads[1]?.end()
    await pass(0)
    expect(shownLabel()).toBe('새로고침')
    expect(button().getAttribute('aria-busy')).toBe('false')
  })

  it('keeps the label up when the read a later press replaced ends first', async () => {
    const reads = [pendingRead(), pendingRead()]
    let started = 0
    await mount(() => {
      const read = reads[started]
      started += 1
      if (read === undefined) throw new Error('more reads started than the test prepared')
      return read.promise
    })

    await press()
    await pass(REFRESH_MIN_BUSY_MS * 2)
    await press()

    // The replaced read ends (a cache read ends when it is aborted).
    reads[0]?.end()
    await pass(REFRESH_MIN_BUSY_MS * 2)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)
    expect(button().getAttribute('aria-busy')).toBe('true')

    reads[1]?.end()
    await pass(0)
    expect(shownLabel()).toBe('새로고침')
  })

  it('takes a press after the read has ended while the label is still up, and holds the label for it', async () => {
    let started = 0
    await mount(() => {
      started += 1
      return Promise.resolve()
    })

    await press()
    await pass(REFRESH_MIN_BUSY_MS - 100)
    // The first read ended at once. Its label has 100 ms left.
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)
    await press()
    expect(started).toBe(2)

    // The time of the first press is over: the label stays for the second.
    await pass(100)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)
    await pass(REFRESH_MIN_BUSY_MS - 101)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)
    expect(button().getAttribute('aria-busy')).toBe('true')

    await pass(1)
    expect(shownLabel()).toBe('새로고침')
    expect(button().getAttribute('aria-busy')).toBe('false')
  })

  it('leaves the label up for a later read when the time of an earlier press ends', async () => {
    const later = pendingRead()
    let started = 0
    await mount(() => {
      started += 1
      return started === 1 ? Promise.resolve() : later.promise
    })

    await press()
    await pass(100)
    await press()
    expect(started).toBe(2)

    // 400 ms after the first press, 300 after the second: its read is out.
    await pass(REFRESH_MIN_BUSY_MS - 100)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)

    // The second press is 1000 ms old when its read ends: nothing holds the label.
    await pass(700)
    expect(shownLabel()).toBe(REFRESH_BUSY_LABEL)
    later.end()
    await pass(0)
    expect(shownLabel()).toBe('새로고침')
  })

  it('hands both labels to CSS so the button is as wide as the wider one', async () => {
    await mount(() => Promise.resolve(), '스키마 새로고침')
    expect(shownLabel()).toBe('스키마 새로고침')
    expect(button().dataset.label).toBe('스키마 새로고침')
    expect(button().dataset.busyLabel).toBe(REFRESH_BUSY_LABEL)
    expect(button().classList.contains('refresh-btn')).toBe(true)
  })

  it('ends quietly when the toolbar is gone before the read ends', async () => {
    const read = pendingRead()
    await mount(() => read.promise)
    await press()
    await act(() => {
      render(null, container)
    })
    read.end()
    await pass(REFRESH_MIN_BUSY_MS)
    expect(container.querySelector('button')).toBeNull()
  })
})
