import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { EmptyState } from './common/feedback-state'
import { LoadingState } from './common/feedback-state'
import { Select } from './common/select'
import { TextInput } from './common/input'
import { StatTile } from './common/stat-tile'
import { isRecord } from './common/normalize'
import { StatusChip } from './common/status-chip'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { useSavedSignal } from '../lib/saved-signal'
import { MISSING_DATA_DASH } from '../lib/format-string'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { gateObservationErrorState } from '../lib/gate-observation-state'
import { get, type GetOptions } from '../api/core'
import { decodeKeeperApprovalQueueState } from '../api/dashboard-gate'
import type { KeeperApprovalQueueState } from '../types'

interface ToolRejection {
  tool: string
  reason: string
  count: number
}

/**
 * Pure filter for tool rejection rows.
 *
 * Case-insensitive substring match on `row.tool` and `row.reason`. The
 * `count` field is numeric so it is not part of the text search.
 *
 * Empty/whitespace query returns the input reference unchanged (no
 * new array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated.
 */
function filterToolRejections(
  rows: readonly ToolRejection[],
  query: string,
): readonly ToolRejection[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter(row => {
    if (row.tool.toLowerCase().includes(needle)) return true
    if (row.reason.toLowerCase().includes(needle)) return true
    return false
  })
}

interface ApprovalQueue {
  depth: number
  p50_wait_sec: number | null
  p95_wait_sec: number | null
  oldest_pending_sec: number | null
}

interface GateToolEvents {
  generated_at: string
  window_minutes: number
  tool_rejections: ToolRejection[]
  approval_queue_state: KeeperApprovalQueueState
  approval_queue: ApprovalQueue | null
}

function invalidGateToolEvents(detail: string): never {
  throw new Error(`invalid Gate tool-events payload: ${detail}`)
}

function queueNumber(raw: unknown, field: string): number {
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 0) {
    return invalidGateToolEvents(`approval_queue.${field} must be a non-negative number`)
  }
  return raw
}

function nullableQueueNumber(raw: unknown, field: string): number | null {
  return raw === null ? null : queueNumber(raw, field)
}

async function fetchGateToolEvents(
  windowMinutes = 60,
  opts?: GetOptions,
): Promise<GateToolEvents> {
  const raw = await get<Record<string, unknown>>(
    `/api/v1/dashboard/gate/tool-events?window=${windowMinutes}`,
    { signal: opts?.signal },
  )
  if (!isRecord(raw)) throw new Error('invalid Gate tool-events payload')
  const approvalQueueState = decodeKeeperApprovalQueueState(raw.approval_queue_state)
  if (!approvalQueueState) {
    return invalidGateToolEvents('approval_queue_state is not a current closed variant')
  }
  const rejections = Array.isArray(raw.tool_rejections)
    ? (raw.tool_rejections as unknown[]).filter(isRecord).map(r => ({
        tool: String(r.tool ?? ''),
        reason: String(r.reason ?? ''),
        count: Number(r.count ?? 0),
      }))
    : []
  if (approvalQueueState.state === 'unavailable') {
    if (raw.approval_queue !== null) {
      return invalidGateToolEvents('unavailable approval_queue must be null')
    }
    return {
      generated_at: String(raw.generated_at ?? ''),
      window_minutes: Number(raw.window_minutes ?? windowMinutes),
      tool_rejections: rejections,
      approval_queue_state: approvalQueueState,
      approval_queue: null,
    }
  }
  if (!isRecord(raw.approval_queue)) {
    return invalidGateToolEvents('ready approval_queue must be an object')
  }
  const q = raw.approval_queue
  const depth = queueNumber(q.depth, 'depth')
  if (!Number.isInteger(depth)) {
    return invalidGateToolEvents('approval_queue.depth must be an integer')
  }
  return {
    generated_at: String(raw.generated_at ?? ''),
    window_minutes: Number(raw.window_minutes ?? windowMinutes),
    tool_rejections: rejections,
    approval_queue_state: approvalQueueState,
    approval_queue: {
      depth,
      p50_wait_sec: nullableQueueNumber(q.p50_wait_sec, 'p50_wait_sec'),
      p95_wait_sec: nullableQueueNumber(q.p95_wait_sec, 'p95_wait_sec'),
      oldest_pending_sec: nullableQueueNumber(q.oldest_pending_sec, 'oldest_pending_sec'),
    },
  }
}

function fmtSec(value: number | null): string {
  if (value == null || Number.isNaN(value)) return MISSING_DATA_DASH
  if (value < 60) return `${value.toFixed(1)}s`
  return `${(value / 60).toFixed(1)}m`
}

