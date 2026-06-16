// Keeper Workspace — rich recent-tool-calls section for the context rail.
//
// The rail previously rendered keeper.recent_tool_names (a flat string[] from
// the keeper snapshot) with a hardcoded "ok" dot — no status, duration, age, or
// args/result. The richer per-call data already exists server-side: the durable
// tool-call store is served by GET /api/v1/keepers/:name/tool-calls and decoded
// by fetchKeeperToolCalls -> ToolCallEntry. This section lazy-loads that for the
// selected keeper (one fetch per selection, refreshed on tool-activity SSE) and
// renders compact rows with a real success/failure dot, duration, relative age,
// and click-to-expand input/output. No backend change — pure consumption.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useCallback, useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchKeeperToolCalls } from '../../api/dashboard'
import type { ToolCallEntry, ToolCallsResponse } from '../../api/dashboard'
import { useManagedAsyncResource } from '../../lib/use-managed-async-resource'
import { lastEvent } from '../../sse'
import { isKeeperToolActivityEvent, sseEventMatchesKeeper } from '../keeper-sse-match'
import { formatMsCompact } from '../../lib/format-number'
import { formatTimeAgo } from '../../lib/format-time'
import { formatInput, formatOutput } from '../keeper-tool-call-inspector'
import { StatusDot } from './keeper-workspace-shared'

// Match the v2 rails RecentTool list length — a short tail, not full history.
const RECENT_LIMIT = 10

/** Stable identity for a tool-call row (ts + tool + turn disambiguates retries
 *  within the same second). */
export function toolCallRowKey(entry: ToolCallEntry): string {
  return `${entry.ts}-${entry.tool}-${entry.turn ?? ''}`
}

/** Pure presentational list — newest first. Separated from the data loader so it
 *  can be tested without mocking fetch/SSE. */
export function RecentToolList({
  entries,
  expandedKey,
  onToggle,
}: {
  entries: ToolCallEntry[]
  expandedKey: string | null
  onToggle: (key: string) => void
}): VNode {
  return html`
    <div class="kw-list">
      ${entries.map((e) => {
        const key = toolCallRowKey(e)
        const open = expandedKey === key
        const tone = e.success ? 'ok' : 'bad'
        return html`
          <div class=${`kw-toolcall${open ? ' open' : ''}`} key=${key}>
            <button
              type="button"
              class="kw-toolcall-head"
              aria-expanded=${open ? 'true' : 'false'}
              onClick=${() => onToggle(key)}
            >
              <${StatusDot} tone=${tone} pulse=${false} />
              <span class="nm" title=${e.tool}>${e.tool}</span>
              <span class="dur" title="지속시간">${formatMsCompact(e.duration_ms)}</span>
              <span class="age" title="경과">${formatTimeAgo(e.ts)}</span>
            </button>
            ${open
              ? html`
                  <div class="kw-toolcall-body">
                    <div class="kw-tc-block">
                      <div class="kw-tc-lbl">입력</div>
                      <pre>${formatInput(e.input)}</pre>
                    </div>
                    <div class="kw-tc-block">
                      <div class="kw-tc-lbl">출력</div>
                      <pre>${formatOutput(e.output)}</pre>
                    </div>
                  </div>
                `
              : null}
          </div>
        `
      })}
    </div>
  `
}

/** Data loader + section wrapper. Returns null while empty so the section stays
 *  hidden until the keeper has tool-call history (matches the old behavior of
 *  omitting the section when there were no recent tool names). */
export function KeeperWorkspaceRecentTools({ keeperName }: { keeperName: string }): VNode | null {
  const resource = useManagedAsyncResource<ToolCallsResponse | null>(null)
  const expandedKey = useSignal<string | null>(null)

  const load = useCallback(
    (signal: AbortSignal) => fetchKeeperToolCalls(keeperName, RECENT_LIMIT, { signal }),
    [keeperName],
  )

  // External-system sync: load on keeper change, cancel in-flight on unmount.
  useEffect(() => {
    void resource.load(load)
    return () => {
      resource.cancel()
    }
  }, [load, resource])

  // Refresh when this keeper emits a tool-activity event (same trigger the full
  // inspector uses), so the rail stays current without polling.
  useEffect(() => {
    const unsubscribe = lastEvent.subscribe((event) => {
      if (!event) return
      if (!isKeeperToolActivityEvent(event)) return
      if (!sseEventMatchesKeeper(event, keeperName)) return
      void resource.load(load)
    })
    return () => {
      unsubscribe()
    }
  }, [keeperName, load, resource])

  const entries = (resource.state.value.data?.entries ?? []).slice(-RECENT_LIMIT).reverse()
  if (entries.length === 0) return null

  return html`
    <div class="kw-sec">
      <h4>최근 도구 호출</h4>
      <${RecentToolList}
        entries=${entries}
        expandedKey=${expandedKey.value}
        onToggle=${(key: string) => {
          expandedKey.value = expandedKey.value === key ? null : key
        }}
      />
    </div>
  `
}
