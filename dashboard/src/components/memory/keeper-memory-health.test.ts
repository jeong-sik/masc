// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  KeeperMemoryHealthKeeperEntry,
  KeeperMemoryHealthResponse,
} from '../../api/dashboard'

// ── Mock API ──────────────────────────────────────────
// KeeperMemoryHealth fetches via fetchKeeperMemoryHealth() inside useEffect.
// Mocking the module lets us drive every render branch without a real HTTP call.

const mockFetch = vi.fn<() => Promise<KeeperMemoryHealthResponse>>()

vi.mock('../../api/dashboard', () => ({
  fetchKeeperMemoryHealth: () => mockFetch(),
}))

// ── Import after mocks ────────────────────────────────

import { KeeperMemoryHealth } from './keeper-memory-health'

function makeEntry(
  overrides: Partial<KeeperMemoryHealthKeeperEntry> = {},
): KeeperMemoryHealthKeeperEntry {
  return {
    keeper_id: 'alpha',
    facts: 10,
    facts_bytes: 512,
    events: 20,
    events_bytes: 1024,
    events_bytes_to_facts_bytes_ratio: 0,
    duplicate_claim_identity_rows: 0,
    alerts: [],
    ...overrides,
  }
}

function makeResponse(
  keepers: KeeperMemoryHealthKeeperEntry[],
  totalsOverrides: Partial<KeeperMemoryHealthResponse['totals']> = {},
  alertSummary?: KeeperMemoryHealthResponse['alert_summary'],
): KeeperMemoryHealthResponse {
  return {
    generated_at: 1_700_000_000,
    cadence_counter_entries: 3,
    read_error_count: 0,
    read_errors: [],
    keepers,
    totals: {
      facts: 0,
      facts_bytes: 0,
      events_bytes: 0,
      duplicate_claim_identity_rows: 0,
      ...totalsOverrides,
    },
    alert_summary: alertSummary ?? makeAlertSummary(),
  }
}

function makeAlertSummary(
  overrides: Partial<NonNullable<KeeperMemoryHealthResponse['alert_summary']>> = {},
): NonNullable<KeeperMemoryHealthResponse['alert_summary']> {
  return {
    total_alerts: 0,
    warn_alerts: 0,
    keepers_with_alerts: 0,
    duplicate_claim_identity_rows_keepers: 0,
    thresholds: {
      duplicate_claim_identity_rows: 0,
    },
    ...overrides,
  }
}

function statValue(container: Element, key: string): string | undefined {
  const stat = container.querySelector(`.kmh-totals-strip .kmh-stat[data-stat-key="${key}"]`)
  return stat?.querySelector('.kmh-stat-value')?.textContent ?? undefined
}

