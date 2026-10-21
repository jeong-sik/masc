import { render } from 'preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { normalizeKeepers } from '../keeper-store-normalize'
import { MetricsCharts } from './keeper-detail-charts'

afterEach(() => { document.body.innerHTML = '' })

describe('retained metric values through the producer normalizer', () => {
  it('does not turn an unpriced row into a NaN cost total', () => {
    const [keeper] = normalizeKeepers([{ name: 'chart-proof', status: 'active', metrics_series: [
      { ts_unix: 1, latency_ms: 100, cost_usd: 0.001 },
      { ts_unix: 2, latency_ms: 0, cost_usd: null },
    ] }])
    const host = document.createElement('div')
    document.body.appendChild(host)
    render(html`<${MetricsCharts} keeper=${keeper!} />`, host)
    expect(host.textContent).not.toContain('NaN')
    expect(host.textContent).toContain('$0.0010')
    expect(host.textContent).toContain('0ms')
  })
})
