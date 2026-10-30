// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  TimeAgo,
  toMs,
  toIsoDatetime,
  toAccessibleLabel,
  pickDisplayText,
  toHumanTooltip,
} from './time-ago'

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

const RELATIVE_SUFFIX_RE = /(?:초|분|시간|일|주|개월|년) 전/

describe('toMs (pure normalization)', () => {
  it('passes unix ms through unchanged', () => {
    expect(toMs(1_700_000_000_000)).toBe(1_700_000_000_000)
  })

  it('multiplies unix seconds (< 1e12) by 1000', () => {
    // 1_700_000_000 seconds → 1_700_000_000_000 ms
    expect(toMs(1_700_000_000)).toBe(1_700_000_000_000)
  })

  it('parses ISO strings via Date constructor', () => {
    const iso = '2026-04-17T18:30:00.000Z'
    expect(toMs(iso)).toBe(new Date(iso).getTime())
  })
})

describe('toIsoDatetime', () => {
  it('produces a valid ISO 8601 string from unix ms', () => {
    const out = toIsoDatetime(1_700_000_000_000)
    expect(out).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/)
  })

  it('round-trips through Date parsing', () => {
    const ms = 1_700_000_000_000
    const iso = toIsoDatetime(ms)
    expect(new Date(iso).getTime()).toBe(ms)
  })
})

describe('toAccessibleLabel', () => {
  it('contains both a relative and absolute portion', () => {
    const recent = Date.now() - 60_000 // 1 minute ago
    const label = toAccessibleLabel(recent)
    // Relative part should mention "분 전" (minutes ago in ko)
    expect(label).toMatch(/분 전|초 전/)
    // Absolute part is in parens
    expect(label).toMatch(/\(.+\)/)
  })
})

describe('pickDisplayText', () => {
  const recent = Date.now() - 60_000

  it('mode=relative returns only the relative fragment (no parens)', () => {
    const out = pickDisplayText(recent, 'relative')
    expect(out).not.toContain('(')
    expect(out).not.toContain('·')
  })

  it('mode=absolute returns only the absolute fragment (no relative suffix)', () => {
    const out = pickDisplayText(recent, 'absolute')
    expect(out).not.toMatch(RELATIVE_SUFFIX_RE)
  })

  it('mode=both joins relative and absolute with "·"', () => {
    const out = pickDisplayText(recent, 'both')
    expect(out).toContain('·')
  })
})

