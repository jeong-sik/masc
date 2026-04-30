import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  TlcResultEntry,
  TlcResultsResponse,
} from '../api/dashboard'

const mockState = signal({
  loading: false,
  error: null as string | null,
  data: null as TlcResultsResponse | null,
})
const mockLoad = vi.fn()
const mockCancel = vi.fn()

vi.mock('../lib/async-state', () => ({
  createManagedAsyncResource: () => ({
    state: mockState,
    load: mockLoad,
    cancel: mockCancel,
    reset: vi.fn(),
  }),
}))

vi.mock('../api/dashboard', () => ({
  fetchTlcResults: vi.fn(),
}))

vi.mock('./btn', () => ({
  Btn: ({ children, onClick }: any) => html`
    <button type="button" onClick=${onClick}>${children}</button>
  `,
}))

vi.mock('./common/card', () => ({
  Card: ({ title, children }: any) => html`
    <section data-testid="card"><h3>${title}</h3>${children}</section>
  `,
}))

vi.mock('./common/empty-state', () => ({
  EmptyState: ({ message, children }: any) => html`
    <div data-testid="empty-state">${children ?? message}</div>
  `,
}))

vi.mock('./common/feedback-state', () => ({
  ErrorState: ({ message }: any) => html`
    <div data-testid="error-state">${message}</div>
  `,
  LoadingState: ({ children }: any) => html`
    <div data-testid="loading-state">${children}</div>
  `,
}))

vi.mock('./common/status-chip', () => ({
  StatusChip: ({ tone, label, children }: any) => html`
    <span data-testid="status-chip" data-tone=${tone}>${children ?? label}</span>
  `,
}))

vi.mock('./common/filter-chips', () => ({
  FilterChips: ({ chips, active }: any) => html`
    <div data-testid="filter-chips">
      ${chips.map((chip: any) => html`
        <button
          type="button"
          key=${chip.key}
          data-testid=${`filter-chip-${chip.key}`}
          data-active=${active?.value === chip.key}
          onClick=${() => { if (active) active.value = chip.key }}
        >
          ${chip.label}${chip.count != null ? ` (${chip.count})` : ''}
        </button>
      `)}
    </div>
  `,
}))

import {
  __resetTlcResultsPanelForTest,
  filterTlcEntries,
  formatTlcMetric,
  formatTlcTimestamp,
  hasTlcEvidence,
  TlcResultsPanel,
  tlcStatusLabel,
  tlcStatusTone,
} from './tlc-results-panel'

function makeEntry(overrides: Partial<TlcResultEntry> = {}): TlcResultEntry {
  return {
    spec_name: 'KeeperTurnFSM',
    cfg_name: 'KeeperTurnFSM.cfg',
    category: 'boundary',
    status: 'passed',
    states_explored: 1234,
    distinct_states: 512,
    diameter: 17,
    last_run_at: '2026-04-30T00:00:00Z',
    violation: null,
    log_path: '/tmp/tlc.log',
    ...overrides,
  }
}

function setData(entries: TlcResultEntry[], overrides: Partial<TlcResultsResponse> = {}) {
  mockState.value = {
    loading: false,
    error: null,
    data: {
      updated_at: '2026-04-30T00:01:00Z',
      results_dir: null,
      count: entries.length,
      entries,
      ...overrides,
    },
  }
}

describe('TLC result helpers', () => {
  it('labels every TLC status', () => {
    expect(tlcStatusLabel('passed')).toBe('통과')
    expect(tlcStatusLabel('violated')).toBe('위반')
    expect(tlcStatusLabel('running')).toBe('실행 중')
    expect(tlcStatusLabel('queued')).toBe('대기')
    expect(tlcStatusLabel('error')).toBe('오류')
    expect(tlcStatusLabel('not_run')).toBe('미실행')
  })

  it('maps TLC statuses to semantic tones', () => {
    expect(tlcStatusTone('passed')).toBe('ok')
    expect(tlcStatusTone('violated')).toBe('bad')
    expect(tlcStatusTone('running')).toBe('info')
    expect(tlcStatusTone('queued')).toBe('neutral')
    expect(tlcStatusTone('error')).toBe('warn')
    expect(tlcStatusTone('not_run')).toBe('neutral')
  })

  it('formats nullable TLC metrics and timestamps', () => {
    expect(formatTlcMetric(1234567)).toBe('1,234,567')
    expect(formatTlcMetric(null)).toBe('-')
    expect(formatTlcTimestamp('2026-04-30T00:00:00Z')).toBe('2026-04-30 00:00:00')
    expect(formatTlcTimestamp(null)).toBe('기록 없음')
  })

  it('treats all-null not_run rows as absent evidence', () => {
    const notRun = makeEntry({
      status: 'not_run',
      states_explored: null,
      distinct_states: null,
      diameter: null,
      last_run_at: null,
      violation: null,
      log_path: null,
    })
    expect(hasTlcEvidence(notRun)).toBe(false)
    expect(hasTlcEvidence({ ...notRun, log_path: '/tmp/tlc.log' })).toBe(true)
    expect(hasTlcEvidence(makeEntry({ status: 'passed' }))).toBe(true)
  })

  it('filters by status and sorts newest evidence first', () => {
    const older = makeEntry({ spec_name: 'Older', status: 'passed', last_run_at: '2026-04-29T00:00:00Z' })
    const newer = makeEntry({ spec_name: 'Newer', status: 'passed', last_run_at: '2026-04-30T00:00:00Z' })
    const queued = makeEntry({ spec_name: 'Queued', status: 'queued', last_run_at: null })

    expect(filterTlcEntries([older, queued, newer], 'passed').map((entry) => entry.spec_name))
      .toEqual(['Newer', 'Older'])
  })
})

describe('TlcResultsPanel', () => {
  beforeEach(() => {
    mockState.value = { loading: false, error: null, data: null }
    mockLoad.mockReset()
    mockCancel.mockReset()
    __resetTlcResultsPanelForTest()
  })

  afterEach(() => {
    cleanup()
  })

  it('shows an explicit empty state when no TLC rows exist', () => {
    setData([])
    render(html`<${TlcResultsPanel} />`)

    expect(screen.getByTestId('empty-state').textContent).toContain('TLC 결과 항목이 없습니다')
  })

  it('shows absent-evidence warning for only not_run rows', () => {
    setData([
      makeEntry({
        status: 'not_run',
        states_explored: null,
        distinct_states: null,
        diameter: null,
        last_run_at: null,
        violation: null,
        log_path: null,
      }),
    ])
    render(html`<${TlcResultsPanel} />`)

    expect(screen.getByText(/TLC 실행 증거 없음/)).toBeTruthy()
    expect(screen.getByText('미실행')).toBeTruthy()
    expect(screen.getByText('기록 없음')).toBeTruthy()
  })

  it('filters rendered rows by status chip', () => {
    setData([
      makeEntry({ spec_name: 'PassingSpec', status: 'passed' }),
      makeEntry({
        spec_name: 'QueuedSpec',
        status: 'queued',
        states_explored: null,
        distinct_states: null,
        diameter: null,
        last_run_at: null,
      }),
    ])
    render(html`<${TlcResultsPanel} />`)

    fireEvent.click(screen.getByTestId('filter-chip-queued'))
    const card = screen.getByTestId('card')
    expect(card.textContent).toContain('QueuedSpec')
    expect(card.textContent).not.toContain('PassingSpec')
  })
})
