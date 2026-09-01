// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  KeeperMemoryHealthKeeperEntry,
  KeeperMemoryHealthResponse,
} from '../../api/dashboard'

const mockFetch = vi.fn<() => Promise<KeeperMemoryHealthResponse>>()

vi.mock('../../api/dashboard', () => ({
  fetchKeeperMemoryHealth: () => mockFetch(),
}))

import { KeeperMemoryHealth } from './keeper-memory-health'

function makeEntry(
  overrides: Partial<KeeperMemoryHealthKeeperEntry> = {},
): KeeperMemoryHealthKeeperEntry {
  return {
    keeper_id: 'alpha',
    revision: 7,
    facts: 10,
    snapshot_bytes: 512,
    added: 2,
    removed: 1,
    snapshot_present: true,
    librarian_lane_busy: 0,
    librarian_failures: 0,
    vision_ingest_errors: 0,
    vision_ingest_error_reasons: [],
    read_error: null,
    source_revision: 0,
    source_facts: 0,
    source_invalidations: 0,
    source_snapshot_bytes: 0,
    source_snapshot_present: false,
    source_read_error: null,
    alerts: [],
    ...overrides,
  }
}

function makeAlertSummary(
  overrides: Partial<KeeperMemoryHealthResponse['alert_summary']> = {},
): KeeperMemoryHealthResponse['alert_summary'] {
  return {
    total_alerts: 0,
    warn_alerts: 0,
    error_alerts: 0,
    keepers_with_alerts: 0,
    snapshot_read_error_keepers: 0,
    source_snapshot_read_error_keepers: 0,
    librarian_lane_busy_keepers: 0,
    librarian_starving_keepers: 0,
    ...overrides,
  }
}

function makeResponse(
  keepers: KeeperMemoryHealthKeeperEntry[],
  totalsOverrides: Partial<KeeperMemoryHealthResponse['totals']> = {},
  alertSummary = makeAlertSummary(),
): KeeperMemoryHealthResponse {
  return {
    schema: 'keeper.memory_os.current_health.v2',
    generated_at: 1_700_000_000,
    cadence_counter_entries: 3,
    keepers,
    totals: {
      facts: 0,
      snapshot_bytes: 0,
      added: 0,
      removed: 0,
      source_facts: 0,
      source_invalidations: 0,
      source_snapshot_bytes: 0,
      librarian_lane_busy: 0,
      librarian_failures: 0,
      vision_ingest_errors: 0,
      read_errors: 0,
      source_read_errors: 0,
      ...totalsOverrides,
    },
    alert_summary: alertSummary,
  }
}

function statValue(container: Element, key: string): string | undefined {
  const stat = container.querySelector(`.kmh-totals-strip .kmh-stat[data-stat-key="${key}"]`)
  return stat?.querySelector('.kmh-stat-value')?.textContent ?? undefined
}

