import { html } from 'htm/preact'
import { cleanup, fireEvent, render } from '@testing-library/preact'
import { useRef } from 'preact/hooks'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  SplitHandle,
  clampSplitSize,
  resetSplitSizeCacheForTests,
  splitStorageKey,
  useSplitSize,
} from './split-handle'

describe('SplitHandle & useSplitSize', () => {
  beforeEach(() => {
    window.localStorage.clear()
    resetSplitSizeCacheForTests()
    delete document.body.dataset.resizing
  })

  afterEach(() => {
    cleanup()
    delete document.body.dataset.resizing
    resetSplitSizeCacheForTests()
  })

  it('clamps split sizes and persists committed values under masc:split:<id>:v1', () => {
    expect(clampSplitSize(120, 200, 440, 260)).toBe(200)
    expect(clampSplitSize(999, 200, 440, 260)).toBe(440)
    expect(clampSplitSize(NaN, 200, 440, 260)).toBe(260)

    function Host() {
      const ref = useRef<HTMLDivElement>(null)
      const { size, setSize } = useSplitSize({ id: 'test-pane', defaultSize: 260, min: 200, max: 440 })
      return html`
        <div ref=${ref} data-testid="host" style=${{ '--pane-w': `${size}px` } as Record<string, string>}>
          <${SplitHandle}
            id="test-pane"
            orientation="vertical"
            value=${size}
            defaultSize=${260}
            min=${200}
            max=${440}
            cssVar="--pane-w"
            targetRef=${ref}
            onChange=${setSize}
            label="테스트 패널 너비"
          />
        </div>
      `
    }

    const view = render(html`<${Host} />`)
    const handle = view.getByRole('separator')
    expect(handle.getAttribute('aria-orientation')).toBe('vertical')
    expect(handle.getAttribute('aria-valuemin')).toBe('200')
    expect(handle.getAttribute('aria-valuemax')).toBe('440')
    expect(handle.getAttribute('aria-valuenow')).toBe('260')

    // ArrowRight (+16), Shift+ArrowRight (+48), Home (min), End (max), Enter (default)
    fireEvent.keyDown(handle, { key: 'ArrowRight' })
    expect(handle.getAttribute('aria-valuenow')).toBe('276')
    expect(window.localStorage.getItem(splitStorageKey('test-pane'))).toBe('276')

    fireEvent.keyDown(handle, { key: 'ArrowRight', shiftKey: true })
    expect(handle.getAttribute('aria-valuenow')).toBe('324')

    fireEvent.keyDown(handle, { key: 'Home' })
    expect(handle.getAttribute('aria-valuenow')).toBe('200')

    fireEvent.keyDown(handle, { key: 'End' })
    expect(handle.getAttribute('aria-valuenow')).toBe('440')

    fireEvent.keyDown(handle, { key: 'Enter' })
    expect(handle.getAttribute('aria-valuenow')).toBe('260')

    // Double-click resets to default
    fireEvent.keyDown(handle, { key: 'End' })
    expect(handle.getAttribute('aria-valuenow')).toBe('440')
    fireEvent.dblClick(handle)
    expect(handle.getAttribute('aria-valuenow')).toBe('260')
  })

  it('writes CSS var directly during pointermove without calling onChange until pointerup/pointercancel', () => {
    const onChange = vi.fn()

    function DragHost() {
      const ref = useRef<HTMLDivElement>(null)
      return html`
        <div
          ref=${ref}
          data-testid="drag-host"
          style=${{ '--qpeek-w': '480px' } as Record<string, string>}
        >
          <${SplitHandle}
            id="drawer-drag"
            orientation="vertical"
            value=${480}
            defaultSize=${480}
            min=${360}
            max=${960}
            cssVar="--qpeek-w"
            targetRef=${ref}
            onChange=${onChange}
            reverse=${true}
            label="서랍 너비"
          />
        </div>
      `
    }

    const view = render(html`<${DragHost} />`)
    const hostEl = view.getByTestId('drag-host')
    const handle = view.getByRole('separator')

    fireEvent.pointerDown(handle, { button: 0, clientX: 500, pointerId: 1 })
    expect(document.body.dataset.resizing).toBe('col')

    // Moving left by 100px with reverse=true expands drawer from 480 -> 580
    fireEvent(window, new PointerEvent('pointermove', { clientX: 400 }))
    expect(hostEl.style.getPropertyValue('--qpeek-w')).toBe('580px')
    expect(handle.getAttribute('aria-valuenow')).toBe('580')
    expect(onChange).not.toHaveBeenCalled()

    // pointercancel cleans up body[data-resizing] and commits final size once
    fireEvent(window, new PointerEvent('pointercancel', { clientX: 400 }))
    expect(document.body.dataset.resizing).toBeUndefined()
    expect(onChange).toHaveBeenCalledTimes(1)
    expect(onChange).toHaveBeenCalledWith(580)
  })
})
