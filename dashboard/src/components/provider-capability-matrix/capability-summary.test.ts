// @vitest-environment happy-dom
import { describe, it, expect } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { CapabilitySummaryStrip } from './capability-summary'
import { ANTI_PATTERNS, FEATURES } from './data'

describe('CapabilitySummaryStrip', () => {
  function mount(props: { liveProviders?: any[] }) {
    const container = document.createElement('div')
    render(html`<${CapabilitySummaryStrip} ...${props} />`, container)
    return container
  }

  it('renders with correct number of KPI cells', () => {
    const el = mount({ liveProviders: [] })
    const cells = el.querySelectorAll('[role="listitem"]')
    // 6 metrics: spotlight + anti-patterns + coverage + BFCL + live providers + wiring gaps
    expect(cells.length).toBe(6)
  })

  it('spotlights high-impact wiring gaps when present', () => {
    const el = mount({ liveProviders: [] })
    const cells = el.querySelectorAll('[role="listitem"]')
    const spotlight = cells[0]!
    expect(spotlight.getAttribute('aria-label')).toContain('(spotlight)')
    expect(spotlight.textContent).toContain('◆')
    expect(spotlight.textContent).toContain('배선')
  })

  it('shows anti-pattern count with silent failure caption', () => {
    const el = mount({ liveProviders: [] })
    const text = el.textContent ?? ''
    expect(text).toContain('안티패턴')
    const silentCount = ANTI_PATTERNS.filter(a => a.category === 'silent-failure').length
    expect(text).toContain(`${silentCount} silent`)
  })

  it('shows low coverage feature count', () => {
    const el = mount({ liveProviders: [] })
    const text = el.textContent ?? ''
    expect(text).toContain('저커버리지')
    const providerCount = 13
    const lowCount = FEATURES.filter(f => {
      const fullCount = Object.values(f.providers).filter(v => v === '●').length
      return fullCount / providerCount < 0.5
    }).length
    expect(text).toContain(String(lowCount))
  })

  it('warns when no live providers', () => {
    const el = mount({ liveProviders: [] })
    const text = el.textContent ?? ''
    expect(text).toContain('no live data')
  })

  it('shows live provider count when available', () => {
    const el = mount({ liveProviders: [{ kind: 'anthropic' }, { kind: 'openai' }] })
    const text = el.textContent ?? ''
    expect(text).toContain('2 active')
  })
})
