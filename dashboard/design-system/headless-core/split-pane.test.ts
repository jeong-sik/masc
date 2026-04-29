// Pure TS unit tests for SplitPane. No DOM.
import { describe, it, expect } from 'vitest'
import {
  createSplitPane,
  type SplitKeyEvent,
  type SplitStorage,
} from './split-pane'

function memoryStorage(initial?: Record<string, string>): SplitStorage & {
  readonly map: Map<string, string>
} {
  const map = new Map<string, string>(Object.entries(initial ?? {}))
  return {
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => {
      map.set(key, value)
    },
    map,
  }
}

function makeKey(key: string, shiftKey?: boolean): SplitKeyEvent & {
  _prevented: boolean
} {
  let prevented = false
  return {
    key,
    shiftKey,
    preventDefault() {
      prevented = true
    },
    get _prevented() {
      return prevented
    },
  } as SplitKeyEvent & { _prevented: boolean }
}

describe('createSplitPane — defaults + persistence', () => {
  it('default ratio is 0.5; storage untouched on construct', () => {
    const storage = memoryStorage()
    const sp = createSplitPane({ direction: 'horizontal', persistKey: 'k', storage })
    expect(sp.getRatio()).toBe(0.5)
    expect(storage.map.size).toBe(0)
  })

  it('persists on setRatio + reads back on next construct', () => {
    const storage = memoryStorage()
    const sp1 = createSplitPane({ direction: 'horizontal', persistKey: 'k', storage })
    sp1.setRatio(0.42)
    expect(storage.map.get('k')).toBe('0.42')
    const sp2 = createSplitPane({ direction: 'horizontal', persistKey: 'k', storage })
    expect(sp2.getRatio()).toBe(0.42)
  })

  it('corrupted persisted value falls back to defaultRatio', () => {
    const storage = memoryStorage({ k: 'NaN' })
    const sp = createSplitPane({
      direction: 'horizontal',
      persistKey: 'k',
      defaultRatio: 0.3,
      storage,
    })
    expect(sp.getRatio()).toBe(0.3)
  })

  it('out-of-range persisted value falls back to defaultRatio', () => {
    const storage = memoryStorage({ k: '2.0' })
    const sp = createSplitPane({
      direction: 'horizontal',
      persistKey: 'k',
      defaultRatio: 0.6,
      storage,
    })
    expect(sp.getRatio()).toBe(0.6)
  })
})

describe('createSplitPane — pointer drag (horizontal)', () => {
  it('drag right by 200px on 800px container increases ratio by 0.25', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.5 })
    sp.setContainerSize(800)
    sp.handlePointerDown({ clientX: 100, clientY: 0 })
    sp.handlePointerMove({ clientX: 300, clientY: 0 })
    expect(sp.getRatio()).toBeCloseTo(0.75, 5)
  })

  it('clamps at maxRatio during drag', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.85 })
    sp.setContainerSize(800)
    sp.handlePointerDown({ clientX: 100, clientY: 0 })
    sp.handlePointerMove({ clientX: 1000, clientY: 0 })
    expect(sp.getRatio()).toBe(0.9)
  })
})

describe('createSplitPane — pointer drag (vertical)', () => {
  it('drag down increases ratio (top pane widens)', () => {
    const sp = createSplitPane({ direction: 'vertical', defaultRatio: 0.5 })
    sp.setContainerSize(400)
    sp.handlePointerDown({ clientX: 0, clientY: 100 })
    sp.handlePointerMove({ clientX: 0, clientY: 200 })
    expect(sp.getRatio()).toBeCloseTo(0.75, 5)
  })
})

