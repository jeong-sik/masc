// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type {
  AuditIntegrityKeeperEntry,
  AuditIntegrityResponse,
} from '../../api/dashboard'

// ── Mock API ──────────────────────────────────────────
// AuditIntegrity fetches via fetchAuditIntegrity() inside useEffect.
// Mocking the module lets us drive every render branch without a real HTTP call.

const mockFetch = vi.fn<() => Promise<AuditIntegrityResponse>>()

vi.mock('../../api/dashboard', () => ({
  fetchAuditIntegrity: () => mockFetch(),
}))

// ── Import after mocks ────────────────────────────────

import { AuditIntegrity } from './audit-integrity'

function makeEntry(
  overrides: Partial<AuditIntegrityKeeperEntry> = {},
): AuditIntegrityKeeperEntry {
  return {
    keeper_id: 'alpha',
    entries: 12,
    ok: true,
    broken_at: null,
    detail: null,
    ...overrides,
  }
}

function makeResponse(
  keepers: AuditIntegrityKeeperEntry[],
  totalsOverrides: Partial<AuditIntegrityResponse['totals']> = {},
  enabled = true,
): AuditIntegrityResponse {
  return {
    generated_at: 1_700_000_000,
    resilience_enabled: enabled,
    keepers,
    totals: {
      keepers: keepers.length,
      entries: keepers.reduce((acc, k) => acc + k.entries, 0),
      ok: keepers.filter(k => k.ok).length,
      failed: keepers.filter(k => !k.ok).length,
      ...totalsOverrides,
    },
  }
}

function statValue(container: Element, key: string): string | undefined {
  const stat = container.querySelector(`.ai-totals-strip .ai-stat[data-stat-key="${key}"]`)
  return stat?.querySelector('.ai-stat-value')?.textContent ?? undefined
}

describe('AuditIntegrity', () => {
  beforeEach(() => {
    mockFetch.mockReset()
  })
  afterEach(() => cleanup())

  describe('chain status rendering', () => {
    it('renders an ok badge and no failure detail for an intact chain', async () => {
      mockFetch.mockResolvedValue(makeResponse([makeEntry({ keeper_id: 'alpha' })]))
      const { container } = render(html`<${AuditIntegrity} />`)
      await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())

      expect(container.querySelector('.ai-badge--ok')).not.toBeNull()
      expect(container.querySelector('.ai-row--fail')).toBeNull()
    })

    it('flags a failed chain with broken index and detail', async () => {
      mockFetch.mockResolvedValue(
        makeResponse([
          makeEntry({
            keeper_id: 'tampered',
            ok: false,
            broken_at: 2,
            detail: 'prev_hash mismatch at index 2',
          }),
        ]),
      )
      const { container } = render(html`<${AuditIntegrity} />`)
      await waitFor(() => expect(screen.getByText('tampered')).not.toBeNull())

      expect(container.querySelector('.ai-row--fail')).not.toBeNull()
      expect(container.querySelector('.ai-badge--fail')).not.toBeNull()
      expect(screen.getByText('2')).not.toBeNull()
      expect(screen.getByText('prev_hash mismatch at index 2')).not.toBeNull()
    })

    it('surfaces the failed count in the totals strip', async () => {
      mockFetch.mockResolvedValue(
        makeResponse([
          makeEntry({ keeper_id: 'broken', ok: false, broken_at: 1, detail: 'boom' }),
          makeEntry({ keeper_id: 'healthy' }),
        ]),
      )
      const { container } = render(html`<${AuditIntegrity} />`)
      await waitFor(() => expect(screen.getByText('broken')).not.toBeNull())

      expect(statValue(container, 'failed')).toBe('1')
      expect(statValue(container, 'ok')).toBe('1')
      expect(statValue(container, 'keepers')).toBe('2')
      expect(container.querySelector('[data-stat-key="failed"] .ai-stat-value--fail')).not.toBeNull()
    })
  })

  describe('render states', () => {
    it('shows the loading state before the fetch resolves', () => {
      // Never-resolving promise keeps the component in its initial loading branch.
      mockFetch.mockReturnValue(new Promise<AuditIntegrityResponse>(() => {}))
      render(html`<${AuditIntegrity} />`)
      expect(screen.getByText('로딩중...')).not.toBeNull()
    })

    it('shows the error state when the fetch rejects', async () => {
      mockFetch.mockRejectedValue(new Error('boom'))
      render(html`<${AuditIntegrity} />`)
      await waitFor(() => expect(screen.getByText('데이터 로드 실패: boom')).not.toBeNull())
    })

    it('shows the empty-keepers message when the response has no keepers', async () => {
      mockFetch.mockResolvedValue(makeResponse([]))
      render(html`<${AuditIntegrity} />`)
      await waitFor(() => expect(screen.getByText('검증할 감사 로그 없음 (resilience audit 기록 없음).')).not.toBeNull())
    })

    it('renders one table row per keeper and the resilience flag', async () => {
      mockFetch.mockResolvedValue(
        makeResponse([makeEntry({ keeper_id: 'alpha' }), makeEntry({ keeper_id: 'beta' })]),
      )
      const { container } = render(html`<${AuditIntegrity} />`)
      await waitFor(() => expect(screen.getByText('alpha')).not.toBeNull())

      const rows = container.querySelectorAll('tbody tr')
      expect(rows.length).toBe(2)
      expect(screen.getByText('beta')).not.toBeNull()
      expect(statValue(container, 'resilience-enabled')).toBe('활성')
    })

    it('shows the resilience flag as inactive when the feature is off', async () => {
      mockFetch.mockResolvedValue(makeResponse([], {}, false))
      const { container } = render(html`<${AuditIntegrity} />`)
      await waitFor(() =>
        expect(container.querySelector('[data-stat-key="resilience-enabled"]')).not.toBeNull(),
      )
      expect(statValue(container, 'resilience-enabled')).toBe('비활성')
    })
  })
})
