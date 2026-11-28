/**
 * Host Disk Space & `.masc/` Store Pressure Telemetry Card.
 *
 * - Decodes `host_storage` / `disk_observation` (filesystem probe + ENOSPC observations)
 * - Threshold-colored capacity bar: ok (<80%), warn (80-90% or status=warning),
 *   bad (>=90% or status=degraded|error or ENOSPC > 0)
 * - Fetches `GET /api/v1/dashboard/runtime-observables` for sorted `.masc/` store size
 *   breakdown with mini proportion bars (default-collapsed when >5 rows)
 * - Preserves default-collapsed raw JSON disclosure (`sandbox-host-storage-toggle/body`)
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { decodeHostStorageObservables, type RuntimeObservablesStoreEntry } from '../../api/host-storage-observables'
import { currentSessionEpoch, isEpochCurrent, sessionEpoch } from '../../core/auth'
import { apiGet } from '../../core/transport'
import {
  classifyDiskPressure,
  decodeDiskObservation,
  isRecentEnospcObservation,
  type DiskPressureLevel,
  type HostDiskObservation,
} from '../../shell/shell-state'
import { formatUnixTs, type WorkspaceInspectPayload } from './types'
import './infra.css'

export interface HostStorageCardProps {
  readonly hostStorage: Record<string, unknown> | null
  readonly onInspect?: (payload: WorkspaceInspectPayload) => void
  readonly fetchObservables?: boolean
}

const GIB = 1024 * 1024 * 1024
const MIB = 1024 * 1024
const KIB = 1024

export function formatBinaryBytes(bytes: number | null | undefined): string {
  if (typeof bytes !== 'number' || !Number.isFinite(bytes) || bytes < 0) return '미보고'
  if (bytes >= GIB) return `${(bytes / GIB).toFixed(1)} GiB`
  if (bytes >= MIB) return `${(bytes / MIB).toFixed(1)} MiB`
  if (bytes >= KIB) return `${(bytes / KIB).toFixed(1)} KiB`
  return `${Math.round(bytes)} B`
}

export function formatGiB(bytes: number | null | undefined): string {
  if (typeof bytes !== 'number' || !Number.isFinite(bytes) || bytes < 0) return '미보고'
  return `${(bytes / GIB).toFixed(1)} GiB`
}

function summarizeRawMetrics(raw: Record<string, unknown> | null): string {
  if (!raw) return '미보고'
  const pairs: string[] = []
  const collect = (obj: Record<string, unknown>, depth: number) => {
    for (const [k, v] of Object.entries(obj)) {
      if (typeof v === 'number' && Number.isFinite(v)) {
        pairs.push(`${k}: ${Number.isInteger(v) ? String(v) : v.toFixed(1)}`)
      } else if (typeof v === 'boolean') {
        pairs.push(`${k}: ${v ? 'true' : 'false'}`)
      } else if (typeof v === 'string' && v.trim()) {
        const t = v.trim()
        pairs.push(`${k}: ${t.length > 28 ? `${t.slice(0, 27)}…` : t}`)
      } else if (depth === 0 && v && typeof v === 'object' && !Array.isArray(v)) {
        collect(v as Record<string, unknown>, 1)
      }
    }
  }
  collect(raw, 0)
  if (pairs.length === 0) {
    const n = Object.keys(raw).length
    return n > 0 ? `${n}개 항목` : '비어 있음'
  }
  const head = pairs.slice(0, 3).join(' · ')
  return pairs.length > 3 ? `${head} (+${pairs.length - 3})` : head
}

function pressureTone(level: DiskPressureLevel, hasData: boolean): 'ok' | 'warn' | 'bad' | 'muted' {
  if (!hasData) return 'muted'
  switch (level) {
    case 'ok':
      return 'ok'
    case 'warning':
    case 'unavailable':
      return 'warn'
    case 'critical':
    case 'exhausted':
      return 'bad'
  }
}

function pressureBadgeLabel(level: DiskPressureLevel, hasData: boolean): string {
  if (!hasData) return '미보고'
  switch (level) {
    case 'ok':
      return '정상'
    case 'warning':
      return '주의'
    case 'critical':
      return '위험'
    case 'exhausted':
      return 'ENOSPC'
    case 'unavailable':
      return '조회 오류'
  }
}

type StoresLoadState =
  | { readonly kind: 'idle' }
  | { readonly kind: 'loading' }
  | { readonly kind: 'ready'; readonly stores: readonly RuntimeObservablesStoreEntry[]; readonly ageSeconds: number | null }
  | { readonly kind: 'unavailable'; readonly reason: string }

export function HostStorageCard(props: HostStorageCardProps) {
  const { hostStorage, onInspect, fetchObservables = true } = props
  const epoch = sessionEpoch.value
  const decoded: HostDiskObservation | null = useMemo(
    () => decodeDiskObservation(hostStorage),
    [hostStorage],
  )
  const pressure = useMemo(() => classifyDiskPressure(decoded), [decoded])
  const hasStructuredFs = decoded?.filesystem != null
  const tone = pressureTone(pressure.level, decoded !== null)

  const [rawOpen, setRawOpen] = useState(false)
  const [storesOpenPref, setStoresOpenPref] = useState<boolean | null>(null)
  const [storesState, setStoresState] = useState<StoresLoadState>({ kind: 'idle' })
  const abortRef = useRef<AbortController | null>(null)

  const loadStores = useCallback(async () => {
    if (!fetchObservables) return
    abortRef.current?.abort()
    const ctrl = new AbortController()
    abortRef.current = ctrl
    const startEpoch = currentSessionEpoch()
    setStoresState({ kind: 'loading' })
    const res = await apiGet<unknown>('/api/v1/dashboard/runtime-observables', { signal: ctrl.signal })
    if (ctrl.signal.aborted || !isEpochCurrent(startEpoch)) return
    if (!res.ok) {
      setStoresState({ kind: 'unavailable', reason: res.error.message })
      return
    }
    const parsed = decodeHostStorageObservables(res.value)
    if (!parsed) {
      setStoresState({ kind: 'unavailable', reason: 'runtime-observables 미보고' })
      return
    }
    const sorted = [...parsed.stores].sort((a, b) => b.bytes - a.bytes)
    setStoresState({ kind: 'ready', stores: sorted, ageSeconds: parsed.age_seconds })
  }, [fetchObservables])

  useEffect(() => {
    if (!fetchObservables) return
    void loadStores()
    return () => {
      abortRef.current?.abort()
      abortRef.current = null
    }
  }, [epoch, fetchObservables, loadStores])

  const fs = decoded?.filesystem ?? null
  const capacityPct = fs?.capacityPercent ?? null
  const clampedPct = capacityPct !== null ? Math.max(0, Math.min(100, capacityPct)) : null
  const exhaustionTotal = decoded?.exhaustionTotal ?? 0
  const recentEnospc = isRecentEnospcObservation(decoded)

  const storesList = storesState.kind === 'ready' ? storesState.stores : []
  const totalStoreBytes = useMemo(
    () => storesList.reduce((acc, s) => acc + Math.max(0, s.bytes), 0),
    [storesList],
  )
  const storesExpanded = storesOpenPref ?? (storesList.length > 0 && storesList.length <= 5)

  return html`
    <section class="hst-card" data-testid="sandbox-host-storage" aria-label="호스트 스토리지">
      <div class="hst-head">
        <div class="hst-head-title">
          <h3>호스트 스토리지</h3>
          <span class="hst-badge" data-tone=${tone} data-testid="host-storage-status-badge">
            ${pressureBadgeLabel(pressure.level, decoded !== null)}
          </span>
          ${decoded?.mode && html`<span class="hst-meta mono">${decoded.mode}</span>`}
        </div>
        <div class="hst-head-actions">
          ${fetchObservables && html`
            <button
              type="button"
              class="btn-ghost hst-btn-sm"
              disabled=${storesState.kind === 'loading'}
              onClick=${() => void loadStores()}
            >
              저장소 새로고침
            </button>
          `}
          ${onInspect && html`
            <button
              type="button"
              class="btn-ghost hst-btn-sm"
              onClick=${() => onInspect({
                title: 'Host Storage',
                kind: 'host_storage',
                data: hostStorage,
                render: () => html`<pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>${JSON.stringify(hostStorage, null, 2)}</pre>`,
              })}
            >
              [⤢] 원본
            </button>
          `}
        </div>
      </div>

      ${exhaustionTotal > 0 && recentEnospc && html`
        <div class="hst-enospc-alert" role="alert" data-testid="host-storage-enospc-alert">
          <strong>ENOSPC 공간 부족 관측 (<span class="tnum">${exhaustionTotal}</span>건)</strong>
          ${decoded?.lastExhaustionTs != null && html`
            <span class="mono"> · 마지막 관측: ${formatUnixTs(decoded.lastExhaustionTs)}</span>
          `}
        </div>
      `}

      ${exhaustionTotal > 0 && !recentEnospc && html`
        <div class="hst-reasons" role="note" data-testid="host-storage-enospc-history">
          과거 ENOSPC 관측 이력 (<span class="tnum">${exhaustionTotal}</span>건)
          ${decoded?.lastExhaustionTs != null && html`
            <span class="mono"> · 마지막 관측: ${formatUnixTs(decoded.lastExhaustionTs)}</span>
          `}
        </div>
      `}

      ${decoded && decoded.statusReasons.length > 0 && html`
        <div class="hst-reasons" role="status">
          ${decoded.statusReasons.join(' · ')}
        </div>
      `}

      ${fs?.error
        ? html`
            <div class="hst-fs-error" role="status" data-testid="host-storage-fs-error">
              파일시스템 프로브 오류: <span class="mono">${fs.error}</span>
            </div>
          `
        : hasStructuredFs && fs
          ? html`
              <div class="hst-capacity-block" data-testid="host-storage-capacity">
                <div class="hst-capacity-top">
                  <span class="hst-capacity-primary tnum">
                    ${formatGiB(fs.availableBytes)} 사용 가능 / ${formatGiB(fs.totalBytes)} 전체
                  </span>
                  <span class="hst-capacity-pct tnum" data-tone=${tone}>
                    사용률 ${capacityPct !== null ? `${capacityPct.toFixed(1)}%` : '미보고'}
                  </span>
                </div>
                <div
                  class="hst-bar-track"
                  role="progressbar"
                  aria-label="호스트 디스크 사용률"
                  aria-valuemin=${0}
                  aria-valuemax=${100}
                  aria-valuenow=${clampedPct !== null ? Math.round(clampedPct) : 0}
                >
                  <div
                    class="hst-bar-fill"
                    data-tone=${tone}
                    style=${{ width: `${clampedPct ?? 0}%` }}
                  />
                </div>
                <div class="hst-fs-meta mono">
                  ${fs.mountedOn && html`<span>mount: ${fs.mountedOn}</span>`}
                  ${fs.filesystem && html`<span>fs: ${fs.filesystem}</span>`}
                  ${(fs.path ?? decoded?.mascRoot) && html`<span>path: ${fs.path ?? decoded?.mascRoot}</span>`}
                </div>
              </div>
            `
          : html`
              <div class="hst-empty">
                ${hostStorage
                  ? `구조화된 파일시스템 텔레메트리 없음 (${summarizeRawMetrics(hostStorage)})`
                  : '호스트 스토리지 정보 미보고'}
              </div>
            `}

      <!-- .masc/ Store Size Breakdown -->
      ${fetchObservables && html`
        <div class="hst-stores" data-testid="host-storage-masc-stores">
          <button
            type="button"
            class="ap-disclosure-trigger hst-stores-trigger"
            data-testid="host-storage-stores-toggle"
            aria-expanded=${storesExpanded}
            onClick=${() => setStoresOpenPref(!storesExpanded)}
          >
            <span class="hst-stores-summary">
              <span>.masc/ 저장소 사용량</span>
              <span class="mono tnum hst-meta">
                ${storesState.kind === 'loading'
                  ? '불러오는 중…'
                  : storesState.kind === 'ready'
                    ? `${formatBinaryBytes(totalStoreBytes)} · ${storesList.length}개 스토어`
                    : storesState.kind === 'unavailable'
                      ? storesState.reason
                      : '대기 중'}
              </span>
            </span>
            <span aria-hidden="true">${storesExpanded ? '▾' : '▸'}</span>
          </button>

          ${storesExpanded && html`
            <div class="hst-stores-body" data-testid="host-storage-stores-body">
              ${storesState.kind === 'ready' && storesList.length > 0
                ? html`
                    <table class="hst-store-table">
                      <thead>
                        <tr>
                          <th>스토어</th>
                          <th class="hst-num">크기</th>
                          <th class="hst-num">파일</th>
                          <th>비중</th>
                        </tr>
                      </thead>
                      <tbody>
                        ${storesList.map((entry) => {
                          const share = totalStoreBytes > 0
                            ? Math.max(0, Math.min(100, (entry.bytes / totalStoreBytes) * 100))
                            : 0
                          return html`
                            <tr key=${entry.store}>
                              <td class="mono hst-store-name" title=${entry.store}>${entry.store}</td>
                              <td class="mono tnum hst-num">${formatBinaryBytes(entry.bytes)}</td>
                              <td class="mono tnum hst-num">${entry.files !== null ? entry.files.toLocaleString() : '—'}</td>
                              <td class="hst-store-bar-cell">
                                <div class="hst-store-bar-track">
                                  <div class="hst-store-bar-fill" style=${{ width: `${share.toFixed(1)}%` }} />
                                </div>
                                <span class="mono tnum hst-store-share">${share.toFixed(0)}%</span>
                              </td>
                            </tr>
                          `
                        })}
                      </tbody>
                    </table>
                  `
                : html`
                    <div class="hst-empty">
                      ${storesState.kind === 'loading'
                        ? '런타임 스토어 통계 수집 중…'
                        : storesState.kind === 'unavailable'
                          ? `스토어 통계를 불러오지 못했습니다 (${storesState.reason})`
                          : '기록된 .masc/ 스토어 항목 없음'}
                    </div>
                  `}
            </div>
          `}
        </div>
      `}

      <!-- Default-collapsed Raw JSON Disclosure -->
      <div class="ap-disclosure hst-raw-disclosure">
        <button
          type="button"
          class="ap-disclosure-trigger"
          data-testid="sandbox-host-storage-toggle"
          aria-expanded=${rawOpen}
          onClick=${() => setRawOpen((v) => !v)}
        >
          <span class="hst-raw-summary">
            <span>원시 JSON</span>
            <span class="mono tnum hst-meta">${summarizeRawMetrics(hostStorage)}</span>
          </span>
          <span aria-hidden="true">${rawOpen ? '▾' : '▸'}</span>
        </button>
        ${rawOpen && html`
          <div class="ap-disclosure-body" data-testid="sandbox-host-storage-body">
            <pre class="mono hst-raw-pre">${hostStorage ? JSON.stringify(hostStorage, null, 2) : '없음'}</pre>
          </div>
        `}
      </div>
    </section>
  `
}
