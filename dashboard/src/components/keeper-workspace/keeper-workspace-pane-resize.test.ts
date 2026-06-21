// @vitest-environment happy-dom
import { afterEach, describe, expect, it } from 'vitest'
import {
  beginPaneResize,
  clampPaneWidth,
  rosterWidth,
  railWidth,
  DEFAULT_ROSTER_WIDTH,
  DEFAULT_RAIL_WIDTH,
} from './keeper-workspace-pane-resize'

afterEach(() => {
  rosterWidth.value = DEFAULT_ROSTER_WIDTH
  railWidth.value = DEFAULT_RAIL_WIDTH
  document.body.classList.remove('kw-resizing')
})

describe('clampPaneWidth', () => {
  it('clamps the roster to 200..440 and rounds', () => {
    expect(clampPaneWidth('roster', 10)).toBe(200)
    expect(clampPaneWidth('roster', 9999)).toBe(440)
    expect(clampPaneWidth('roster', 312.6)).toBe(313)
  })

  it('clamps the rail to 240..480', () => {
    expect(clampPaneWidth('rail', 0)).toBe(240)
    expect(clampPaneWidth('rail', 9999)).toBe(480)
    expect(clampPaneWidth('rail', 300)).toBe(300)
  })

  it('falls back to the minimum for non-finite input (defensive floor)', () => {
    expect(clampPaneWidth('roster', Number.NaN)).toBe(200)
    expect(clampPaneWidth('rail', Number.POSITIVE_INFINITY)).toBe(240)
  })
})

describe('beginPaneResize', () => {
  function pointer(type: string, clientX: number): MouseEvent {
    // happy-dom lacks PointerEvent; a MouseEvent with the pointer* type name
    // still triggers the listeners and carries clientX, which is all the
    // handler reads.
    return new MouseEvent(type, { clientX, bubbles: true })
  }

  it('updates the CSS var live during the drag WITHOUT touching the signal, then persists on release', () => {
    const grid = document.createElement('div')
    document.body.appendChild(grid)
    const down = { clientX: 100, preventDefault: () => {} } as unknown as PointerEvent

    beginPaneResize('roster', down, grid)
    expect(document.body.classList.contains('kw-resizing')).toBe(true)

    window.dispatchEvent(pointer('pointermove', 150)) // +50 → 286+50 = 336
    expect(grid.style.getPropertyValue('--kw-roster-w')).toBe('336px')
    // mid-drag the persisted signal must NOT change (no re-render of the subtree)
    expect(rosterWidth.value).toBe(DEFAULT_ROSTER_WIDTH)

    window.dispatchEvent(pointer('pointerup', 150))
    expect(rosterWidth.value).toBe(336)
    expect(document.body.classList.contains('kw-resizing')).toBe(false)

    grid.remove()
  })

  it('clamps the rail and inverts the drag direction (grows when dragging left)', () => {
    const grid = document.createElement('div')
    document.body.appendChild(grid)
    const down = { clientX: 500, preventDefault: () => {} } as unknown as PointerEvent

    beginPaneResize('rail', down, grid) // startW = 312
    window.dispatchEvent(pointer('pointermove', 400)) // dragging left 100 → 312+100 = 412
    expect(grid.style.getPropertyValue('--kw-rail-w')).toBe('412px')
    window.dispatchEvent(pointer('pointermove', 0)) // far left → clamp 480
    expect(grid.style.getPropertyValue('--kw-rail-w')).toBe('480px')
    window.dispatchEvent(pointer('pointerup', 0))
    expect(railWidth.value).toBe(480)

    grid.remove()
  })

  it('tears down on pointercancel (gesture stolen) — persists width, drops body class and listeners', () => {
    const grid = document.createElement('div')
    document.body.appendChild(grid)
    beginPaneResize('roster', { clientX: 100, preventDefault: () => {} } as unknown as PointerEvent, grid)
    window.dispatchEvent(pointer('pointermove', 140)) // 286+40 = 326
    expect(grid.style.getPropertyValue('--kw-roster-w')).toBe('326px')

    window.dispatchEvent(pointer('pointercancel', 140))
    expect(rosterWidth.value).toBe(326) // last width is persisted
    expect(document.body.classList.contains('kw-resizing')).toBe(false)

    window.dispatchEvent(pointer('pointermove', 999)) // listener should be gone
    expect(grid.style.getPropertyValue('--kw-roster-w')).toBe('326px') // unchanged
    grid.remove()
  })

  it('stops responding to pointermove after release', () => {
    const grid = document.createElement('div')
    document.body.appendChild(grid)
    beginPaneResize('roster', { clientX: 100, preventDefault: () => {} } as unknown as PointerEvent, grid)
    window.dispatchEvent(pointer('pointermove', 130)) // 286+30 = 316
    expect(grid.style.getPropertyValue('--kw-roster-w')).toBe('316px')
    window.dispatchEvent(pointer('pointerup', 130))
    expect(rosterWidth.value).toBe(316)
    window.dispatchEvent(pointer('pointermove', 999)) // listener should be gone
    expect(grid.style.getPropertyValue('--kw-roster-w')).toBe('316px') // unchanged
    grid.remove()
  })
})
