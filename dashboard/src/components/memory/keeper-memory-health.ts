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
  type KeeperMemoryHealthAlertTarget,
  type KeeperMemoryHealthKeeperEntry,
  type KeeperMemoryHealthResponse,
} from '../../api/dashboard'
import { DEFAULT_PANEL_REFRESH_MS, formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../../lib/auto-refresh'

const EVENT_RATIO_ALERT_TARGET: KeeperMemoryHealthAlertTarget = 'events_to_facts_ratio'
const TTL_ALERT_TARGET: KeeperMemoryHealthAlertTarget = 'ttl_expired_on_disk'
const NEAR_DUPLICATE_ALERT_TARGET: KeeperMemoryHealthAlertTarget = 'near_duplicate'
const PROVIDER_SLOT_BUSY_ALERT_TARGET: KeeperMemoryHealthAlertTarget = 'provider_slot_busy'

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
}

function entryAlerts(entry: KeeperMemoryHealthKeeperEntry): KeeperMemoryHealthAlert[] {
  return entry.alerts
}

function providerSlotBusy(entry: KeeperMemoryHealthKeeperEntry): number {
  return entry.provider_slot_busy
}

function hasTargetAlert(alerts: KeeperMemoryHealthAlert[], target: KeeperMemoryHealthAlertTarget): boolean {
  return alerts.some(alert => alert.target === target)
}

function isRowWarning(entry: KeeperMemoryHealthKeeperEntry): boolean {
  return entryAlerts(entry).length > 0
}

function KeeperRow({ entry }: { entry: KeeperMemoryHealthKeeperEntry }) {
  const ratioStr = entry.events_to_facts_ratio.toFixed(2)
  const alerts = entryAlerts(entry)
  const warn = isRowWarning(entry)
  const ratioWarn = hasTargetAlert(alerts, EVENT_RATIO_ALERT_TARGET)
  const ttlWarn = hasTargetAlert(alerts, TTL_ALERT_TARGET)
  const nearDuplicateWarn = hasTargetAlert(alerts, NEAR_DUPLICATE_ALERT_TARGET)
  const providerSlotBusyWarn = hasTargetAlert(alerts, PROVIDER_SLOT_BUSY_ALERT_TARGET)
  const providerSlotBusyCount = providerSlotBusy(entry)

  return html`
    <tr class=${warn ? 'kmh-row--warn' : ''}>
      <td>${entry.keeper_id}</td>
      <td>${entry.facts.toLocaleString()}</td>
      <td>${formatBytes(entry.facts_bytes)}</td>
      <td>
        ${ratioWarn
          ? html`<span class="kmh-badge kmh-badge--warn">${ratioStr}</span>`
          : html`<span>${ratioStr}</span>`}
      </td>
      <td>
        ${ttlWarn
          ? html`<span class="kmh-badge kmh-badge--warn">${entry.ttl_expired_on_disk}</span>`
          : html`<span class="kmh-badge kmh-badge--ok">${entry.ttl_expired_on_disk}</span>`}
      </td>
      <td>
        ${nearDuplicateWarn
          ? html`<span class="kmh-badge kmh-badge--warn">${entry.near_duplicate}</span>`
          : html`<span class="kmh-badge kmh-badge--ok">${entry.near_duplicate}</span>`}
      </td>
      <td>
        ${providerSlotBusyWarn
          ? html`<span class="kmh-badge kmh-badge--warn">${providerSlotBusyCount}</span>`
          : html`<span class="kmh-badge kmh-badge--ok">${providerSlotBusyCount}</span>`}
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
  const snapshotErrors = data.errors
  const ttlExpiredWarn = data.alert_summary.ttl_expired_keepers > 0
  const providerSlotBusyWarn = data.alert_summary.provider_slot_busy_keepers > 0
  const totalProviderSlotBusy = data.totals.provider_slot_busy

  return html`
    <div class="kmh-panel">
      <div class="kmh-header">
        <div class="kmh-title">키퍼 메모리 상태</div>
        <div class="kmh-totals-strip">
          <div class="kmh-stat" data-stat-key="facts">
            <span class="kmh-stat-label">전체 사실</span>
            <span class="kmh-stat-value">${data.totals.facts.toLocaleString()}</span>
          </div>
          <div class="kmh-stat" data-stat-key="facts-bytes">
            <span class="kmh-stat-label">사실 크기</span>
            <span class="kmh-stat-value">${formatBytes(data.totals.facts_bytes)}</span>
          </div>
          <div class="kmh-stat" data-stat-key="events-bytes">
            <span class="kmh-stat-label">이벤트 크기</span>
            <span class="kmh-stat-value">${formatBytes(data.totals.events_bytes)}</span>
          </div>
          <div class="kmh-stat" data-stat-key="ttl-expired">
            <span class="kmh-stat-label">TTL 만료(디스크)</span>
            <span class=${`kmh-stat-value${ttlExpiredWarn ? ' kmh-stat-value--warn' : ''}`}>
              ${data.totals.ttl_expired_on_disk}
            </span>
          </div>
          <div class="kmh-stat" data-stat-key="near-duplicate">
            <span class="kmh-stat-label">근접중복</span>
            <span class="kmh-stat-value">${data.totals.near_duplicate}</span>
          </div>
          <div class="kmh-stat" data-stat-key="provider-slot-busy">
            <span class="kmh-stat-label">슬롯 실패</span>
            <span class=${`kmh-stat-value${providerSlotBusyWarn ? ' kmh-stat-value--warn' : ''}`}>
              ${totalProviderSlotBusy}
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

      ${snapshotErrors.length > 0
        ? html`<p class="kmh-empty">일부 키퍼 메모리 상태를 읽지 못했습니다: ${snapshotErrors.map(error => `${error.keeper_id} (${error.message})`).join(', ')}</p>`
        : null}

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
                  <th>슬롯 실패</th>
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