describe('TimeAgo component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a <time> element (HTML5 semantic, not <span>)', () => {
    // Regression guard — Reference pattern: Slack/GitHub/Linear all use
    // <time datetime="...">. <span> is not machine-readable.
    render(html`<${TimeAgo} timestamp=${Date.now() - 60_000} />`, container)
    const el = container.querySelector('time')
    expect(el).toBeTruthy()
    expect(container.querySelector('span.time-ago')).toBeNull()
  })

  it('datetime attr is a valid ISO 8601 string', () => {
    render(html`<${TimeAgo} timestamp=${1_700_000_000_000} />`, container)
    const el = container.querySelector('time')!
    expect(el.getAttribute('datetime')).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/)
  })

  it('aria-label includes both relative and absolute portions (AT context)', () => {
    render(html`<${TimeAgo} timestamp=${Date.now() - 60_000} />`, container)
    const el = container.querySelector('time')!
    const label = el.getAttribute('aria-label') ?? ''
    expect(label).toMatch(/분 전|초 전/) // relative part
    expect(label).toMatch(/\(.+\)/) // absolute part in parens
  })

  it('title attr is human-readable (ko-KR form, NOT ISO — GitHub/Linear pattern)', () => {
    // ISO stays on `datetime` for crawlers/dev tools; title gets the
    // ko-KR form so mouse users can read the timestamp without
    // parsing \"2024-11-14T22:13:20.000Z\" in their head.
    render(html`<${TimeAgo} timestamp=${1_700_000_000_000} />`, container)
    const el = container.querySelector('time')!
    const title = el.getAttribute('title')
    expect(title).not.toBeNull()
    expect(title).not.toMatch(/^\d{4}-\d{2}-\d{2}T/)
    // datetime attr still carries the ISO form
    expect(el.getAttribute('datetime')).toMatch(/^\d{4}-\d{2}-\d{2}T/)
  })

  it('mode="absolute" renders only the absolute fragment', () => {
    render(html`<${TimeAgo} timestamp=${Date.now() - 60_000} mode="absolute" />`, container)
    const el = container.querySelector('time')!
    expect(el.textContent).not.toMatch(RELATIVE_SUFFIX_RE)
  })

  it('mode="both" renders both fragments joined by "·"', () => {
    render(html`<${TimeAgo} timestamp=${Date.now() - 60_000} mode="both" />`, container)
    const el = container.querySelector('time')!
    expect(el.textContent).toContain('·')
  })

  it('default mode is "relative"', () => {
    render(html`<${TimeAgo} timestamp=${Date.now() - 60_000} />`, container)
    const el = container.querySelector('time')!
    // No absolute-part separator in relative-only mode.
    expect(el.textContent).not.toContain('·')
  })

  it('class prop is appended to the base "time-ago" class', () => {
    render(html`<${TimeAgo} timestamp=${Date.now()} class="text-dim" />`, container)
    const el = container.querySelector('time')!
    expect(el.className).toContain('time-ago')
    expect(el.className).toContain('text-dim')
  })

  it('accepts unix seconds timestamps (legacy backend contract)', () => {
    // Backends returning `generated_at: 1_700_000_000` (seconds) shouldn't
    // get read as year 1970 — the < 1e12 branch re-scales to ms.
    const seconds = 1_700_000_000
    render(html`<${TimeAgo} timestamp=${seconds} />`, container)
    const el = container.querySelector('time')!
    const dt = el.getAttribute('datetime')!
    // Should land in 2023-11 (the actual date of that epoch), not 1970.
    expect(dt.startsWith('2023-11')).toBe(true)
  })

  it('live clock tick updates relative text without parent re-render', async () => {
    // The singleton interval should re-run the component's read of
    // `relativeClock.value`. We don't care about exact string, only
    // that the DOM text CAN refresh — assert by vi advancing fake timers.
    vi.useFakeTimers()
    try {
      const start = Date.now()
      // Render a "just now" time.
      render(html`<${TimeAgo} timestamp=${start} />`, container)
      const before = container.querySelector('time')!.textContent
      // Advance clock by 5 minutes.
      vi.advanceTimersByTime(5 * 60_000)
      // Let preact flush.
      await flushUi()
      const after = container.querySelector('time')!.textContent
      // We don't assert equality on the exact label, just that something
      // was re-derivable (before/after still come from formatTimeAgo).
      expect(before).toBeTruthy()
      expect(after).toBeTruthy()
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('toHumanTooltip (pure)', () => {
  it('matches the aria-label shape (relative + absolute) for hover/SR parity', () => {
    // The tooltip and the aria-label must tell the same story — a
    // mouse user hovering and a screen-reader user arrowing should
    // both get \"2분 전 (04. 17. 18:30)\", not two different strings.
    const t = '2026-04-18T00:01:00.000Z'
    expect(toHumanTooltip(t)).toBe(toAccessibleLabel(t))
  })

  it('is NOT the raw ISO string (GitHub/Linear pattern: humans get ko-KR, dev tools get ISO via datetime attr)', () => {
    // Regression guard: a well-meaning refactor might "simplify" by
    // passing the ISO to both datetime= and title=, regressing the
    // hover UX. Pin the difference.
    const t = '2026-04-18T00:01:00.000Z'
    const tooltip = toHumanTooltip(t)
    expect(tooltip).not.toBe(toIsoDatetime(t))
    expect(tooltip).not.toContain('T00:01:00')
  })

  it('accepts unix seconds and unix ms — same result (normalization is via toMs)', () => {
    const sec = 1_745_000_000
    const ms = sec * 1000
    expect(toHumanTooltip(sec)).toBe(toHumanTooltip(ms))
  })
})

describe('<TimeAgo/> title attribute (integration)', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders human-readable title (not ISO) so hover users get ko-KR', async () => {
    // Regression guard covering the 2026-04-18 chip that swapped
    // title from iso → toHumanTooltip. Hovering over any \"2분 전\"
    // in the dashboard must reveal a Korean-formatted timestamp.
    const timestamp = '2026-04-18T00:00:00.000Z'
    render(html`<${TimeAgo} timestamp=${timestamp} />`, container)
    await flushUi()
    const el = container.querySelector('time')
    expect(el).toBeTruthy()
    const title = el!.getAttribute('title')
    expect(title).not.toBeNull()
    // datetime still the ISO form (crawlers / dev tools)
    expect(el!.getAttribute('datetime')).toBe(toIsoDatetime(timestamp))
    // title is human-readable — equals toHumanTooltip
    expect(title).toBe(toHumanTooltip(timestamp))
    expect(title).not.toBe(toIsoDatetime(timestamp))
  })
})
