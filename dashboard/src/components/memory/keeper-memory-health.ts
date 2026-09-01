// KeeperMemoryHealth — per-keeper current-memory snapshot observability.
//
// Read-only diagnostic surface for Lab > 키퍼 메모리 상태.
// Shows ordinary and source-bound current snapshots, exact latest delta, read
// failures, and Librarian lane pressure. There is no legacy event/fact-store or
// GC view.

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
const SOURCE_SNAPSHOT_READ_ERROR_TARGET: KeeperMemoryHealthAlertTarget = 'source_snapshot_read_error'
const LIBRARIAN_LANE_BUSY_TARGET: KeeperMemoryHealthAlertTarget = 'librarian_lane_busy'
const LIBRARIAN_FAILURES_TARGET: KeeperMemoryHealthAlertTarget = 'librarian_failures'
const LIBRARIAN_STARVATION_TARGET: KeeperMemoryHealthAlertTarget = 'librarian_starvation'

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

function hasErrorAlert(alerts: KeeperMemoryHealthAlert[]): boolean {
  return alerts.some(alert => alert.severity === 'error')
}

function alertBadgeClass(alert: KeeperMemoryHealthAlert): string {
  return alert.severity === 'error' ? 'kmh-badge kmh-badge--error' : 'kmh-badge kmh-badge--warn'
}

