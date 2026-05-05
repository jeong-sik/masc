import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { ActionButton } from './common/button'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { Select } from './common/select'
import { TextInput } from './common/input'
import { StatTile } from './common/stat-tile'
import { StatusChip } from './common/status-chip'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { useSavedSignal } from '../lib/saved-signal'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { get, type GetOptions } from '../api/core'

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
          ariaLabel="governance 메트릭 새로고침"
          onClick=${() => void load()}
        >새로고침<//>
        <span class="text-xs text-[var(--color-fg-muted)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        ${current.loading ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>` : null}
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !data
        ? html`<${LoadingState}>governance metrics 불러오는 중...<//>`
        : null}

      <${Card} title="승인 대기열">
        ${data ? html`
          <div class="grid grid-cols-4 gap-3">
            <${StatTile}
              label="대기열 깊이"
              value=${String(data.approval_queue.depth)}
              status=${data.approval_queue.depth > 0 ? 'warn' : 'ok'}
              delta=${{ direction: data.approval_queue.depth > 0 ? 'flat' as const : 'up' as const, text: data.approval_queue.depth > 0 ? '승인 대기' : '비어있음' }}
            />
            <${StatTile}
              label="p50 Wait"
              value=${fmtSec(data.approval_queue.p50_wait_sec)}
            />
            <${StatTile}
              label="p95 대기"
              value=${fmtSec(data.approval_queue.p95_wait_sec)}
              status=${data.approval_queue.p95_wait_sec != null && data.approval_queue.p95_wait_sec > 300 ? 'warn' : undefined}
              delta=${data.approval_queue.p95_wait_sec != null && data.approval_queue.p95_wait_sec > 300 ? { direction: 'down' as const, text: '5분 초과' } : undefined}
            />
            <div class="flex items-center gap-2">
              <${StatTile}
                label="최장 대기"
                value=${fmtSec(data.approval_queue.oldest_pending_sec)}
                status=${data.approval_queue.oldest_pending_sec != null && data.approval_queue.oldest_pending_sec > 600 ? 'crit' : data.approval_queue.oldest_pending_sec != null && data.approval_queue.oldest_pending_sec > 300 ? 'warn' : undefined}
                delta=${data.approval_queue.oldest_pending_sec != null && data.approval_queue.oldest_pending_sec > 300 ? { direction: 'down' as const, text: '장기 대기' } : undefined}
              />
              <${StatusChip}
                label=${data.approval_queue.depth === 0 ? '없음' : `${data.approval_queue.depth}건 대기`}
                tone=${queueTone(data.approval_queue.depth, data.approval_queue.oldest_pending_sec)}
              />
            </div>
          </div>
        ` : null}
      <//>

      <${Card} title="도구 거부 (${data?.window_minutes ?? windowMinutes.value}m)">
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
                  <table class="w-full text-xs" aria-label="도구 거부 현황">
                    <thead>
                      <tr class="text-left text-[var(--color-fg-muted)] border-b border-[var(--color-border-default)]">
                        <th scope="col" class="py-1.5 pr-4 font-medium">도구</th>
                        <th scope="col" class="py-1.5 pr-4 font-medium">사유</th>
                        <th scope="col" class="py-1.5 font-medium text-right">횟수</th>
                      </tr>
                    </thead>
                    <tbody>
                      ${visibleRejections.map(r => html`
                        <tr class="border-b border-[var(--color-border-default)]/30 text-[var(--color-fg-primary)]">
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
