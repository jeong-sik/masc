// KeeperMemoryHealth — per-keeper current-memory snapshot observability.
//
// Read-only diagnostic surface for Lab > 키퍼 메모리 상태.
// Shows the single current snapshot revision, exact latest delta, read failures,
// and Librarian lane pressure. There is no legacy event/fact-store or GC view.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchKeeperMemoryHealth,
  type KeeperMemoryHealthAlert,
  type KeeperMemoryHealthAlertTarget,
  type KeeperMemoryHealthKeeperEntry,
  type KeeperMemoryHealthResponse,
} from '../../api/dashboard'
import { DEFAULT_PANEL_REFRESH_MS, formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../../lib/auto-refresh'

const SNAPSHOT_READ_ERROR_TARGET: KeeperMemoryHealthAlertTarget = 'snapshot_read_error'
const LIBRARIAN_LANE_BUSY_TARGET: KeeperMemoryHealthAlertTarget = 'librarian_lane_busy'

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
}

function entryAlerts(entry: KeeperMemoryHealthKeeperEntry): KeeperMemoryHealthAlert[] {
  return entry.alerts
}

function hasTargetAlert(alerts: KeeperMemoryHealthAlert[], target: KeeperMemoryHealthAlertTarget): boolean {
  return alerts.some(alert => alert.target === target)
}

function isRowWarning(entry: KeeperMemoryHealthKeeperEntry): boolean {
  return entryAlerts(entry).length > 0
}

function KeeperRow({ entry }: { entry: KeeperMemoryHealthKeeperEntry }) {
  const alerts = entryAlerts(entry)
  const warn = isRowWarning(entry)
  const readErrorWarn = hasTargetAlert(alerts, SNAPSHOT_READ_ERROR_TARGET)
  const laneBusyWarn = hasTargetAlert(alerts, LIBRARIAN_LANE_BUSY_TARGET)

  return html`
    <tr class=${warn ? 'kmh-row--warn' : ''}>
      <td>${entry.keeper_id}</td>
      <td>${entry.revision}</td>
      <td>${entry.facts.toLocaleString()}</td>
      <td>${formatBytes(entry.snapshot_bytes)}</td>
      <td><span class="kmh-badge kmh-badge--ok">+${entry.added}</span></td>
      <td><span class="kmh-badge kmh-badge--ok">−${entry.removed}</span></td>
      <td>
        ${laneBusyWarn
          ? html`<span class="kmh-badge kmh-badge--warn">${entry.librarian_lane_busy}</span>`
          : html`<span class="kmh-badge kmh-badge--ok">${entry.librarian_lane_busy}</span>`}
      </td>
      <td>
        ${readErrorWarn
          ? html`<span class="kmh-badge kmh-badge--warn" title=${entry.read_error ?? ''}>오류</span>`
          : html`<span class="kmh-badge kmh-badge--ok">정상</span>`}
      </td>
      <td>
        ${alerts.length > 0
          ? alerts.map(alert => html`
            <span class="kmh-badge kmh-badge--warn" title=${alert.message}>${alert.label}</span>
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
  const totalAlerts = data.alert_summary.total_alerts
  const readErrorWarn = data.alert_summary.snapshot_read_error_keepers > 0
  const laneBusyWarn = data.alert_summary.librarian_lane_busy_keepers > 0

  return html`
    <div class="kmh-panel">
      <div class="kmh-header">
        <div class="kmh-title">키퍼 메모리 상태</div>
        <div class="kmh-totals-strip">
          <div class="kmh-stat" data-stat-key="facts">
            <span class="kmh-stat-label">전체 사실</span>
            <span class="kmh-stat-value">${data.totals.facts.toLocaleString()}</span>
          </div>
          <div class="kmh-stat" data-stat-key="snapshot-bytes">
            <span class="kmh-stat-label">스냅샷 크기</span>
            <span class="kmh-stat-value">${formatBytes(data.totals.snapshot_bytes)}</span>
          </div>
          <div class="kmh-stat" data-stat-key="added">
            <span class="kmh-stat-label">최근 추가</span>
            <span class="kmh-stat-value">+${data.totals.added}</span>
          </div>
          <div class="kmh-stat" data-stat-key="removed">
            <span class="kmh-stat-label">최근 제거</span>
            <span class="kmh-stat-value">−${data.totals.removed}</span>
          </div>
          <div class="kmh-stat" data-stat-key="read-errors">
            <span class="kmh-stat-label">읽기 오류</span>
            <span class=${`kmh-stat-value${readErrorWarn ? ' kmh-stat-value--warn' : ''}`}>
              ${data.totals.read_errors}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="librarian-lane-busy">
            <span class="kmh-stat-label">Librarian lane busy</span>
            <span class=${`kmh-stat-value${laneBusyWarn ? ' kmh-stat-value--warn' : ''}`}>
              ${data.totals.librarian_lane_busy}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="alerts">
            <span class="kmh-stat-label">경보</span>
            <span class=${`kmh-stat-value${totalAlerts > 0 ? ' kmh-stat-value--warn' : ''}`}>
              ${totalAlerts}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="cadence-counter">
            <span class="kmh-stat-label">케이던스 카운터</span>
            <span class="kmh-stat-value">${data.cadence_counter_entries}</span>
          </div>
          <div class="kmh-stat" data-stat-key="keeper-count">
            <span class="kmh-stat-label">키퍼 수</span>
            <span class="kmh-stat-value">${data.keepers.length}</span>
          </div>
        </div>
        <div class="kmh-refresh-label">
          ${formatAutoRefreshLabel(DEFAULT_PANEL_REFRESH_MS)} — 기준 ${generatedAt}
        </div>
      </div>

      ${data.keepers.length === 0
        ? html`<p class="kmh-empty">등록된 current-memory snapshot 없음.</p>`
        : html`
          <div class="kmh-table-wrap">
            <table class="kmh-table">
              <thead>
                <tr>
                  <th>키퍼</th>
                  <th>revision</th>
                  <th>사실</th>
                  <th>bytes</th>
                  <th>추가</th>
                  <th>제거</th>
                  <th>lane busy</th>
                  <th>snapshot</th>
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
