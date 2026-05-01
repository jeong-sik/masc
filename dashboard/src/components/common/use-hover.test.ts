// @ts-nocheck
import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { useHover } from './use-hover'

describe('useHover', () => {
  function makePointerEvent(type: string, pointerType: string): PointerEvent {
    try {
      return new PointerEvent(type, { pointerType })
    } catch {
      const ev = new Event(type) as PointerEvent
      Object.defineProperty(ev, 'pointerType', { value: pointerType })
      return ev
    }
  }

  it('starts not hovered', () => {
    let result: ReturnType<typeof useHover>
    function Test() {
      result = useHover()
      return h('div', result.hoverProps, 'test')
    }
    render(h(Test), document.createElement('div'))
    expect(result!.hovered).toBe(false)
    expect(result!.hoverProps['data-hovered']).toBeUndefined()
  })

  it('sets hovered on mouse pointer enter', async () => {
    let result: ReturnType<typeof useHover>
    function Test() {
      result = useHover()
      return h('div', result.hoverProps, 'test')
    }
    const container = document.createElement('div')
    render(h(Test), container)
    const el = container.querySelector('div') as HTMLDivElement
    el.dispatchEvent(makePointerEvent('pointerenter', 'mouse'))
    await new Promise(r => setTimeout(r, 0))
    expect(result!.hovered).toBe(true)
    expect(result!.hoverProps['data-hovered']).toBe('true')
  })

  it('ignores touch pointer enter', () => {
    let result: ReturnType<typeof useHover>
    function Test() {
      result = useHover()
      return h('div', result.hoverProps, 'test')
    }
    const container = document.createElement('div')
    render(h(Test), container)
    const el = container.querySelector('div') as HTMLDivElement
    el.dispatchEvent(makePointerEvent('pointerenter', 'touch'))
    expect(result!.hovered).toBe(false)
  })

  it('clears hovered on pointer leave after mouse', () => {
    let result: ReturnType<typeof useHover>
    function Test() {
      result = useHover()
      return h('div', result.hoverProps, 'test')
    }
    const container = document.createElement('div')
    render(h(Test), container)
    const el = container.querySelector('div') as HTMLDivElement
    el.dispatchEvent(makePointerEvent('pointerenter', 'mouse'))
    el.dispatchEvent(makePointerEvent('pointerleave', 'mouse'))
    expect(result!.hovered).toBe(false)
    expect(result!.hoverProps['data-hovered']).toBeUndefined()
  })

  it('does not clear hovered on leave after touch', () => {
    let result: ReturnType<typeof useHover>
    function Test() {
      result = useHover()
      return h('div', result.hoverProps, 'test')
    }
    const container = document.createElement('div')
    render(h(Test), container)
    const el = container.querySelector('div') as HTMLDivElement
    el.dispatchEvent(makePointerEvent('pointerenter', 'touch'))
    el.dispatchEvent(makePointerEvent('pointerleave', 'mouse'))
    expect(result!.hovered).toBe(false)
  })
})
