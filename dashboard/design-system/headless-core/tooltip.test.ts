// Pure TS unit tests for Tooltip + TooltipManager. No DOM, no Preact.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createTooltip, type TooltipKeyEvent } from './tooltip'
import { createTooltipManager } from './tooltip-manager'

function makeKey(key: string): TooltipKeyEvent & { _prevented: boolean } {
  let prevented = false
  return {
    key,
    preventDefault() {
      prevented = true
    },
    get _prevented() {
      return prevented
    },
  } as TooltipKeyEvent & { _prevented: boolean }
}

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createTooltip — show/hide delays', () => {
  it('handleTriggerMouseEnter -> 300ms -> isOpen=true', () => {
    const t = createTooltip({ id: 'tip-1' })
    t.handleTriggerMouseEnter()
    expect(t.isOpen).toBe(false)
    vi.advanceTimersByTime(299)
    expect(t.isOpen).toBe(false)
    vi.advanceTimersByTime(1)
    expect(t.isOpen).toBe(true)
  })

  it('default hideDelay 0 -> immediate hide on mouseLeave', () => {
    const t = createTooltip({ id: 'tip-1', showDelay: 0 })
    t.handleTriggerMouseEnter()
    expect(t.isOpen).toBe(true)
    t.handleTriggerMouseLeave()
    expect(t.isOpen).toBe(false)
  })

  it('non-zero hideDelay defers close', () => {
    const t = createTooltip({ id: 'tip-1', showDelay: 0, hideDelay: 200 })
    t.handleTriggerMouseEnter()
    expect(t.isOpen).toBe(true)
    t.handleTriggerMouseLeave()
    expect(t.isOpen).toBe(true)
    vi.advanceTimersByTime(199)
    expect(t.isOpen).toBe(true)
    vi.advanceTimersByTime(1)
    expect(t.isOpen).toBe(false)
  })

  it('cancel show on early leave', () => {
    const t = createTooltip({ id: 'tip-1' })
    t.handleTriggerMouseEnter()
    vi.advanceTimersByTime(100)
    t.handleTriggerMouseLeave()
    vi.advanceTimersByTime(500)
    expect(t.isOpen).toBe(false)
  })

  it('cancel hide on content re-enter', () => {
    const t = createTooltip({ id: 'tip-1', showDelay: 0, hideDelay: 200 })
    t.handleTriggerMouseEnter()
    expect(t.isOpen).toBe(true)
    t.handleTriggerMouseLeave()
    // simulate user moving to the content body before hide fires
    vi.advanceTimersByTime(50)
    t.handleContentMouseEnter()
    vi.advanceTimersByTime(500)
    expect(t.isOpen).toBe(true)
    // leaving content starts hide again
    t.handleContentMouseLeave()
    vi.advanceTimersByTime(200)
    expect(t.isOpen).toBe(false)
  })
})

describe('createTooltip — focus + Esc lifecycle', () => {
  it('focus shows / blur hides (keyboard parity)', () => {
    const t = createTooltip({ id: 'tip-1', showDelay: 0 })
    t.handleTriggerFocus()
    expect(t.isOpen).toBe(true)
    t.handleTriggerBlur()
    expect(t.isOpen).toBe(false)
  })

  it('Esc bypasses delays and hides immediately', () => {
    const t = createTooltip({ id: 'tip-1', showDelay: 0, hideDelay: 500 })
    t.handleTriggerMouseEnter()
    expect(t.isOpen).toBe(true)
    const event = makeKey('Escape')
    t.handleTriggerKeyDown(event)
    expect(t.isOpen).toBe(false)
    expect(event._prevented).toBe(true)
  })

  it('Esc when closed is a no-op', () => {
    const t = createTooltip({ id: 'tip-1' })
    const event = makeKey('Escape')
    t.handleTriggerKeyDown(event)
    expect(t.isOpen).toBe(false)
    expect(event._prevented).toBe(false)
  })
})

describe('createTooltipManager — one-at-a-time', () => {
  it('opening B hides A', () => {
    const manager = createTooltipManager()
    const a = createTooltip({ id: 'a', showDelay: 0, manager })
    const b = createTooltip({ id: 'b', showDelay: 0, manager })
    a.handleTriggerMouseEnter()
    expect(a.isOpen).toBe(true)
    b.handleTriggerMouseEnter()
    expect(a.isOpen).toBe(false)
    expect(b.isOpen).toBe(true)
    expect(manager.active()?.id).toBe('b')
  })

  it('skip-window flags rapid switches for animation suppression', () => {
    const manager = createTooltipManager({ skipWindowMs: 100 })
    const a = createTooltip({ id: 'a', showDelay: 0, manager })
    const b = createTooltip({ id: 'b', showDelay: 0, manager })
    const events: Array<{ id: string; skip: boolean }> = []
    manager.subscribeClose((e) => events.push({ id: e.id, skip: e.skip }))
    a.handleTriggerMouseEnter()
    a.handleTriggerMouseLeave()
    // close fires with skip=false (no follow-up open yet)
    expect(events).toEqual([{ id: 'a', skip: false }])
    // user darts to a sibling within 100ms
    vi.advanceTimersByTime(50)
    b.handleTriggerMouseEnter()
    expect(b.isOpen).toBe(true)
    // a was already closed; no double-emit triggered
    expect(events.filter((e) => e.id === 'a').length).toBe(1)
  })

  it('manager.closeAll() force-closes any active tooltip', () => {
    const manager = createTooltipManager()
    const a = createTooltip({ id: 'a', showDelay: 0, manager })
    a.handleTriggerMouseEnter()
    expect(a.isOpen).toBe(true)
    manager.closeAll()
    expect(a.isOpen).toBe(false)
    expect(manager.active()).toBeNull()
  })
})

describe('createTooltip — destroy / subscribe', () => {
  it('destroy clears pending timers and emits close', () => {
    const t = createTooltip({ id: 'tip-1' })
    const opens: boolean[] = []
    t.subscribe((open) => opens.push(open))
    t.handleTriggerMouseEnter()
    vi.advanceTimersByTime(150)
    t.destroy()
    vi.advanceTimersByTime(500)
    // no open event fired (timer cleared); no leak after destroy
    expect(opens).toEqual([])
    expect(t.isOpen).toBe(false)
  })

  it('subscribe / unsubscribe is leak-safe', () => {
    const t = createTooltip({ id: 'tip-1', showDelay: 0 })
    const fired: boolean[] = []
    const dispose = t.subscribe((open) => fired.push(open))
    t.handleTriggerMouseEnter()
    expect(fired).toEqual([true])
    dispose()
    t.handleTriggerMouseLeave()
    expect(fired).toEqual([true])
  })
})

describe('createTooltip — controlled mode', () => {
  it('open: true skips internal mutation; onOpenChange still fires', () => {
    const events: boolean[] = []
    const t = createTooltip({
      id: 'tip-1',
      open: true,
      onOpenChange: (o) => events.push(o),
    })
    expect(t.isOpen).toBe(true)
    t.handleTriggerMouseLeave()
    // hideDelay default 0; in controlled mode we still emit but don't
    // mutate isOpen (parent owns the value).
    expect(events).toEqual([false])
    expect(t.isOpen).toBe(true)
  })
})

describe('createTooltip — ARIA id', () => {
  it('id is exposed verbatim from opts', () => {
    const t = createTooltip({ id: 'tooltip-explicit' })
    expect(t.id).toBe('tooltip-explicit')
  })
})
