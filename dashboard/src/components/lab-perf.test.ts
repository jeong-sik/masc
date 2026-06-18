// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { html } from 'htm/preact'
import { LabPerf } from './lab-perf'

describe('LabPerf', () => {
  beforeEach(() => {
    vi.stubGlobal('requestAnimationFrame', vi.fn(() => 1))
    vi.stubGlobal('cancelAnimationFrame', vi.fn())
    vi.stubGlobal('ResizeObserver', class MockResizeObserver {
      private readonly callback: ResizeObserverCallback

      constructor(callback: ResizeObserverCallback) {
        this.callback = callback
      }

      observe(target: Element) {
        this.callback([{
          target,
          contentRect: { width: 320, height: 96 } as DOMRectReadOnly,
        } as ResizeObserverEntry], this as unknown as ResizeObserver)
      }

      disconnect() {}
    })
    vi.stubGlobal('IntersectionObserver', class MockIntersectionObserver {
      private readonly callback: IntersectionObserverCallback

      constructor(callback: IntersectionObserverCallback) {
        this.callback = callback
      }

      observe(target: Element) {
        this.callback([{
          target,
          isIntersecting: true,
          intersectionRatio: 1,
        } as IntersectionObserverEntry], this as unknown as IntersectionObserver)
      }

      disconnect() {}
    })
    vi.stubGlobal('CSS', {
      supports: vi.fn((property: string, value: string) => property === 'content-visibility' && value === 'auto'),
    })
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
    Reflect.deleteProperty(document, 'startViewTransition')
  })

  it('renders the v2 performance primitives as a visible Lab surface', () => {
    render(html`<${LabPerf} />`)

    expect(screen.getByTestId('lab-perf-surface')).not.toBeNull()
    expect(screen.getByTestId('lab-perf-fps')).not.toBeNull()
    expect(screen.getByTestId('lab-perf-platform')).not.toBeNull()
    expect(screen.getByTestId('lab-perf-observer-probes')).not.toBeNull()
    expect(screen.getByTestId('lab-perf-dialog-demo')).not.toBeNull()
    expect(screen.getByText(/VirtualList · .* rows/)).not.toBeNull()
    expect(screen.getByTestId('lab-perf-virtual-list')).not.toBeNull()
    expect(screen.getByTestId('lab-perf-mode-virtual-list').getAttribute('aria-pressed')).toBe('true')
    expect(screen.getByTestId('lab-perf-capability-content-visibility').getAttribute('data-supported')).toBe('true')
    expect(screen.getByTestId('lab-perf-size-readout').textContent).toContain('320×96')
    expect(screen.getByTestId('lab-perf-inview-readout').getAttribute('data-in-view')).toBe('true')
  })

  it('switches to the content-visibility list demo', () => {
    render(html`<${LabPerf} />`)

    fireEvent.click(screen.getByTestId('lab-perf-mode-content-visibility'))

    expect(screen.getByTestId('lab-perf-mode-content-visibility').getAttribute('aria-pressed')).toBe('true')
    expect(screen.queryByTestId('lab-perf-virtual-list')).toBeNull()
    expect(screen.getByTestId('lab-perf-cv-list').getAttribute('data-cv-total')).toBe('180')
    const rows = screen.getAllByTestId('lab-perf-cv-row')
    expect(rows).toHaveLength(180)
    expect((rows[0] as HTMLElement).style.contentVisibility).toBe('auto')
    expect((rows[0] as HTMLElement).style.containIntrinsicSize).toBe('auto 48px')
  })

  it('uses the View Transitions API when available for mode swaps', () => {
    const startViewTransition = vi.fn((mutate: () => void) => {
      mutate()
      return {}
    })
    Object.defineProperty(document, 'startViewTransition', {
      configurable: true,
      value: startViewTransition,
    })

    render(html`<${LabPerf} />`)
    fireEvent.click(screen.getByTestId('lab-perf-mode-content-visibility'))

    expect(startViewTransition).toHaveBeenCalledTimes(1)
    expect(screen.getByTestId('lab-perf-cv-list')).not.toBeNull()
  })

  it('opens and closes the native dialog demo', () => {
    render(html`<${LabPerf} />`)

    fireEvent.click(screen.getByTestId('lab-perf-dialog-open'))
    const dialog = screen.getByTestId('lab-perf-native-dialog') as HTMLDialogElement

    expect(dialog.hasAttribute('open')).toBe(true)
    expect(dialog.getAttribute('aria-labelledby')).toBe('lab-perf-dialog-title')
    expect(dialog.textContent).toContain('Native top-layer dialog')

    fireEvent.click(screen.getByTestId('lab-perf-dialog-close'))

    expect(dialog.hasAttribute('open')).toBe(false)
  })

  it('lets the native cancel event close the dialog demo', () => {
    render(html`<${LabPerf} />`)

    fireEvent.click(screen.getByTestId('lab-perf-dialog-open'))
    const dialog = screen.getByTestId('lab-perf-native-dialog') as HTMLDialogElement
    expect(dialog.hasAttribute('open')).toBe(true)

    fireEvent(dialog, new Event('cancel', { cancelable: true }))

    expect(dialog.hasAttribute('open')).toBe(false)
  })
})
