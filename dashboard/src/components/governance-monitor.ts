import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { StatCell } from './common/stat-cell'
import { StatusChip } from './common/status-chip'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { useSavedSignal } from '../lib/saved-signal'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { get, type GetOptions } from '../api/core'

export interface ToolRejection {
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
export function filterToolRejections(
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

interface GovernanceToolEvents {
  generated_at: string
  window_minutes: number
  tool_rejections: ToolRejection[]
  approval_queue: ApprovalQueue
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

async function fetchGovernanceToolEvents(
  windowMinutes = 60,
  opts?: GetOptions,
): Promise<GovernanceToolEvents> {
  const raw = await get<Record<string, unknown>>(
    `/api/v1/dashboard/governance/tool-events?window=${windowMinutes}`,
    { signal: opts?.signal },
  )
  if (!isRecord(raw)) throw new Error('invalid governance tool events payload')
  const rejections = Array.isArray(raw.tool_rejections)
    ? (raw.tool_rejections as unknown[]).filter(isRecord).map(r => ({
        tool: String(r.tool ?? ''),
        reason: String(r.reason ?? ''),
        count: Number(r.count ?? 0),
      }))
    : []
  const q = isRecord(raw.approval_queue) ? raw.approval_queue : {}
  return {
    generated_at: String(raw.generated_at ?? ''),
    window_minutes: Number(raw.window_minutes ?? windowMinutes),
    tool_rejections: rejections,
    approval_queue: {
      depth: Number(q.depth ?? 0),
      p50_wait_sec: typeof q.p50_wait_sec === 'number' ? q.p50_wait_sec : null,
      p95_wait_sec: typeof q.p95_wait_sec === 'number' ? q.p95_wait_sec : null,
      oldest_pending_sec: typeof q.oldest_pending_sec === 'number' ? q.oldest_pending_sec : null,
    },
  }
}

function fmtSec(value: number | null): string {
  if (value == null || Number.isNaN(value)) return '--'
  if (value < 60) return `${value.toFixed(1)}s`
  return `${(value / 60).toFixed(1)}m`
}

function queueTone(depth: number, oldest: number | null): string {
  if (depth === 0) return 'ok'
  if (oldest != null && oldest > 300) return 'bad'
  if (depth > 5) return 'warn'
  return 'ok'
}

export function GovernanceMonitor() {
  const resource = useManagedAsyncResource<GovernanceToolEvents>()
  const windowMinutes = useSignal(60)
  const [query] = useSavedSignal('dash:filter:governance-monitor:query', '')

  const load = () =>
    resource.load(async (signal) => fetchGovernanceToolEvents(windowMinutes.value, { signal }))

  useEffect(() => {
    void load()
    const disposeAutoRefresh = setupVisibleAutoRefresh(() => void load(), TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
      resource.cancel()
    }
  }, [resource, windowMinutes.value])

  const current = resource.state.value
  const data = current.data
  const allRejections = data?.tool_rejections ?? []
  const visibleRejections = useMemo(
    () => filterToolRejections(allRejections, query.value),
    [allRejections, query.value],
  )
  const isFiltering = query.value.trim() !== ''

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <select
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${String(windowMinutes.value)}
          onChange=${(e: Event) => { windowMinutes.value = Number((e.target as HTMLSelectElement).value) }}
        >
          <option value="30">30m</option>
          <option value="60">60m</option>
          <option value="180">180m</option>
          <option value="720">12h</option>
        </select>
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void load()}
        >새로고침</button>
        <span class="text-xs text-[var(--text-muted)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        ${current.loading ? html`<span class="text-xs text-[var(--text-muted)]">로딩 중...</span>` : null}
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !data
        ? html`<${LoadingState}>governance metrics 불러오는 중...<//>`
        : null}

      <${Card} title="Approval Queue">
        ${data ? html`
          <div class="grid grid-cols-4 gap-3">
            <${StatCell}
              label="Queue Depth"
              value=${data.approval_queue.depth}
            />
            <${StatCell}
              label="p50 Wait"
              value=${fmtSec(data.approval_queue.p50_wait_sec)}
            />
            <${StatCell}
              label="p95 Wait"
              value=${fmtSec(data.approval_queue.p95_wait_sec)}
            />
            <div class="flex items-center gap-2">
              <${StatCell}
                label="Oldest"
                value=${fmtSec(data.approval_queue.oldest_pending_sec)}
              />
              <${StatusChip}
                label=${data.approval_queue.depth === 0 ? 'clear' : `${data.approval_queue.depth} pending`}
                tone=${queueTone(data.approval_queue.depth, data.approval_queue.oldest_pending_sec)}
              />
            </div>
          </div>
        ` : null}
      <//>

      <${Card} title="Tool Rejections (${data?.window_minutes ?? windowMinutes.value}m)">
        <div class="flex flex-col gap-2">
          <input
            type="search"
            value=${query.value}
            placeholder="tool / reason 필터"
            aria-label="Tool rejection 필터"
            onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
            class="min-w-40 max-w-60 rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] placeholder:text-[var(--text-muted)] focus:outline-none focus:border-[var(--accent)]"
          />
          ${allRejections.length === 0
            ? html`<${EmptyState} message="선택한 시간 범위에 tool rejection이 없습니다." compact />`
            : isFiltering && visibleRejections.length === 0
              ? html`<div class="py-4 text-center text-2xs text-[var(--text-muted)]">필터 결과 없음 (${allRejections.length} items)</div>`
              : html`
                <div class="overflow-x-auto">
                  <table class="w-full text-xs">
                    <thead>
                      <tr class="text-left text-[var(--text-muted)] border-b border-[var(--card-border)]">
                        <th class="py-1.5 pr-4 font-medium">Tool</th>
                        <th class="py-1.5 pr-4 font-medium">Reason</th>
                        <th class="py-1.5 font-medium text-right">Count</th>
                      </tr>
                    </thead>
                    <tbody>
                      ${visibleRejections.map(r => html`
                        <tr class="border-b border-[var(--card-border)]/30 text-[var(--text-body)]">
                          <td class="py-1.5 pr-4 font-mono text-2xs">${r.tool}</td>
                          <td class="py-1.5 pr-4">
                            <span class="inline-flex items-center px-1.5 py-0.5 rounded text-3xs bg-[var(--bg-panel-hover)]">${r.reason}</span>
                          </td>
                          <td class="py-1.5 text-right font-medium text-[var(--text-strong)]">${r.count}</td>
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