export function GateMonitor() {
  const resource = useManagedAsyncResource<GateToolEvents>()
  const windowMinutes = useSignal(60)
  const [query] = useSavedSignal('dash:filter:gate-monitor:query', '')

  const load = () =>
    resource.load(async (signal) => fetchGateToolEvents(windowMinutes.value, { signal }))

  useEffect(() => {
    void load()
    const disposeAutoRefresh = setupVisibleAutoRefresh(() => void load(), TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
      resource.cancel()
    }
  }, [resource, windowMinutes.value])

  const current = resource.state.value
  const data = current.error ? null : current.data
  const approvalQueueState = current.error
    ? gateObservationErrorState(current.error)
    : data?.approval_queue_state ?? null
  const allRejections = data?.tool_rejections ?? []
  const visibleRejections = useMemo(
    () => filterToolRejections(allRejections, query.value),
    [allRejections, query.value],
  )
  const isFiltering = query.value.trim() !== ''

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <div class="v2-monitoring-toolbar flex items-center gap-3 flex-wrap">
        <${Select}
          class="px-2 py-1 text-xs"
          value=${String(windowMinutes.value)}
          ariaLabel="시간 윈도우 선택"
          options=${[
            { value: '30', label: '30m' },
            { value: '60', label: '60m' },
            { value: '180', label: '180m' },
            { value: '720', label: '12h' },
          ]}
          onInput=${(v: string) => { windowMinutes.value = Number(v) }}
        />
        <${ActionButton}
          variant="ghost"
          size="sm"
          ariaLabel="Gate 메트릭 새로고침"
          onClick=${() => void load()}
        >새로고침<//>
        <span class="text-xs text-[var(--color-fg-muted)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        ${current.loading ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>` : null}
      </div>

      ${current.loading && !data
        ? html`<${LoadingState}>Gate metrics 불러오는 중...<//>`
        : null}

      <${SectionCard} label="승인 대기열">
        ${data?.approval_queue ? html`
          <div class="grid grid-cols-4 gap-3">
            <${StatTile}
              label="대기열 깊이"
              value=${String(data.approval_queue.depth)}
            />
            <${StatTile}
              label="p50 Wait"
              value=${fmtSec(data.approval_queue.p50_wait_sec)}
            />
            <${StatTile}
              label="p95 대기"
              value=${fmtSec(data.approval_queue.p95_wait_sec)}
            />
            <div class="flex items-center gap-2">
              <${StatTile}
                label="최장 대기"
                value=${fmtSec(data.approval_queue.oldest_pending_sec)}
              />
              <${StatusChip}
                label=${data.approval_queue.depth === 0 ? '없음' : `${data.approval_queue.depth}건 대기`}
                tone="info"
              />
            </div>
          </div>
        ` : approvalQueueState && approvalQueueState.state !== 'ready' ? html`
          <div
            role="alert"
            data-severity=${approvalQueueState.severity}
            class="flex items-start gap-3 rounded-[var(--r-2)] border border-[var(--color-danger-border)] bg-[var(--color-danger-subtle)] p-3"
          >
            <span aria-hidden="true" class="font-bold text-[var(--color-danger-fg)]">${approvalQueueState.icon}</span>
            <div class="min-w-0">
              <div class="text-sm font-semibold text-[var(--color-danger-fg)]">${approvalQueueState.title}</div>
              <div class="mt-1 text-xs text-[var(--color-fg-secondary)]">${approvalQueueState.operator_detail}</div>
            </div>
          </div>
        ` : null}
      <//>

      <${SectionCard} label="도구 거부 (${data?.window_minutes ?? windowMinutes.value}m)">
        <div class="flex flex-col gap-2">
          <${TextInput}
            type="search"
            value=${query.value}
            placeholder="tool / reason 필터"
            ariaLabel="Tool rejection 필터"
            onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
            class="min-w-40 max-w-60 !bg-[var(--color-bg-page)] !px-2 !py-1 !text-xs"
          />
          ${allRejections.length === 0
            ? html`<${EmptyState} message="선택한 시간 범위에 tool rejection이 없습니다." compact />`
            : isFiltering && visibleRejections.length === 0
              ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-muted)]">필터 결과 없음 (${allRejections.length} items)</div>`
              : html`
                <div class="overflow-x-auto">
                  <table class="v2-monitoring-table w-full text-xs" aria-label="도구 거부 현황">
                    <thead>
                      <tr class="text-left text-[var(--color-fg-muted)] border-b border-[var(--color-border-default)]">
                        <th scope="col" class="py-1.5 pr-4 font-medium">도구</th>
                        <th scope="col" class="py-1.5 pr-4 font-medium">사유</th>
                        <th scope="col" class="py-1.5 font-medium text-right">횟수</th>
                      </tr>
                    </thead>
                    <tbody>
                      ${visibleRejections.map(r => html`
                        <tr class="v2-monitoring-row border-b border-[var(--color-border-default)]/30 text-[var(--color-fg-primary)]">
                          <td class="py-1.5 pr-4 font-mono text-2xs">${r.tool}</td>
                          <td class="py-1.5 pr-4">
                            <span class="inline-flex items-center px-1.5 py-0.5 rounded-[var(--r-1)] text-3xs bg-[var(--color-bg-hover)]">${r.reason}</span>
                          </td>
                          <td class="py-1.5 text-right font-medium text-[var(--color-fg-secondary)]">${r.count}</td>
                        </tr>
                      `)}
                    </tbody>
                  </table>
                </div>
              `}
        </div>
      <//>
    </div>
  `
}
