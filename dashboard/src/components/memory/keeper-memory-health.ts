// KeeperMemoryHealth — per-keeper fact-store observability panel.
//
// Read-only diagnostic surface for Lab > 키퍼 메모리 상태.
// Shows fact-store sizes, GC dry-run statistics, and the fleet-wide
// librarian cadence counter so operators can monitor what the
// disabled GC leaves on disk.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchKeeperMemoryHealth,
  type KeeperMemoryHealthAlert,
  type KeeperMemoryHealthKeeperEntry,
  type KeeperMemoryHealthResponse,
} from '../../api/dashboard'
import { DEFAULT_PANEL_REFRESH_MS, formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../../lib/auto-refresh'

// Rows whose events-to-facts ratio exceeds this threshold are flagged for
// operator attention by the backend. Keep the fallback threshold only for
// legacy responses that predate typed alerts.
const LEGACY_EVENTS_TO_FACTS_RATIO_WARN_THRESHOLD = 2

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
}

function entryAlerts(entry: KeeperMemoryHealthKeeperEntry): KeeperMemoryHealthAlert[] {
  return entry.alerts ?? []
}

function isRowWarning(entry: KeeperMemoryHealthKeeperEntry): boolean {
  if (entryAlerts(entry).length > 0) return true
  return (
    entry.events_to_facts_ratio > LEGACY_EVENTS_TO_FACTS_RATIO_WARN_THRESHOLD
    || entry.ttl_expired_on_disk > 0
  )
}

function alertLabel(code: string): string {
  switch (code) {
    case 'ttl_expired_on_disk':
      return 'TTL'
    case 'near_duplicate':
      return '중복'
    case 'events_to_facts_ratio_high':
      return '비율'
    default:
      return code
  }
}

function KeeperRow({ entry }: { entry: KeeperMemoryHealthKeeperEntry }) {
  const warn = isRowWarning(entry)
  const ratioStr = entry.events_to_facts_ratio.toFixed(2)
  const alerts = entryAlerts(entry)

  return html`
    <tr class=${warn ? 'kmh-row--warn' : ''}>
      <td>${entry.keeper_id}</td>
      <td>${entry.facts.toLocaleString()}</td>
      <td>${formatBytes(entry.facts_bytes)}</td>
      <td>
        ${alerts.some(alert => alert.code === 'events_to_facts_ratio_high')
          || entry.events_to_facts_ratio > LEGACY_EVENTS_TO_FACTS_RATIO_WARN_THRESHOLD
          ? html`<span class="kmh-badge kmh-badge--warn">${ratioStr}</span>`
          : html`<span>${ratioStr}</span>`}
      </td>
      <td>
        ${entry.ttl_expired_on_disk > 0
          ? html`<span class="kmh-badge kmh-badge--warn">${entry.ttl_expired_on_disk}</span>`
          : html`<span class="kmh-badge kmh-badge--ok">0</span>`}
      </td>
      <td>${entry.near_duplicate}</td>
      <td>
        ${alerts.length > 0
          ? alerts.map(alert => html`
            <span class="kmh-badge kmh-badge--warn" title=${alert.message}>${alertLabel(alert.code)}</span>
          `)
          : html`<span class="kmh-badge kmh-badge--ok">정상</span>`}
      </td>
    </tr>
  `
}

export function KeeperMemoryHealth() {
  const [data, setData] = useState<KeeperMemoryHealthResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    // useEffect is appropriate here: this is external-system synchronization
    // (periodic HTTP fetch from the MASC API), not derived state or event response.
    const controller = new AbortController()

    const refresh = async () => {
      try {
        const result = await fetchKeeperMemoryHealth()
        if (controller.signal.aborted) return
        setData(result)
        setError(null)
      } catch (err) {
        if (controller.signal.aborted) return
        setError(err instanceof Error ? err.message : 'keeper-memory-health fetch failed')
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
      <div class="kmh-panel">
        <p class="kmh-empty">로딩중...</p>
      </div>
    `
  }

  if (error !== null && data === null) {
    return html`
      <div class="kmh-panel">
        <p class="kmh-empty">데이터 로드 실패: ${error}</p>
      </div>
    `
  }

  if (data === null) {
    return html`
      <div class="kmh-panel">
        <p class="kmh-empty">데이터 없음.</p>
      </div>
    `
  }

  const generatedAt = new Date(data.generated_at * 1000).toLocaleTimeString()
  const derivedAlertCount = data.keepers.reduce((total, entry) => {
    const alerts = entryAlerts(entry)
    if (alerts.length > 0) return total + alerts.length
    return total + (isRowWarning(entry) ? 1 : 0)
  }, 0)
  const totalAlerts = data.alert_summary?.total_alerts ?? derivedAlertCount

  return html`
    <div class="kmh-panel">
      <div class="kmh-header">
        <div class="kmh-title">키퍼 메모리 상태</div>
        <div class="kmh-totals-strip">
          <div class="kmh-stat">
            <span class="kmh-stat-label">전체 사실</span>
            <span class="kmh-stat-value">${data.totals.facts.toLocaleString()}</span>
          </div>
          <div class="kmh-stat">
            <span class="kmh-stat-label">사실 크기</span>
            <span class="kmh-stat-value">${formatBytes(data.totals.facts_bytes)}</span>
          </div>
          <div class="kmh-stat">
            <span class="kmh-stat-label">이벤트 크기</span>
            <span class="kmh-stat-value">${formatBytes(data.totals.events_bytes)}</span>
          </div>
          <div class="kmh-stat">
            <span class="kmh-stat-label">TTL 만료(디스크)</span>
            <span class=${`kmh-stat-value${data.totals.ttl_expired_on_disk > 0 ? ' kmh-stat-value--warn' : ''}`}>
              ${data.totals.ttl_expired_on_disk}
            </span>
          </div>
          <div class="kmh-stat">
            <span class="kmh-stat-label">근접중복</span>
            <span class="kmh-stat-value">${data.totals.near_duplicate}</span>
          </div>
          <div class="kmh-stat">
            <span class="kmh-stat-label">경보</span>
            <span class=${`kmh-stat-value${totalAlerts > 0 ? ' kmh-stat-value--warn' : ''}`}>
              ${totalAlerts}
            </span>
          </div>
          <div class="kmh-stat">
            <span class="kmh-stat-label">케이던스 카운터</span>
            <span class="kmh-stat-value">${data.cadence_counter_entries}</span>
          </div>
          <div class="kmh-stat">
            <span class="kmh-stat-label">키퍼 수</span>
            <span class="kmh-stat-value">${data.keepers.length}</span>
          </div>
        </div>
        <div class="kmh-refresh-label">
          ${formatAutoRefreshLabel(DEFAULT_PANEL_REFRESH_MS)} — 기준 ${generatedAt}
        </div>
      </div>

      ${data.keepers.length === 0
        ? html`<p class="kmh-empty">등록된 키퍼 팩트 스토어 없음.</p>`
        : html`
          <div class="kmh-table-wrap">
            <table class="kmh-table">
              <thead>
                <tr>
                  <th>키퍼</th>
                  <th>사실</th>
                  <th>bytes</th>
                  <th>events:facts 비율</th>
                  <th>만료(디스크)</th>
                  <th>근접중복</th>
                  <th>경보</th>
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
