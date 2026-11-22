// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { act, cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { acceptedExecutionWorkspace } from '../../execution-workspace-authority'

import type {
  KeeperMemoryHealthKeeperEntry,
  KeeperMemoryHealthResponse,
} from '../../api/dashboard'

const mockFetch = vi.fn<() => Promise<KeeperMemoryHealthResponse>>()
const mockGet = vi.hoisted(() => vi.fn())

vi.mock('../../api/core', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/core')>(), get: mockGet,
}))

vi.mock('../../api/dashboard', () => ({
  fetchKeeperMemoryHealth: () => mockFetch(),
}))

import { KeeperMemoryHealth } from './keeper-memory-health'
import { fetchKeeperMemoryHealth as fetchStrictKeeperMemoryHealth } from '../../api/dashboard-misc'

// Every pass and change the server counts, none moved since it started.
function noMemoryChanges(): KeeperMemoryHealthKeeperEntry['changes_since_start'] {
  const none = () => ({ added: 0, absorbed: 0, superseded: 0, dropped: 0 })
  return {
    admission: none(),
    durable: none(),
    continuity: none(),
    cleanup: none(),
    keeper_write: none(),
    keeper_delete: none(),
    operator_delete: none(),
  }
}

function makeEntry(
  overrides: Partial<KeeperMemoryHealthKeeperEntry> = {},
): KeeperMemoryHealthKeeperEntry {
  return {
    keeper_id: 'alpha',
    revision: 7,
    updated_at: 1_699_999_900,
    facts: 10,
    observed_facts: 8,
    derived_facts: 2,
    support_invalidations: 0,
    snapshot_bytes: 512,
    added: 2,
    removed: 1,
    snapshot_present: true,
    age_bins: null,
    facts_by_hour: [],
    changes_since_start: noMemoryChanges(),
    writer: { kind: 'no_writer' },
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
    schema: 'keeper.memory_os.current_health.v19',
    generated_at: 1_700_000_000,
    keepers,
    totals: {
      facts: 0,
      observed_facts: 0,
      derived_facts: 0,
      support_invalidations: 0,
      snapshot_bytes: 0,
      added: 0,
      removed: 0,
      source_facts: 0,
      source_invalidations: 0,
      source_snapshot_bytes: 0,
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

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((accept, refuse) => { resolve = accept; reject = refuse })
  return { promise, resolve, reject }
}

describe('KeeperMemoryHealth', () => {
  beforeEach(() => {
    acceptedExecutionWorkspace.value = Object.freeze({ epoch: 'fixture', workspaceRoot: '/fixture',
      connectionGeneration: 0, observerInstanceId: 'fixture-instance' })
    mockFetch.mockReset()
    mockGet.mockReset()
  })
  afterEach(() => {
    cleanup()
    acceptedExecutionWorkspace.value = null
    vi.restoreAllMocks()
  })

  it.each([
    ['alert', 'success'], ['alert', 'failure'],
    ['failure', 'success'], ['failure', 'failure'],
  ] as const)('keeps the latest refresh %s after an older %s arrives', async (latest, olderOutcome) => {
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    const older = deferred<KeeperMemoryHealthResponse>()
    const newer = deferred<KeeperMemoryHealthResponse>()
    mockFetch.mockReturnValueOnce(older.promise).mockReturnValueOnce(newer.promise)
    const { container } = render(html`<${KeeperMemoryHealth} />`)
    await waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(1))
    await act(async () => { window.dispatchEvent(new Event('focus')) })
    expect(mockFetch).toHaveBeenCalledTimes(2)

    const degraded = makeEntry({
      read_error: 'snapshot unreadable',
      alerts: [{ code: 'snapshot_read_error', severity: 'warn',
        target: 'snapshot_read_error', label: '읽기', message: 'snapshot unreadable' }],
    })
    const payload = { ...makeResponse([degraded], { read_errors: 1 }, makeAlertSummary({
      total_alerts: 1, warn_alerts: 1, keepers_with_alerts: 1, snapshot_read_error_keepers: 1,
    })), generated_at: 1_700_000_010 }
    await act(async () => {
      if (latest === 'alert') newer.resolve(payload)
      else newer.reject(new Error('latest refresh failed'))
    })
    await waitFor(() => {
      if (latest === 'alert') expect(statValue(container, 'read-errors')?.trim()).toBe('1')
      else expect(screen.getByText('데이터 로드 실패: latest refresh failed')).not.toBeNull()
    })
    const acceptedObservation = container.querySelector('.kmh-refresh-label')?.textContent
    if (latest === 'alert') expect(statValue(container, 'read-errors')?.trim()).toBe('1')
    else expect(screen.getByText('데이터 로드 실패: latest refresh failed')).not.toBeNull()

    await act(async () => {
      if (olderOutcome === 'success') older.resolve(makeResponse([makeEntry({ keeper_id: 'old-healthy' })]))
      else older.reject(new Error('old failure'))
    })
    expect(screen.queryByText('old-healthy')).toBeNull()
    if (latest === 'alert') {
      expect(statValue(container, 'read-errors')?.trim()).toBe('1')
      expect(container.querySelector('.kmh-refresh-label')?.textContent).toBe(acceptedObservation)
      expect(screen.queryByRole('alert')).toBeNull()
    } else expect(screen.getByText('데이터 로드 실패: latest refresh failed')).not.toBeNull()
  })

  it.each(['success', 'failure'] as const)('retires a pending %s when the panel unmounts', async outcome => {
    const retired = deferred<KeeperMemoryHealthResponse>()
    mockFetch.mockReturnValueOnce(retired.promise)
    const previous = render(html`<${KeeperMemoryHealth} />`)
    await waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(1))
    previous.unmount()
    mockFetch.mockResolvedValueOnce(makeResponse([makeEntry({ keeper_id: 'current-panel' })]))
    render(html`<${KeeperMemoryHealth} />`)
    await waitFor(() => expect(screen.getByText('current-panel')).not.toBeNull())
    await act(async () => {
      if (outcome === 'success') retired.resolve(makeResponse([makeEntry({ keeper_id: 'retired-panel' })]))
      else retired.reject(new Error('retired failure'))
    })
    expect(screen.queryByText('retired-panel')).toBeNull()
    expect(screen.getByText('current-panel')).not.toBeNull()
  })

  it.each(['transport', 'strict decode'] as const)('keeps the last accepted observation visible when refresh fails: %s', async failure => {
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    const entry = makeEntry({ age_bins: [10, ...Array<number>(23).fill(0)] })
    const payload = makeResponse([entry], {
      facts: 10, observed_facts: 8, derived_facts: 2, snapshot_bytes: 512, added: 2, removed: 1,
    })
    mockGet.mockResolvedValueOnce(payload)
    mockFetch.mockImplementation(fetchStrictKeeperMemoryHealth)
    const { container } = render(html`<${KeeperMemoryHealth} />`)
    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    const lastObservation = container.querySelector('.kmh-refresh-label')!.textContent
    expect(lastObservation).toContain('마지막 관측')
    expect(screen.queryByRole('alert')).toBeNull()

    if (failure === 'transport') mockGet.mockRejectedValueOnce(new Error('connection lost'))
    else mockGet.mockResolvedValueOnce({ ...payload, schema: 'keeper.memory_os.current_health.v18' })
    await act(async () => { window.dispatchEvent(new Event('focus')) })
    await waitFor(() => expect(screen.getByRole('alert')).not.toBeNull())
    expect(mockGet).toHaveBeenCalledTimes(2)
    expect(screen.getByRole('alert').textContent).toContain('마지막 관측값을 표시합니다')
    expect(screen.getByRole('alert').textContent).toContain(failure === 'transport'
      ? 'connection lost' : '유효하지 않은 keeper memory health payload')
    expect(screen.getByText('alpha')).not.toBeNull()
    expect(statValue(container, 'facts')).toBe('10')
    expect(statValue(container, 'read-errors')?.trim()).toBe('0')
    expect(container.querySelector('.kmh-refresh-label')!.textContent).toBe(lastObservation)
  })

  it('renders the current snapshot totals and exact latest delta', async () => {
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry()],
      {
        facts: 10,
        observed_facts: 8,
        derived_facts: 2,
        snapshot_bytes: 1536,
        added: 2,
        removed: 1,
      },
    ))
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    expect(statValue(container, 'snapshot-bytes')).toBe('1.5 KB')
    expect(statValue(container, 'added')).toBe('+2')
    expect(statValue(container, 'removed')).toBe('−1')
    expect(statValue(container, 'observed-facts')).toBe('8')
    expect(statValue(container, 'derived-facts')).toBe('2')
    expect(container.textContent).toContain('7')
  })

  it('renders v2 Memory writer status, alarms, stop reason, and molt state', async () => {
    mockFetch.mockResolvedValue(makeResponse([
      makeEntry({
        writer: {
          kind: 'writer',
          row: {
            state: 'resting',
            level: 'warn',
            alarms: ['W1'],
            stop: 'provider quota',
            pending_molt: true,
            pending_molt_categories: ['fact'],
            available_acts: ['wake'],
          },
        },
      }),
    ]))
    render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    expect(screen.getByText('writer:resting (W1)')).not.toBeNull()
    expect(screen.getByText('stop: provider quota')).not.toBeNull()
    expect(screen.getByText('molt pending (fact)')).not.toBeNull()
    expect(screen.getByText('acts: wake')).not.toBeNull()
  })

  it('renders support retractions as observable state, not an alert', async () => {
    mockFetch.mockResolvedValue(
      makeResponse(
        [makeEntry({ support_invalidations: 2 })],
        { support_invalidations: 2 },
      ),
    )
    const { container } = render(html`<${KeeperMemoryHealth} />`)

    await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())
    expect(statValue(container, 'support-invalidations')).toBe('2')
    expect(container.querySelector('.kmh-row--warn')).toBeNull()
  })

  it('uses backend snapshot-read alerts as the row warning authority', async () => {
    const alert = {
      code: 'snapshot_read_error' as const,
      severity: 'warn' as const,
      target: 'snapshot_read_error' as const,
      label: '읽기',
      message: 'invalid current snapshot',
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

  it('renders librarian starvation as an error row, not a warning', async () => {
    const alert = {
      code: 'librarian_starvation' as const,
      severity: 'error' as const,
      target: 'librarian_starvation' as const,
      label: 'Librarian',
      message: 'Librarian runs failed and no current-memory snapshot exists',
    }
    mockFetch.mockResolvedValue(makeResponse(
      [makeEntry({
        keeper_id: 'starving',
        revision: 0,
        facts: 0,
        observed_facts: 0,
        derived_facts: 0,
        snapshot_bytes: 0,
        snapshot_present: false,
        updated_at: null,
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
        observed_facts: 0,
        derived_facts: 0,
        snapshot_bytes: 0,
        snapshot_present: false,
        updated_at: null,
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
    await waitFor(() => expect(mockFetch).toHaveBeenCalledTimes(1))
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
