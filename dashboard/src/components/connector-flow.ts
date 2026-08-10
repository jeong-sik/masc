// ConnectorFlowSection — message-flow monitoring for a connector card.
//
// Everything rendered here was ALREADY fetched by the connector page
// (GET /api/v1/gate/status channels/bindings/recent_events + the
// connector's recent_audit) and silently dropped before render. This
// section surfaces it: inbound counts and success rate, per-keeper
// binding traffic, the latest gate events, and the binding-change
// audit trail. No new endpoint, no polling of its own.

import { html } from 'htm/preact'
import type {
  BindingInfo,
  ChannelInfo,
  DiscordAuditEntry,
  GateConnectorInfo,
  GateEventInfo,
  GateStatusData,
} from '../api/gate'
import { formatTimeAgoEn } from '../lib/format-time'
import { SurfaceCard } from './common/card'

const MAX_EVENT_ROWS = 5
const MAX_AUDIT_ROWS = 5

/** Pure: the aggregated channel stats for a connector. Prefers the
    connector's own observed_channel aggregation; falls back to the
    matching row in the gate status channel list. */
export function channelStatsFor(
  connector: GateConnectorInfo | null,
  gate: GateStatusData | null,
): ChannelInfo | null {
  if (connector?.observed_channel) return connector.observed_channel
  const channel = connector?.channel ?? ''
  if (!channel || !gate) return null
  return gate.channels.find(c => c.channel === channel) ?? null
}

/** Pure: per-keeper binding traffic rows for this connector's channel. */
export function bindingRowsFor(
  connector: GateConnectorInfo | null,
  gate: GateStatusData | null,
): BindingInfo[] {
  const channel = connector?.channel ?? ''
  if (!channel || !gate) return []
  return gate.bindings.filter(b => b.channel === channel)
}

/** Pure: latest gate events for this connector's channel, newest first. */
export function recentEventsFor(
  connector: GateConnectorInfo | null,
  gate: GateStatusData | null,
  limit = MAX_EVENT_ROWS,
): GateEventInfo[] {
  const channel = connector?.channel ?? ''
  if (!channel || !gate) return []
  return gate.recent_events
    .filter(e => e.channel === channel)
    .slice()
    .sort((a, b) => b.seq - a.seq)
    .slice(0, limit)
}

function outcomeTone(outcome: string): string {
  if (outcome === 'success') return 'text-emerald-400'
  if (outcome === 'duplicate') return 'text-[var(--color-fg-disabled)]'
  return 'text-[var(--color-status-warn)]'
}

function StatChip({ label, value }: { label: string; value: string }) {
  return html`
    <span class="inline-flex items-baseline gap-1 whitespace-nowrap">
      <span class="text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">${label}</span>
      <span class="font-mono text-2xs text-[var(--color-fg-primary)]">${value}</span>
    </span>
  `
}

