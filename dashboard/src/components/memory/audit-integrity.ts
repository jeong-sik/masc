// AuditIntegrity — per-keeper resilience audit hash-chain verification panel.
//
// Read-only diagnostic surface for Lab > 감사 무결성.
// Runs Shared_audit.Store.verify server-side and shows the result:
// last verification time, entries checked, OK/failed, and the first
// broken-link index so operators can spot tamper evidence.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchAuditIntegrity,
  type AuditIntegrityKeeperEntry,
  type AuditIntegrityResponse,
} from '../../api/dashboard'
import { DEFAULT_PANEL_REFRESH_MS, formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../../lib/auto-refresh'

function KeeperRow({ entry }: { entry: AuditIntegrityKeeperEntry }) {
  return html`
    <tr class=${entry.ok ? '' : 'ai-row--fail'}>
      <td>${entry.keeper_id}</td>
      <td>${entry.entries.toLocaleString()}</td>
      <td>
        ${entry.ok
          ? html`<span class="ai-badge ai-badge--ok">정상</span>`
          : html`<span class="ai-badge ai-badge--fail">실패</span>`}
      </td>
      <td>${entry.broken_at !== null ? String(entry.broken_at) : '—'}</td>
      <td class="ai-cell-detail">${entry.detail ?? '—'}</td>
    </tr>
  `
}

export function AuditIntegrity() {
  const [data, setData] = useState<AuditIntegrityResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    // useEffect is appropriate here: this is external-system synchronization
    // (periodic HTTP fetch from the MASC API), not derived state or event response.
    const controller = new AbortController()

    const refresh = async () => {
      try {
        const result = await fetchAuditIntegrity()
        if (controller.signal.aborted) return
        setData(result)
        setError(null)
      } catch (err) {
        if (controller.signal.aborted) return
        setError(err instanceof Error ? err.message : 'audit-integrity fetch failed')
      } finally {
        if (!controller.signal.aborted) setLoading(false)
      }
    }

    setLoading(true)
    void refresh()
    const cleanup = setupVisibleAutoRefresh(() => { void refresh() }, DEFAULT_PANEL_REFRESH_MS)

    return () => {
      controller.abort()
      cleanup()
    }
  }, [])

  if (loading && data === null) {
    return html`
      <div class="ai-panel">
        <p class="ai-empty">로딩중...</p>
      </div>
    `
  }

  if (error !== null && data === null) {
    return html`
      <div class="ai-panel">
        <p class="ai-empty">데이터 로드 실패: ${error}</p>
      </div>
    `
  }

  if (data === null) {
    return html`
      <div class="ai-panel">
        <p class="ai-empty">데이터 없음.</p>
      </div>
    `
  }

  const generatedAt = new Date(data.generated_at * 1000).toLocaleTimeString()
  const hasFailures = data.totals.failed > 0

  return html`
    <div class="ai-panel">
      <div class="ai-header">
        <div class="ai-title">감사 무결성</div>
        <div class="ai-totals-strip">
          <div class="ai-stat" data-stat-key="keepers">
            <span class="ai-stat-label">검증 키퍼</span>
            <span class="ai-stat-value">${data.totals.keepers}</span>
          </div>
          <div class="ai-stat" data-stat-key="entries">
            <span class="ai-stat-label">검증 엔트리</span>
            <span class="ai-stat-value">${data.totals.entries.toLocaleString()}</span>
          </div>
          <div class="ai-stat" data-stat-key="ok">
            <span class="ai-stat-label">정상</span>
            <span class="ai-stat-value">${data.totals.ok}</span>
          </div>
          <div class="ai-stat" data-stat-key="failed">
            <span class="ai-stat-label">실패</span>
            <span class=${`ai-stat-value${hasFailures ? ' ai-stat-value--fail' : ''}`}>
              ${data.totals.failed}
            </span>
          </div>
          <div class="ai-stat" data-stat-key="resilience-enabled">
            <span class="ai-stat-label">Resilience 감사</span>
            <span class="ai-stat-value">${data.resilience_enabled ? '활성' : '비활성'}</span>
          </div>
        </div>
        <div class="ai-refresh-label">
          ${formatAutoRefreshLabel(DEFAULT_PANEL_REFRESH_MS)} — 기준 ${generatedAt}
        </div>
      </div>

      ${data.keepers.length === 0
        ? html`<p class="ai-empty">검증할 감사 로그 없음 (resilience audit 기록 없음).</p>`
        : html`
          <div class="ai-table-wrap">
            <table class="ai-table">
              <thead>
                <tr>
                  <th>키퍼</th>
                  <th>검증 엔트리</th>
                  <th>체인 상태</th>
                  <th>실패 지점</th>
                  <th>상세</th>
                </tr>
              </thead>
              <tbody>
                ${data.keepers.map(entry => html`<${KeeperRow} key=${entry.keeper_id} entry=${entry} />`)}
              </tbody>
            </table>
          </div>
        `}
    </div>
  `
}
