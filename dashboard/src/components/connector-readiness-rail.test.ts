// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorReadinessRail,
  deriveRail,
  markRailInflight,
  clearRailInflight,
  getRailInflight,
  withRailInflight,
  resetRailInflightState,
  railPillAriaLabel,
  type RailHandlers,
  type RailPill,
} from './connector-readiness-rail'

const noop: RailHandlers = {
  openConfig: () => {},
  toggleProcess: () => {},
  expandHeader: () => {},
  scrollToBindings: () => {},
}

describe('deriveRail', () => {
  it('all bad/idle when sidecar is down with no gate signal and no keepers', () => {
    const pills = deriveRail(
      { sidecarUp: false, gateHealthy: null, bindingCount: 0, keeperCount: 0 },
      noop,
    )
    expect(pills.find(p => p.key === 'token')?.state).toBe('bad')
    expect(pills.find(p => p.key === 'process')?.state).toBe('bad')
    expect(pills.find(p => p.key === 'gate')?.state).toBe('idle')
    expect(pills.find(p => p.key === 'bindings')?.state).toBe('idle')
  })

  it('all ok when running, gate healthy, has bindings', () => {
    const pills = deriveRail(
      { sidecarUp: true, gateHealthy: true, bindingCount: 2, keeperCount: 3 },
      noop,
    )
    expect(pills.every(p => p.state === 'ok')).toBe(true)
    expect(pills.find(p => p.key === 'bindings')?.detail).toContain('2')
  })

  it('bindings warn when keepers exist but bindings = 0', () => {
    const pills = deriveRail(
      { sidecarUp: true, gateHealthy: true, bindingCount: 0, keeperCount: 1 },
      noop,
    )
    expect(pills.find(p => p.key === 'bindings')?.state).toBe('warn')
  })

  it('gate bad when gate explicitly unhealthy', () => {
    const pills = deriveRail(
      { sidecarUp: true, gateHealthy: false, bindingCount: 0, keeperCount: 0 },
      noop,
    )
    expect(pills.find(p => p.key === 'gate')?.state).toBe('bad')
  })

  it('handlers are wired through to onClick on each pill', () => {
    const calls: string[] = []
    const handlers: RailHandlers = {
      openConfig: () => calls.push('config'),
      toggleProcess: () => calls.push('process'),
      expandHeader: () => calls.push('header'),
      scrollToBindings: () => calls.push('bindings'),
    }
    const pills = deriveRail(
      { sidecarUp: false, gateHealthy: null, bindingCount: 0, keeperCount: 0 },
      handlers,
    )
    pills.forEach(p => p.onClick())
    expect(calls).toEqual(['config', 'process', 'header', 'bindings'])
  })
})