export function ConnectorFlowSection({ connector, gate }: {
  connector: GateConnectorInfo | null
  gate: GateStatusData | null
}) {
  const stats = channelStatsFor(connector, gate)
  const bindingRows = bindingRowsFor(connector, gate)
  const events = recentEventsFor(connector, gate)
  const audit = (connector?.recent_audit ?? []).slice(0, MAX_AUDIT_ROWS)

  if (!stats && bindingRows.length === 0 && events.length === 0 && audit.length === 0) {
    return null
  }

  return html`
    <${SurfaceCard}
      class="mt-3 !bg-[var(--color-bg-elevated)] !px-3 !py-2.5 text-2xs v2-connector-flow"
      data-connector-flow=${connector?.connector_id ?? ''}
    >
      <div class="mb-1.5 text-3xs font-semibold uppercase tracking-4 text-[var(--color-fg-disabled)]">
        메시지 흐름
      </div>

      ${stats
        ? html`
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1" data-flow-stats>
              <${StatChip} label="in" value=${String(stats.message_count)} />
              <${StatChip} label="ok" value=${`${stats.success_count} (${stats.success_rate_pct}%)`} />
              <${StatChip} label="err" value=${String(stats.error_count)} />
              ${stats.avg_duration_ms > 0
                ? html`<${StatChip} label="avg" value=${`${Math.round(stats.avg_duration_ms)}ms`} />`
                : null}
              ${stats.last_activity
                ? html`<${StatChip} label="last" value=${formatTimeAgoEn(stats.last_activity)} />`
                : null}
            </div>
          `
        : html`
            <div class="text-[var(--color-fg-disabled)]" data-flow-empty>
              아직 게이트로 들어온 메시지가 없습니다.
            </div>
          `}

      ${bindingRows.length > 0
        ? html`
            <div class="mt-2 space-y-0.5" data-flow-bindings>
              ${bindingRows.map(row => html`
                <div class="flex flex-wrap items-center gap-x-2 text-2xs">
                  <span class="font-mono text-[var(--color-fg-primary)]">${row.keeper}</span>
                  <span class="text-[var(--color-fg-disabled)]">←</span>
                  <span class="font-mono text-3xs text-[var(--color-fg-disabled)]" title=${row.workspace_id}>
                    ${row.workspace_id}
                  </span>
                  <span class="text-3xs text-[var(--color-fg-disabled)]">
                    in ${row.message_count} · ok ${row.success_count} · err ${row.error_count}
                  </span>
                  ${row.last_activity
                    ? html`<span class="text-3xs text-[var(--color-fg-disabled)]">· ${formatTimeAgoEn(row.last_activity)}</span>`
                    : null}
                </div>
              `)}
            </div>
          `
        : null}

      ${events.length > 0
        ? html`
            <div class="mt-2" data-flow-events>
              <div class="text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">최근 이벤트</div>
              <div class="mt-0.5 space-y-0.5">
                ${events.map(ev => html`
                  <div class="flex flex-wrap items-center gap-x-2 font-mono text-3xs">
                    <span class="text-[var(--color-fg-disabled)]">${formatTimeAgoEn(ev.timestamp)}</span>
                    <span class="text-[var(--color-fg-primary)]">${ev.keeper}</span>
                    <span class=${outcomeTone(ev.outcome)}>${ev.outcome}</span>
                    ${ev.duration_ms > 0
                      ? html`<span class="text-[var(--color-fg-disabled)]">${Math.round(ev.duration_ms)}ms</span>`
                      : null}
                    ${ev.error
                      ? html`<span class="min-w-0 truncate text-[var(--color-status-warn)]" title=${ev.error}>${ev.error}</span>`
                      : null}
                  </div>
                `)}
              </div>
            </div>
          `
        : null}

      ${audit.length > 0
        ? html`
            <div class="mt-2" data-flow-audit>
              <div class="text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">바인딩 변경 이력</div>
              <div class="mt-0.5 space-y-0.5">
                ${audit.map((entry: DiscordAuditEntry) => html`
                  <div class="flex flex-wrap items-center gap-x-2 font-mono text-3xs">
                    <span class="text-[var(--color-fg-disabled)]">${formatTimeAgoEn(entry.timestamp)}</span>
                    <span class=${entry.action === 'unbind' ? 'text-[var(--color-status-warn)]' : 'text-emerald-400'}>
                      ${entry.action}
                    </span>
                    <span class="text-[var(--color-fg-disabled)]" title=${entry.channel_id}>${entry.channel_id}</span>
                    <span class="text-[var(--color-fg-disabled)]">→</span>
                    <span class="text-[var(--color-fg-primary)]">${entry.keeper_name}</span>
                    ${entry.previous_keeper
                      ? html`<span class="text-[var(--color-fg-disabled)]">(was ${entry.previous_keeper})</span>`
                      : null}
                  </div>
                `)}
              </div>
            </div>
          `
        : null}
    <//>
  `
}