describe('KeeperMemoryHealth', () => {
  beforeEach(() => mockFetch.mockReset())
  afterEach(() => cleanup())

  it('renders the current snapshot totals and exact latest delta', async () => {
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry()],
      { facts: 10, snapshot_bytes: 1536, added: 2, removed: 1 },
    ))
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    expect(statValue(container, 'snapshot-bytes')).toBe('1.5 KB')
    expect(statValue(container, 'added')).toBe('+2')
    expect(statValue(container, 'removed')).toBe('−1')
    expect(container.textContent).toContain('7')
  })

  it('uses backend snapshot-read alerts as the row warning authority', async () => {
    const alert = {
      code: 'snapshot_read_error' as const,
      severity: 'warn' as const,
      target: 'snapshot_read_error' as const,
      label: '읽기',
      message: 'invalid current snapshot',
      value: 1,
      threshold: 0,
    }
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry({ read_error: alert.message, alerts: [alert] })],
      { read_errors: 1 },
      makeAlertSummary({
        total_alerts: 1,
        warn_alerts: 1,
        keepers_with_alerts: 1,
        snapshot_read_error_keepers: 1,
      }),
    ))
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    expect(container.querySelector('.kmh-row--warn')).not.toBeNull()
    expect(statValue(container, 'read-errors')).toBe('1')
    expect(screen.getByText('읽기')).not.toBeNull()
  })

  it('renders source-bound facts, invalidations, and snapshot identity', async () => {
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry({
        source_revision: 3,
        source_facts: 2,
        source_invalidations: 1,
        source_snapshot_bytes: 1024,
        source_snapshot_present: true,
      })],
      { source_facts: 2, source_invalidations: 1, source_snapshot_bytes: 1024 },
    ))
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    expect(statValue(container, 'source-facts')).toBe('2')
    expect(statValue(container, 'source-invalidations')).toBe('1')
    expect(statValue(container, 'source-snapshot-bytes')).toBe('1.0 KB')
    expect(container.textContent).toContain('r3 · 2 / 무효 1')
  })

  it('shows Vision ingest counts with their exact reasons', async () => {
    const alert = {
      code: 'vision_ingest_errors' as const,
      severity: 'warn' as const,
      target: 'vision_ingest_errors' as const,
      label: 'Vision',
      message: 'Image ingestion failed 3 times.',
      value: 3,
      threshold: 0,
    }
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry({
        vision_ingest_errors: 3,
        vision_ingest_error_reasons: [
          { reason: 'fetch_failed', count: 2 },
          { reason: 'unsupported_media_type', count: 1 },
        ],
        alerts: [alert],
      })],
      { vision_ingest_errors: 3 },
      makeAlertSummary({
        total_alerts: 1,
        warn_alerts: 1,
        keepers_with_alerts: 1,
      }),
    ))
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    expect(statValue(container, 'vision-ingest-errors')).toBe('3')
    expect(container.querySelector('[title="fetch_failed ×2, unsupported_media_type ×1"]')).not.toBeNull()
    expect(screen.getByText('Vision')).not.toBeNull()
  })

  it('surfaces Librarian lane pressure without inventing a retry or GC state', async () => {
    const alert = {
      code: 'librarian_lane_busy' as const,
      severity: 'warn' as const,
      target: 'librarian_lane_busy' as const,
      label: 'Librarian',
      message: 'current-memory selection deferred',
      value: 3,
      threshold: 0,
    }
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry({ librarian_lane_busy: 3, alerts: [alert] })],
      { librarian_lane_busy: 3 },
      makeAlertSummary({
        total_alerts: 1,
        warn_alerts: 1,
        keepers_with_alerts: 1,
        librarian_lane_busy_keepers: 1,
      }),
    ))
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    expect(statValue(container, 'librarian-lane-busy')).toBe('3')
    expect(screen.getByText('Librarian')).not.toBeNull()
  })

  it('renders librarian starvation as an error row, not a warning', async () => {
    const alert = {
      code: 'librarian_starvation' as const,
      severity: 'error' as const,
      target: 'librarian_starvation' as const,
      label: 'Librarian',
      message: 'Librarian runs failed and no current-memory snapshot exists',
      value: 4,
      threshold: 0,
    }
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry({
        keeper_id: 'starving',
        revision: 0,
        facts: 0,
        snapshot_bytes: 0,
        snapshot_present: false,
        librarian_failures: 4,
        alerts: [alert],
      })],
      { librarian_failures: 4 },
      makeAlertSummary({
        total_alerts: 1,
        error_alerts: 1,
        keepers_with_alerts: 1,
        librarian_starving_keepers: 1,
      }),
    ))
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('starving')).not.toBeNull())
    expect(container.querySelector('.kmh-row--error')).not.toBeNull()
    expect(container.querySelector('.kmh-badge--error')).not.toBeNull()
    expect(screen.getAllByText('없음')).toHaveLength(2)
    expect(statValue(container, 'librarian-failures')).toBe('4')
    expect(statValue(container, 'starving-keepers')).toBe('1')
    const alertStat = container.querySelector(
      '.kmh-totals-strip .kmh-stat[data-stat-key="alerts"] .kmh-stat-value',
    )
    expect(alertStat?.classList.contains('kmh-stat-value--error')).toBe(true)
  })

  it('keeps a never-attempted snapshotless keeper neutral, not alarming', async () => {
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry({
        keeper_id: 'fresh',
        revision: 0,
        facts: 0,
        snapshot_bytes: 0,
        snapshot_present: false,
      })],
    ))
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('fresh')).not.toBeNull())
    expect(container.querySelector('.kmh-row--error')).toBeNull()
    expect(container.querySelector('.kmh-badge--muted')).not.toBeNull()
    expect(screen.getAllByText('없음')).toHaveLength(2)
  })

  it('shows loading, error, and empty current-snapshot states honestly', async () => {
    mockFetch.mockReturnValueOnce(new Promise<KeeperMemoryHealthResponse>(() => {}))
    const loading = render(html`<${KeeperMemoryHealth} />`)
    expect(screen.getByText('로딩중...')).not.toBeNull()
    loading.unmount()

    mockFetch.mockRejectedValueOnce(new Error('boom'))
    const failed = render(html`<${KeeperMemoryHealth} />`)
    await waitFor(() => expect(screen.getByText('데이터 로드 실패: boom')).not.toBeNull())
    failed.unmount()

    mockFetch.mockResolvedValueOnce(makeResponse([]))
    render(html`<${KeeperMemoryHealth} />`)
    await waitFor(() => {
      expect(screen.getByText('등록된 current-memory snapshot 또는 Keeper 없음.')).not.toBeNull()
    })
  })
})