describe('KeeperMemoryHealth', () => {
  beforeEach(() => {
    mockFetch.mockReset()
  })
  afterEach(() => cleanup())

  // ── formatBytes (exercised via the totals strip) ──────
  // formatBytes is module-private; assert it through rendered output:
  //   < 1024            → "<n> B"
  //   < 1024*1024       → "(n/1024).toFixed(1) KB"
  //   otherwise         → "(n/1024/1024).toFixed(2) MB"
  describe('formatBytes (via totals strip)', () => {
    it('renders bytes under 1 KiB with a B suffix', async () => {
      mockFetch.mockResolvedValue(makeResponse([], { facts_bytes: 512 }))
      render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('512 B')).not.toBeNull())
    })

    it('renders kibibyte-range values with one decimal and a KB suffix', async () => {
      // 1536 / 1024 = 1.5
      mockFetch.mockResolvedValue(makeResponse([], { facts_bytes: 1536 }))
      render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('1.5 KB')).not.toBeNull())
    })

    it('renders mebibyte-range values with two decimals and a MB suffix', async () => {
      // 5 * 1024 * 1024 = 5242880 → "5.00 MB"
      mockFetch.mockResolvedValue(makeResponse([], { events_bytes: 5_242_880 }))
      render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('5.00 MB')).not.toBeNull())
    })
  })

  describe('backend alert-driven row warnings', () => {
    it('does not classify a raw high ratio as a warning without a backend alert', async () => {
      mockFetch.mockResolvedValue(
        makeResponse([
          makeEntry({
            keeper_id: 'raw-high-ratio',
            events_bytes_to_facts_bytes_ratio: 3,
          }),
        ]),
      )
      const { container } = render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('raw-high-ratio')).not.toBeNull())

      expect(container.querySelector('.kmh-row--warn')).toBeNull()
      expect(container.querySelector('.kmh-badge--warn')).toBeNull()
      expect(screen.getByText('3.00')).not.toBeNull()
    })

    it('renders exact duplicate claim identity rows from the backend alert', async () => {
      mockFetch.mockResolvedValue({
        ...makeResponse([
          makeEntry({
            keeper_id: 'duplicate-identity',
            duplicate_claim_identity_rows: 2,
            alerts: [{
              code: 'duplicate_claim_identity_rows',
              severity: 'warn',
              target: 'duplicate_claim_identity_rows',
              label: '동일 claim identity 행',
              message: 'Duplicate Memory OS claim identities remain on disk',
              value: 2,
              threshold: 0,
            }],
          }),
        ], { duplicate_claim_identity_rows: 2 }),
        alert_summary: makeAlertSummary({
          total_alerts: 1,
          warn_alerts: 1,
          keepers_with_alerts: 1,
          duplicate_claim_identity_rows_keepers: 1,
        }),
      })
      const { container } = render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('duplicate-identity')).not.toBeNull())

      expect(container.querySelector('.kmh-row--warn')).not.toBeNull()
      expect(statValue(container, 'duplicate-claim-identity-rows')).toContain('2')
      expect(
        container.querySelector(
          '[data-stat-key="duplicate-claim-identity-rows"] .kmh-stat-value--warn',
        ),
      ).not.toBeNull()
      expect(screen.getAllByText('동일 claim identity 행').length).toBeGreaterThan(1)
    })
  })

  describe('backend alert summary', () => {
    it('surfaces total alert count in the summary strip', async () => {
      mockFetch.mockResolvedValue({
        ...makeResponse([
          makeEntry({
            keeper_id: 'alerted',
            duplicate_claim_identity_rows: 2,
            alerts: [{
              code: 'duplicate_claim_identity_rows',
              severity: 'warn',
              target: 'duplicate_claim_identity_rows',
              label: '동일 claim identity 행',
              message: 'Duplicate Memory OS claim identities remain on disk',
              value: 2,
              threshold: 0,
            }],
          }),
        ], { duplicate_claim_identity_rows: 2 }),
        alert_summary: makeAlertSummary({
          total_alerts: 1,
          warn_alerts: 1,
          keepers_with_alerts: 1,
          duplicate_claim_identity_rows_keepers: 1,
        }),
      })
      const { container } = render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('alerted')).not.toBeNull())

      expect(statValue(container, 'alerts')).toBe('1')
    })

  })

  describe('store read errors', () => {
    it('renders every failed keeper and the backend error instead of hiding the row', async () => {
      mockFetch.mockResolvedValue({
        ...makeResponse([makeEntry({ keeper_id: 'healthy' })]),
        read_error_count: 1,
        read_errors: [{
          keeper_id: 'retired-store',
          error: 'Fact_store_decode_error: retired-store.facts.jsonl:1',
        }],
      })
      const { container } = render(html`<${KeeperMemoryHealth} />`)

      await waitFor(() => expect(screen.getByText('Memory OS 저장소 읽기 오류 1건')).not.toBeNull())
      const alert = container.querySelector('.kmh-read-errors[role="alert"]')
      expect(alert?.textContent).toContain('retired-store')
      expect(alert?.textContent).toContain('Fact_store_decode_error')
      expect(screen.getByText('healthy')).not.toBeNull()
      expect(statValue(container, 'read-errors')).toBe('1')
    })
  })

  // ── render states ─────────────────────────────────────
  describe('render states', () => {
    it('shows the loading state before the fetch resolves', () => {
      // Never-resolving promise keeps the component in its initial loading branch.
      mockFetch.mockReturnValue(new Promise<KeeperMemoryHealthResponse>(() => {}))
      render(html`<${KeeperMemoryHealth} />`)
      expect(screen.getByText('로딩중...')).not.toBeNull()
    })

    it('shows the error state when the fetch rejects', async () => {
      mockFetch.mockRejectedValue(new Error('boom'))
      render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('데이터 로드 실패: boom')).not.toBeNull())
    })

    it('shows the empty-keepers message when the response has no keepers', async () => {
      mockFetch.mockResolvedValue(makeResponse([]))
      render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('등록된 키퍼 팩트 스토어 없음.')).not.toBeNull())
    })

    it('renders one table row per keeper with its id', async () => {
      mockFetch.mockResolvedValue(
        makeResponse([
          makeEntry({ keeper_id: 'alpha' }),
          makeEntry({ keeper_id: 'beta' }),
        ]),
      )
      const { container } = render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())

      const rows = container.querySelectorAll('tbody tr')
      expect(rows.length).toBe(2)
      expect(screen.getByText('beta')).not.toBeNull()
      // The cadence counter total surfaces in the header strip.
      expect(screen.getByText('키퍼 메모리 상태')).not.toBeNull()
    })
  })
})