function KeeperRow({ entry }: { entry: KeeperMemoryHealthKeeperEntry }) {
  const alerts = entryAlerts(entry)
  const error = hasErrorAlert(alerts)
  const warn = alerts.length > 0
  const readErrorWarn = hasTargetAlert(alerts, SNAPSHOT_READ_ERROR_TARGET)
  const sourceReadErrorWarn = hasTargetAlert(alerts, SOURCE_SNAPSHOT_READ_ERROR_TARGET)
  const laneBusyWarn = hasTargetAlert(alerts, LIBRARIAN_LANE_BUSY_TARGET)
  const starving = hasTargetAlert(alerts, LIBRARIAN_STARVATION_TARGET)
  const librarianFailing = starving || hasTargetAlert(alerts, LIBRARIAN_FAILURES_TARGET)
  const visionReasons = entry.vision_ingest_error_reasons
    .map(reason => `${reason.reason} ×${reason.count}`)
    .join(', ')

  return html`
    <tr class=${error ? 'kmh-row--error' : warn ? 'kmh-row--warn' : ''}>
      <td>${entry.keeper_id}</td>
      <td>${entry.revision}</td>
      <td>${entry.facts.toLocaleString()}</td>
      <td>${entry.observed_facts.toLocaleString()} / ${entry.derived_facts.toLocaleString()}</td>
      <td>
        ${entry.support_invalidations > 0
          ? html`<span class="kmh-badge kmh-badge--muted">${entry.support_invalidations}</span>`
          : html`<span class="kmh-badge kmh-badge--ok">0</span>`}
      </td>
      <td>${formatBytes(entry.snapshot_bytes)}</td>
      <td><span class="kmh-badge kmh-badge--ok">+${entry.added}</span></td>
      <td><span class="kmh-badge kmh-badge--ok">−${entry.removed}</span></td>
      <td>
        ${laneBusyWarn
          ? html`<span class="kmh-badge kmh-badge--warn">${entry.librarian_lane_busy}</span>`
          : html`<span class="kmh-badge kmh-badge--ok">${entry.librarian_lane_busy}</span>`}
      </td>
      <td>
        ${starving
          ? html`<span class="kmh-badge kmh-badge--error">${entry.librarian_failures}</span>`
          : librarianFailing
            ? html`<span class="kmh-badge kmh-badge--warn">${entry.librarian_failures}</span>`
            : html`<span class="kmh-badge kmh-badge--ok">${entry.librarian_failures}</span>`}
      </td>
      <td>
        ${readErrorWarn
          ? html`<span class="kmh-badge kmh-badge--warn" title=${entry.read_error ?? ''}>오류</span>`
          : entry.snapshot_present
            ? html`<span class="kmh-badge kmh-badge--ok">정상</span>`
            : starving
              ? html`<span class="kmh-badge kmh-badge--error">없음</span>`
              : html`<span class="kmh-badge kmh-badge--muted">없음</span>`}
      </td>
      <td>
        ${sourceReadErrorWarn
          ? html`<span class="kmh-badge kmh-badge--warn" title=${entry.source_read_error ?? ''}>오류</span>`
          : entry.source_snapshot_present
            ? html`<span class="kmh-badge kmh-badge--ok" title=${formatBytes(entry.source_snapshot_bytes)}>
                r${entry.source_revision} · ${entry.source_facts} / 무효 ${entry.source_invalidations}
              </span>`
            : html`<span class="kmh-badge kmh-badge--muted">없음</span>`}
      </td>
      <td>
        ${entry.vision_ingest_errors > 0
          ? html`<span class="kmh-badge kmh-badge--warn" title=${visionReasons}>
              ${entry.vision_ingest_errors}
            </span>`
          : html`<span class="kmh-badge kmh-badge--ok">0</span>`}
      </td>
      <td>
        ${alerts.length > 0
          ? alerts.map(alert => html`
            <span class=${alertBadgeClass(alert)} title=${alert.message}>${alert.label}</span>
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
  const errorAlerts = data.alert_summary.error_alerts
  const readErrorWarn = data.alert_summary.snapshot_read_error_keepers > 0
  const sourceReadErrorWarn = data.alert_summary.source_snapshot_read_error_keepers > 0
  const laneBusyWarn = data.alert_summary.librarian_lane_busy_keepers > 0
  const starvingKeepers = data.alert_summary.librarian_starving_keepers
  const librarianFailureClass = starvingKeepers > 0
    ? ' kmh-stat-value--error'
    : data.totals.librarian_failures > 0
      ? ' kmh-stat-value--warn'
      : ''
  const alertClass = errorAlerts > 0
    ? ' kmh-stat-value--error'
    : totalAlerts > 0
      ? ' kmh-stat-value--warn'
      : ''

  return html`
    <div class="kmh-panel">
      <div class="kmh-header">
        <div class="kmh-title">키퍼 메모리 상태</div>
        <div class="kmh-totals-strip">
          <div class="kmh-stat" data-stat-key="facts">
            <span class="kmh-stat-label">전체 사실</span>
            <span class="kmh-stat-value">${data.totals.facts.toLocaleString()}</span>
          </div>
          <div class="kmh-stat" data-stat-key="observed-facts">
            <span class="kmh-stat-label">관측 사실</span>
            <span class="kmh-stat-value">${data.totals.observed_facts.toLocaleString()}</span>
          </div>
          <div class="kmh-stat" data-stat-key="derived-facts">
            <span class="kmh-stat-label">파생 사실</span>
            <span class="kmh-stat-value">${data.totals.derived_facts.toLocaleString()}</span>
          </div>
          <div class="kmh-stat" data-stat-key="support-invalidations">
            <span class="kmh-stat-label">지지 무효화</span>
            <span class="kmh-stat-value">
              ${data.totals.support_invalidations.toLocaleString()}
            </span>
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
          <div class="kmh-stat" data-stat-key="source-facts">
            <span class="kmh-stat-label">소스 사실</span>
            <span class="kmh-stat-value">${data.totals.source_facts.toLocaleString()}</span>
          </div>
          <div class="kmh-stat" data-stat-key="source-invalidations">
            <span class="kmh-stat-label">소스 무효화</span>
            <span class="kmh-stat-value">${data.totals.source_invalidations.toLocaleString()}</span>
          </div>
          <div class="kmh-stat" data-stat-key="source-snapshot-bytes">
            <span class="kmh-stat-label">소스 크기</span>
            <span class="kmh-stat-value">${formatBytes(data.totals.source_snapshot_bytes)}</span>
          </div>
          <div class="kmh-stat" data-stat-key="read-errors">
            <span class="kmh-stat-label">읽기 오류</span>
            <span class=${`kmh-stat-value${readErrorWarn ? ' kmh-stat-value--warn' : ''}`}>
              ${data.totals.read_errors}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="source-read-errors">
            <span class="kmh-stat-label">소스 읽기 오류</span>
            <span class=${`kmh-stat-value${sourceReadErrorWarn ? ' kmh-stat-value--warn' : ''}`}>
              ${data.totals.source_read_errors}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="vision-ingest-errors">
            <span class="kmh-stat-label">Vision ingest 오류</span>
            <span class=${`kmh-stat-value${data.totals.vision_ingest_errors > 0 ? ' kmh-stat-value--warn' : ''}`}>
              ${data.totals.vision_ingest_errors}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="librarian-lane-busy">
            <span class="kmh-stat-label">Librarian lane busy</span>
            <span class=${`kmh-stat-value${laneBusyWarn ? ' kmh-stat-value--warn' : ''}`}>
              ${data.totals.librarian_lane_busy}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="librarian-failures">
            <span class="kmh-stat-label">Librarian 실패</span>
            <span class=${`kmh-stat-value${librarianFailureClass}`}>
              ${data.totals.librarian_failures}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="starving-keepers">
            <span class="kmh-stat-label">일반 기억 없는 키퍼</span>
            <span class=${`kmh-stat-value${starvingKeepers > 0 ? ' kmh-stat-value--error' : ''}`}>
              ${starvingKeepers}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="alerts">
            <span class="kmh-stat-label">경보</span>
            <span class=${`kmh-stat-value${alertClass}`}>
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
        ? html`<p class="kmh-empty">등록된 current-memory snapshot 또는 Keeper 없음.</p>`
        : html`
          <div class="kmh-table-wrap">
            <table class="kmh-table">
              <thead>
                <tr>
                  <th>키퍼</th>
                  <th>revision</th>
                  <th>사실</th>
                  <th>관측 / 파생</th>
                  <th>지지 무효화</th>
                  <th>bytes</th>
                  <th>추가</th>
                  <th>제거</th>
                  <th>lane busy</th>
                  <th>실패</th>
                  <th>snapshot</th>
                  <th>source snapshot</th>
                  <th>Vision 오류</th>
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
