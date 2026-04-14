import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// Writable route signal shared between mock and test helpers.
const routeSignal = signal<{ tab: string; params: Record<string, string>; postId: string | null }>({
  tab: 'monitoring',
  params: { section: 'fleet-health' },
  postId: null,
})

vi.mock('../router', () => ({
  get route() { return routeSignal },
}))

// Mock child panels to avoid real fetch calls. Each renders a data-testid marker.
vi.mock('./telemetry-unified', () => ({
  TelemetryUnified: () => html`<div data-testid="telemetry-unified">TelemetryUnified</div>`,
}))
vi.mock('./fleet-telemetry-panel', () => ({
  FleetTelemetryPanel: () => html`<div data-testid="fleet-telemetry-panel">FleetTelemetryPanel</div>`,
}))
vi.mock('./tool-quality-panel', () => ({
  ToolQualityPanel: () => html`<div data-testid="tool-quality-panel">ToolQualityPanel</div>`,
}))
vi.mock('./governance-monitor', () => ({
  GovernanceMonitor: () => html`<div data-testid="governance-monitor">GovernanceMonitor</div>`,
}))

// Import after mocks are in place.
import { FleetHealthPanel } from './fleet-health-panel'

function setRoute(view?: string) {
  const params: Record<string, string> = { section: 'fleet-health' }
  if (view) params.view = view
  routeSignal.value = { tab: 'monitoring', params, postId: null }
}

describe('FleetHealthPanel', () => {
  beforeEach(() => {
    setRoute()
  })

  afterEach(() => {
    cleanup()
  })

  it('renders default dual-panel (TelemetryUnified + ToolQualityPanel) when no view param', () => {
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('telemetry-unified')).toBeTruthy()
    expect(screen.getByTestId('tool-quality-panel')).toBeTruthy()
    expect(screen.queryByTestId('fleet-telemetry-panel')).toBeNull()
    expect(screen.queryByTestId('governance-monitor')).toBeNull()
  })

  it('renders TelemetryUnified alone for view=event-log', () => {
    setRoute('event-log')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('telemetry-unified')).toBeTruthy()
    expect(screen.queryByTestId('tool-quality-panel')).toBeNull()
  })

  it('renders FleetTelemetryPanel for view=comparison', () => {
    setRoute('comparison')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('fleet-telemetry-panel')).toBeTruthy()
    expect(screen.queryByTestId('telemetry-unified')).toBeNull()
  })

  it('renders ToolQualityPanel alone for view=tool-quality', () => {
    setRoute('tool-quality')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('tool-quality-panel')).toBeTruthy()
    expect(screen.queryByTestId('telemetry-unified')).toBeNull()
  })

  it('renders GovernanceMonitor for view=governance', () => {
    setRoute('governance')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('governance-monitor')).toBeTruthy()
    expect(screen.queryByTestId('telemetry-unified')).toBeNull()
  })

  it('renders FilterChips with 5 view options', () => {
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByText('개요')).toBeTruthy()
    expect(screen.getByText('이벤트 로그')).toBeTruthy()
    expect(screen.getByText('Fleet 비교')).toBeTruthy()
    expect(screen.getByText('도구 품질')).toBeTruthy()
    expect(screen.getByText('거버넌스')).toBeTruthy()
  })

  it('marks the default chip as active (aria-pressed)', () => {
    render(html`<${FleetHealthPanel} />`)

    const defaultChip = screen.getByText('개요').closest('button')
    expect(defaultChip?.getAttribute('aria-pressed')).toBe('true')
  })

  it('clicking a chip dispatches hashchange to switch view', () => {
    const hashChangeSpy = vi.fn()
    window.addEventListener('hashchange', hashChangeSpy)

    render(html`<${FleetHealthPanel} />`)

    const toolQualityChip = screen.getByText('도구 품질')
    fireEvent.click(toolQualityChip)

    expect(hashChangeSpy).toHaveBeenCalledTimes(1)
    expect(location.hash).toContain('view=tool-quality')

    window.removeEventListener('hashchange', hashChangeSpy)
  })

  it('clicking 개요 chip removes view param from hash', () => {
    setRoute('tool-quality')
    render(html`<${FleetHealthPanel} />`)

    const defaultChip = screen.getByText('개요')
    fireEvent.click(defaultChip)

    expect(location.hash).not.toContain('view=')
  })

  it('falls back to default view for unknown view param', () => {
    setRoute('nonexistent')
    render(html`<${FleetHealthPanel} />`)

    expect(screen.getByTestId('telemetry-unified')).toBeTruthy()
    expect(screen.getByTestId('tool-quality-panel')).toBeTruthy()
  })
})
