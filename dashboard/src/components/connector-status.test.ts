import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

function sampleResponse(overrides?: Partial<Record<string, unknown>>) {
  return {
    channels: [
      {
        channel: 'discord',
        message_count: 12,
        success_count: 10,
        error_count: 2,
        duplicate_count: 1,
        validation_error_count: 0,
        keeper_error_count: 2,
        dispatch_unavailable_count: 0,
        internal_error_count: 0,
        last_activity: '2026-04-03T00:00:00Z',
        last_success: '2026-04-03T00:00:00Z',
        last_error_at: '2026-04-03T00:00:00Z',
        last_keeper: 'luna',
        last_room_id: '123456',
        last_error: 'upstream timeout',
        last_error_kind: 'keeper',
        last_outcome: 'keeper_error',
        avg_duration_ms: 1400,
        max_duration_ms: 4800,
        slow_count: 3,
        slow_rate_pct: 25,
        success_rate_pct: 91,
        room_count: 2,
        health: 'degraded',
      },
    ],
    total_messages: 12,
    total_success: 10,
    total_errors: 2,
    total_duplicates: 1,
    success_rate_pct: 91,
    dedup_table_size: 4,
    uptime_seconds: 3600,
    ...overrides,
  }
}

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function loadComponentWithApi(api: {
  get: (path: string) => Promise<unknown>
  lastEvent: { value: unknown }
}) {
  vi.resetModules()
  vi.doMock('../api/core', () => ({
    get: api.get,
  }))
  vi.doMock('../sse', () => ({
    lastEvent: api.lastEvent,
  }))
  const module = await import('./connector-status')
  module.resetConnectorStatusState()
  return module
}

describe('ConnectorStatusPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(async () => {
    const { resetConnectorStatusState } = await import('./connector-status')
    resetConnectorStatusState()
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api/core')
    vi.doUnmock('../sse')
  })

  it('renders enriched connector health details from gate status', async () => {
    const get = vi.fn<(path: string) => Promise<unknown>>().mockResolvedValue(
      sampleResponse(),
    )

    const { ConnectorStatusPanel } = await loadComponentWithApi({
      get,
      lastEvent: signal(null),
    })

    render(html`<${ConnectorStatusPanel} />`, container)
    await flushUi()

    expect(get).toHaveBeenCalledWith('/api/v1/gate/status')
    expect(container.textContent).toContain('Channel Gate')
    expect(container.textContent).toContain('success 91%')
    expect(container.textContent).toContain('duplicates')
    expect(container.textContent).toContain('upstream timeout')
    expect(container.innerHTML).toContain('degraded')
  })
})