describe('ConnectorReadinessRail rendering', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    document.body.removeChild(container)
  })

  it('renders 4 pills with data-rail-state matching deriveRail output', () => {
    const pills = deriveRail(
      { sidecarUp: true, gateHealthy: true, bindingCount: 0, keeperCount: 1 },
      noop,
    )
    render(html`<${ConnectorReadinessRail} pills=${pills} />`, container)
    const rendered = container.querySelectorAll('[data-rail-pill]')
    expect(rendered.length).toBe(4)

    const tokenPill = container.querySelector('[data-rail-pill="token"]')
    const bindingsPill = container.querySelector('[data-rail-pill="bindings"]')
    expect(tokenPill?.getAttribute('data-rail-state')).toBe('ok')
    expect(bindingsPill?.getAttribute('data-rail-state')).toBe('warn')
  })

  it('inflight=true pulses the pill, disables click, swaps detail to "진행 중..."', () => {
    const pills = deriveRail(
      { sidecarUp: false, gateHealthy: null, bindingCount: 0, keeperCount: 0 },
      noop,
      { process: true },
    )
    render(html`<${ConnectorReadinessRail} pills=${pills} />`, container)
    const processPill = container.querySelector('[data-rail-pill="process"]') as HTMLButtonElement
    expect(processPill.getAttribute('data-rail-inflight')).toBe('true')
    expect(processPill.disabled).toBe(true)
    expect(processPill.className).toContain('animate-pulse')
    expect(processPill.textContent).toContain('진행 중')
  })

  it('withRailInflight marks then clears the key around an async op', async () => {
    resetRailInflightState()
    const before = getRailInflight('discord').process
    expect(before).toBeUndefined()

    let observedDuringAwait: boolean | undefined
    await withRailInflight('discord', 'process', async () => {
      observedDuringAwait = getRailInflight('discord').process
    })
    expect(observedDuringAwait).toBe(true)
    expect(getRailInflight('discord').process).toBeUndefined()
  })

  it('markRailInflight then clearRailInflight only mutates the targeted key', () => {
    resetRailInflightState()
    markRailInflight('discord', 'process')
    markRailInflight('discord', 'token')
    expect(getRailInflight('discord').process).toBe(true)
    expect(getRailInflight('discord').token).toBe(true)
    clearRailInflight('discord', 'process')
    expect(getRailInflight('discord').process).toBeUndefined()
    expect(getRailInflight('discord').token).toBe(true)
  })

  it('clicking a pill invokes its onClick', () => {
    let opened = 0
    const handlers: RailHandlers = {
      ...noop,
      openConfig: () => { opened += 1 },
    }
    const pills = deriveRail(
      { sidecarUp: false, gateHealthy: null, bindingCount: 0, keeperCount: 0 },
      handlers,
    )
    render(html`<${ConnectorReadinessRail} pills=${pills} />`, container)
    const tokenPill = container.querySelector('[data-rail-pill="token"]') as HTMLButtonElement
    tokenPill.click()
    expect(opened).toBe(1)
  })

  it('each pill carries a screen-reader aria-label and a keyboard focus ring', () => {
    const pills = deriveRail(
      { sidecarUp: false, gateHealthy: null, bindingCount: 0, keeperCount: 0 },
      noop,
    )
    render(html`<${ConnectorReadinessRail} pills=${pills} />`, container)
    const tokenPill = container.querySelector('[data-rail-pill="token"]') as HTMLButtonElement
    // AA: button has an aria-label that includes both the label AND the
    // action-outcome detail, so screen readers announce more than "Token".
    const aria = tokenPill.getAttribute('aria-label') ?? ''
    expect(aria).toContain('Token')
    expect(aria).toContain('Config')
    // Focus ring is applied via focus-visible so mouse clicks don't light up.
    expect(tokenPill.className).toContain('focus-visible:outline')
  })

  it('inflight pill sets aria-busy="true"', () => {
    const pills = deriveRail(
      { sidecarUp: false, gateHealthy: null, bindingCount: 0, keeperCount: 0 },
      noop,
      { process: true },
    )
    render(html`<${ConnectorReadinessRail} pills=${pills} />`, container)
    const processPill = container.querySelector('[data-rail-pill="process"]') as HTMLButtonElement
    expect(processPill.getAttribute('aria-busy')).toBe('true')
  })

  it('decorative glyph spans are aria-hidden so AT does not read "dot dot dot"', () => {
    const pills = deriveRail(
      { sidecarUp: true, gateHealthy: true, bindingCount: 1, keeperCount: 1 },
      noop,
    )
    render(html`<${ConnectorReadinessRail} pills=${pills} />`, container)
    const tokenPill = container.querySelector('[data-rail-pill="token"]')!
    const hidden = tokenPill.querySelectorAll('[aria-hidden="true"]')
    // One for the glyph circle + one for uppercase label + one for detail line.
    expect(hidden.length).toBeGreaterThanOrEqual(3)
  })
})

describe('railPillAriaLabel', () => {
  const basePill: RailPill = {
    key: 'token',
    state: 'ok',
    label: 'Token',
    detail: '설정됨',
    hint: null,
    onClick: () => {},
  }

  it('includes label and detail with an em-dash separator', () => {
    expect(railPillAriaLabel(basePill)).toBe('Token — 설정됨')
  })

  it('appends hint when provided', () => {
    const pill = { ...basePill, hint: '클릭하면 Config' }
    expect(railPillAriaLabel(pill)).toBe('Token — 설정됨 — 클릭하면 Config')
  })

  it('replaces detail with "진행 중" when inflight so AT announces the busy state', () => {
    const pill = { ...basePill, inflight: true }
    expect(railPillAriaLabel(pill)).toBe('Token — 진행 중')
  })
})

describe('ConnectorReadinessRail layout', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetRailInflightState()
  })
  afterEach(() => {
    document.body.removeChild(container)
  })

  // Regression guard for the truncation bug ("BINDIN…", "필…"): under
  // flex-wrap, per-pill width depended on intrinsic label width, so short
  // labels (Token) snapped tiny and long labels (Bindings) blew out and
  // truncated mid-word. A 4-column grid forces equal widths across all 4
  // pills, so when truncation does happen at narrow tile widths, it happens
  // symmetrically.
  it('uses a 4-column grid (not flex-wrap) so pill widths are equal', () => {
    const pills = deriveRail(
      { sidecarUp: true, gateHealthy: true, bindingCount: 1, keeperCount: 1 },
      noop,
    )
    render(html`<${ConnectorReadinessRail} pills=${pills} />`, container)
    const rail = container.querySelector('[data-rail-layout="grid-4"]')
    expect(rail).toBeTruthy()
    expect(rail?.className).toContain('grid')
    expect(rail?.className).toContain('grid-cols-4')
    expect(rail?.className).not.toContain('flex-wrap')
  })

  it('renders exactly 4 pill buttons regardless of state mix', () => {
    const pills = deriveRail(
      { sidecarUp: false, gateHealthy: null, bindingCount: 0, keeperCount: 0 },
      noop,
    )
    render(html`<${ConnectorReadinessRail} pills=${pills} />`, container)
    const buttons = container.querySelectorAll('[data-rail-pill]')
    expect(buttons.length).toBe(4)
  })
})