describe('createSplitPane — pointer up persists', () => {
  it('drag end writes localStorage', () => {
    const storage = memoryStorage()
    const sp = createSplitPane({
      direction: 'horizontal',
      persistKey: 'k',
      storage,
    })
    sp.setContainerSize(1000)
    sp.handlePointerDown({ clientX: 0, clientY: 0 })
    sp.handlePointerMove({ clientX: 100, clientY: 0 })
    expect(storage.map.has('k')).toBe(false)
    sp.handlePointerUp()
    expect(storage.map.get('k')).toBe('0.6')
  })

  it('pointer up without down is no-op', () => {
    const storage = memoryStorage()
    const sp = createSplitPane({
      direction: 'horizontal',
      persistKey: 'k',
      storage,
    })
    sp.handlePointerUp()
    expect(storage.map.size).toBe(0)
  })
})

describe('createSplitPane — keyboard step', () => {
  it('ArrowRight on horizontal advances by 0.02', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.5 })
    sp.handleKeyDown(makeKey('ArrowRight'))
    expect(sp.getRatio()).toBeCloseTo(0.52, 5)
  })

  it('Shift+ArrowRight advances by 0.10 (coarse)', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.5 })
    sp.handleKeyDown(makeKey('ArrowRight', true))
    expect(sp.getRatio()).toBeCloseTo(0.6, 5)
  })

  it('off-axis arrow keys are no-op', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.5 })
    sp.handleKeyDown(makeKey('ArrowUp'))
    expect(sp.getRatio()).toBe(0.5)
  })
})

describe('createSplitPane — Home / End', () => {
  it('Home clamps to minRatio, End to maxRatio; both persist', () => {
    const storage = memoryStorage()
    const sp = createSplitPane({
      direction: 'horizontal',
      defaultRatio: 0.5,
      persistKey: 'k',
      storage,
    })
    sp.handleKeyDown(makeKey('Home'))
    expect(sp.getRatio()).toBe(0.1)
    expect(storage.map.get('k')).toBe('0.1')
    sp.handleKeyDown(makeKey('End'))
    expect(sp.getRatio()).toBe(0.9)
    expect(storage.map.get('k')).toBe('0.9')
  })
})

describe('createSplitPane — Enter toggle collapse', () => {
  it('Enter from default position collapses to second; Enter again expands', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.5 })
    sp.handleKeyDown(makeKey('Enter'))
    // ratio 0.5 vs midpoint (0.1+0.9)/2=0.5 → not less; collapse to 'second'
    expect(sp.isCollapsed()).toBe(true)
    expect(sp.getRatio()).toBe(0.9)
    sp.handleKeyDown(makeKey('Enter'))
    expect(sp.isCollapsed()).toBe(false)
    expect(sp.getRatio()).toBeCloseTo(0.5, 5)
  })

  it('collapse from low ratio targets first side', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.2 })
    sp.handleKeyDown(makeKey('Enter'))
    expect(sp.isCollapsed()).toBe(true)
    expect(sp.getRatio()).toBe(0.1)
  })
})

describe('createSplitPane — splitter ARIA props', () => {
  it('aria-valuenow is integer percent of ratio', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.42 })
    const props = sp.getSplitterProps()
    expect(props['aria-valuenow']).toBe(42)
    expect(props['aria-valuemin']).toBe(10)
    expect(props['aria-valuemax']).toBe(90)
    expect(props['aria-orientation']).toBe('horizontal')
    expect(props.tabIndex).toBe(0)
    expect(props.role).toBe('separator')
  })
})

describe('createSplitPane — subscribe', () => {
  it('subscriber fires on every ratio change including drag', () => {
    const sp = createSplitPane({ direction: 'horizontal', defaultRatio: 0.5 })
    sp.setContainerSize(1000)
    const calls: number[] = []
    const dispose = sp.subscribe((r) => calls.push(r))
    sp.handlePointerDown({ clientX: 0, clientY: 0 })
    sp.handlePointerMove({ clientX: 50, clientY: 0 })
    sp.handlePointerMove({ clientX: 100, clientY: 0 })
    sp.handlePointerUp()
    expect(calls.length).toBe(2) // two move events fired
    dispose()
    sp.handleKeyDown(makeKey('ArrowRight'))
    expect(calls.length).toBe(2) // unsubscribed
  })
})
