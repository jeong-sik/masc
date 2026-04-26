// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  HeartbeatStreakChip,
  formatStreakLabel,
} from './heartbeat-streak-chip'
import {
  currentHeartbeatStreak,
  type HeartbeatState,
} from '../../lib/heartbeat-history'

describe('currentHeartbeatStreak (pure, lib-level)', () => {
  it('returns null for empty history', () => {
    expect(currentHeartbeatStreak([])).toBeNull()
  })

  it('counts a single trailing sample as streak of 1', () => {
    expect(currentHeartbeatStreak(['up'])).toEqual({ state: 'up', samples: 1 })
  })

  it('counts contiguous trailing same-state samples', () => {
    expect(currentHeartbeatStreak(['up', 'up', 'up'])).toEqual({
      state: 'up', samples: 3,
    })
  })

  it('stops at the first state change walking backwards from the tail', () => {
    // down, down, up, up, up — trailing streak is 3 up
    expect(currentHeartbeatStreak(['down', 'down', 'up', 'up', 'up']))
      .toEqual({ state: 'up', samples: 3 })
  })

  it('treats interruptions correctly (streak restarts)', () => {
    // up, up, down, up — tail is "up" but previous sample was "down",
    // so streak is just 1 (the final up alone)
    expect(currentHeartbeatStreak(['up', 'up', 'down', 'up']))
      .toEqual({ state: 'up', samples: 1 })
  })

  it('handles an unknown-dominant tail', () => {
    expect(currentHeartbeatStreak(['up', 'unknown', 'unknown']))
      .toEqual({ state: 'unknown', samples: 2 })
  })

  it('counts the full history when everything is the same state', () => {
    const all: HeartbeatState[] = ['down', 'down', 'down', 'down']
    expect(currentHeartbeatStreak(all)).toEqual({ state: 'down', samples: 4 })
  })
})

describe('formatStreakLabel (pure)', () => {
  it('"no data yet" when streak is null', () => {
    expect(formatStreakLabel(null)).toBe('Heartbeat: no data yet')
  })

  it('singular "check" for samples=1', () => {
    expect(formatStreakLabel({ state: 'up', samples: 1 })).toBe('UP for 1 check')
  })

  it('plural "checks" for samples>1', () => {
    expect(formatStreakLabel({ state: 'up', samples: 22 })).toBe('UP for 22 checks')
    expect(formatStreakLabel({ state: 'down', samples: 3 })).toBe('DOWN for 3 checks')
  })

  it('unknown state renders as "N/A"', () => {
    expect(formatStreakLabel({ state: 'unknown', samples: 5 })).toBe('N/A for 5 checks')
  })
})

describe('HeartbeatStreakChip component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders nothing for an empty history (no stubby "0 checks" placeholder)', () => {
    // Regression guard: an empty history should be invisible, not a
    // zero-count chip. The HeartbeatStrip below the chip already
    // shows the unknown-padding row — the chip would be redundant.
    render(html`<${HeartbeatStreakChip} history=${[]} />`, container)
    expect(container.querySelector('[data-heartbeat-streak-chip]')).toBeNull()
  })

  it('renders state + sample count in visible text', () => {
    render(
      html`<${HeartbeatStreakChip} history=${['up', 'up', 'up']} />`,
      container,
    )
    const el = container.querySelector('[data-heartbeat-streak-chip]') as HTMLElement
    expect(el).toBeTruthy()
    expect(el.textContent).toContain('UP')
    expect(el.textContent).toContain('3')
  })

  it('tone class reflects state — ok for up, bad for down, muted for unknown', () => {
    render(html`<${HeartbeatStreakChip} history=${['up', 'up']} />`, container)
    let el = container.querySelector('[data-heartbeat-streak-chip]')!
    expect(el.className).toContain('var(--color-status-ok)')
    render(null, container)

    render(html`<${HeartbeatStreakChip} history=${['down']} />`, container)
    el = container.querySelector('[data-heartbeat-streak-chip]')!
    expect(el.className).toContain('var(--bad-light)')
    render(null, container)

    render(html`<${HeartbeatStreakChip} history=${['unknown']} />`, container)
    el = container.querySelector('[data-heartbeat-streak-chip]')!
    expect(el.className).toContain('text-[var(--color-fg-disabled)]')
  })

  it('data attrs pin state + samples for E2E selectors', () => {
    render(html`<${HeartbeatStreakChip} history=${['down', 'down', 'down']} />`, container)
    const el = container.querySelector('[data-heartbeat-streak-chip]')!
    expect(el.getAttribute('data-heartbeat-streak-state')).toBe('down')
    expect(el.getAttribute('data-heartbeat-streak-samples')).toBe('3')
  })

  it('title + aria-label both carry the narrative label (AT + hover parity)', () => {
    render(html`<${HeartbeatStreakChip} history=${['up', 'up']} />`, container)
    const el = container.querySelector('[data-heartbeat-streak-chip]')!
    expect(el.getAttribute('title')).toBe('UP for 2 checks')
    expect(el.getAttribute('aria-label')).toBe('UP for 2 checks')
  })

  it('uses tabular-nums so the sample count aligns across chips', () => {
    // Regression guard — 4 connector tiles side-by-side, a "1" vs "11"
    // width mismatch makes the chips "dance" visually.
    render(html`<${HeartbeatStreakChip} history=${['up']} />`, container)
    expect(container.querySelector('[data-heartbeat-streak-chip]')!.className)
      .toContain('tabular-nums')
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${HeartbeatStreakChip} history=${['up']} testId="discord-streak" />`,
      container,
    )
    expect(container.querySelector('[data-testid="discord-streak"]')).toBeTruthy()
  })
})
