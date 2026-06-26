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
    events_to_facts_ratio: 2,
    ttl_expired_on_disk: 0,
    near_duplicate: 0,
    alerts: [],
    ...overrides,
  }
}

function makeResponse(
  keepers: KeeperMemoryHealthKeeperEntry[],
  totalsOverrides: Partial<KeeperMemoryHealthResponse['totals']> = {},
): KeeperMemoryHealthResponse {
  return {
    generated_at: 1_700_000_000,
    cadence_counter_entries: 3,
    keepers,
    totals: {
      facts: 0,
      facts_bytes: 0,
      events_bytes: 0,
      ttl_expired_on_disk: 0,
      near_duplicate: 0,
      ...totalsOverrides,
    },
    alert_summary: {
      total_alerts: 0,
      warn_alerts: 0,
      keepers_with_alerts: 0,
      ttl_expired_keepers: 0,
      near_duplicate_keepers: 0,
      high_event_ratio_keepers: 0,
      thresholds: {
        ttl_expired_on_disk: 0,
        near_duplicate: 0,
        events_to_facts_ratio: 2,
      },
    },
  }
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

  // ── isRowWarning boundary (via row class + ratio badge) ──
  // Component operator is strict greater-than against threshold 2:
  //   ratio === 2 → NOT a warning
  //   ratio  > 2 → warning
  describe('isRowWarning ratio boundary (threshold is > 2)', () => {
    it('does not flag a row when the ratio equals the threshold (2)', async () => {
      mockFetch.mockResolvedValue(
        makeResponse([
          makeEntry({ keeper_id: 'at-threshold', events_to_facts_ratio: 2, ttl_expired_on_disk: 0 }),
        ]),
      )
      const { container } = render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('at-threshold')).not.toBeNull())

      expect(container.querySelector('.kmh-row--warn')).toBeNull()
      // The ratio cell renders 2.00 inside a plain span, not a warn badge.
      expect(container.querySelector('.kmh-badge--warn')).toBeNull()
      expect(screen.getByText('2.00')).not.toBeNull()
    })

    it('flags a row when the ratio exceeds the threshold', async () => {
      mockFetch.mockResolvedValue(
        makeResponse([
          makeEntry({ keeper_id: 'over-threshold', events_to_facts_ratio: 3, ttl_expired_on_disk: 0 }),
        ]),
      )
      const { container } = render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('over-threshold')).not.toBeNull())

      expect(container.querySelector('.kmh-row--warn')).not.toBeNull()
      // The ratio cell is wrapped in a warn badge showing 3.00.
      const warnBadge = container.querySelector('.kmh-badge--warn')
      expect(warnBadge).not.toBeNull()
      expect(warnBadge!.textContent).toBe('3.00')
    })

    it('flags a row on ttl_expired_on_disk even when the ratio is at the threshold', async () => {
      // isRowWarning is an OR: ratio>2 OR ttl_expired_on_disk>0.
      mockFetch.mockResolvedValue(
        makeResponse([
          makeEntry({
            keeper_id: 'ttl-expired',
            events_to_facts_ratio: 2,
            ttl_expired_on_disk: 4,
            alerts: [{
              code: 'ttl_expired_on_disk',
              severity: 'warn',
              message: 'TTL-expired Memory OS fact rows remain on disk',
              value: 4,
              threshold: 0,
            }],
          }),
        ], { ttl_expired_on_disk: 4 }),
      )
      const { container } = render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('ttl-expired')).not.toBeNull())

      expect(container.querySelector('.kmh-row--warn')).not.toBeNull()
      expect(screen.getByText('TTL')).not.toBeNull()
    })
  })

  describe('backend alert summary', () => {
    it('surfaces total alert count in the summary strip', async () => {
      mockFetch.mockResolvedValue({
        ...makeResponse([
          makeEntry({
            keeper_id: 'alerted',
            ttl_expired_on_disk: 2,
            alerts: [{
              code: 'ttl_expired_on_disk',
              severity: 'warn',
              message: 'TTL-expired Memory OS fact rows remain on disk',
              value: 2,
              threshold: 0,
            }],
          }),
        ], { ttl_expired_on_disk: 2 }),
        alert_summary: {
          total_alerts: 1,
          warn_alerts: 1,
          keepers_with_alerts: 1,
          ttl_expired_keepers: 1,
          near_duplicate_keepers: 0,
          high_event_ratio_keepers: 0,
          thresholds: {
            ttl_expired_on_disk: 0,
            near_duplicate: 0,
            events_to_facts_ratio: 2,
          },
        },
      })
      const { container } = render(html`<${KeeperMemoryHealth} />`)
      await waitFor(() => expect(screen.getByText('alerted')).not.toBeNull())

      const alertStat = Array.from(container.querySelectorAll('.kmh-totals-strip .kmh-stat'))
        .find((stat) => stat.textContent === '경보1')
      expect(alertStat).not.toBeUndefined()
      expect(alertStat!.querySelector('.kmh-stat-value')?.textContent).toBe('1')
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
