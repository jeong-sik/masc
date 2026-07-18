// Keeper Reactivity Monitor — lifecycle and operator-pause observability.
//
// Implements four data views:
//   1. Health Grid     — compact grid: phase, pause status, last activity
//   2. Lifecycle       — transition timeline (delegates to KeeperPhaseTimeline)
//   3. Events          — supervisor lifecycle events
//   4. Paused Keepers  — keepers in operator-controlled paused phase

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { keepers, shellRuntimeResolution } from '../store'
import { navigate } from '../router'
import { KeeperPhaseBadge, pipelineStageDetailLabel } from './keeper-phase-indicator'
import { KeeperPhaseTimeline, refreshKeeperPhaseTimeline } from './keeper-phase-strip'
import { KeeperLifecycleTimeline, refreshKeeperLifecycleTimeline } from './keeper-lifecycle-timeline'
import { isKeeperCrashed, isKeeperPaused } from '../lib/keeper-predicates'
import { TimeAgo } from './common/time-ago'
import { EmptyState } from './common/feedback-state'
import { FilterChips } from './common/filter-chips'
import type {
  DashboardKeeperReactionLedgerHealth,
  DashboardKeeperReactionLedgerKeeperHealth,
  Keeper,
} from '../types'

// ── Sub-component helpers ──────────────────────────────────────────────────

/** Paused state is projected through the canonical Keeper predicate.
 *
 * Three fields must be checked because they come from different serialisation
 * paths: `paused` is the legacy boolean from the keeper registry; `phase` is
 * the FSM-derived lifecycle phase from the composite observer; `pipeline_stage`
 * is the activity stage from the heartbeat path.  They are ordinarily in sync,
 * but during lifecycle propagation they can briefly disagree. The OR ensures that any
 * signal of pause is reflected in the UI immediately, matching operator intent.
 */
// RFC-0135 PR-3: `isKeeperPaused` lives in the canonical SSOT
// `../lib/keeper-predicates.ts`. The old definition here checked only
// three axes (paused, phase, pipeline_stage); the SSOT folds in the
// `status` axis too and is reused by all four pre-RFC sites.

// ── Sub-components ─────────────────────────────────────────────────────────

function PhaseDot({ phase }: { phase: string | null | undefined }) {
  return html`<${KeeperPhaseBadge} phase=${phase} compact />`
}

/** Health Grid — compact per-keeper status table. */
function HealthGrid({ allKeepers }: { allKeepers: Keeper[] }) {
  if (allKeepers.length === 0) {
    return html`<${EmptyState} message="등록된 키퍼 없음" />`
  }

  return html`
    <div class="overflow-x-auto" role="region" aria-label="키퍼 상태 그리드">
      <table class="v2-monitoring-table w-full text-xs" aria-label="키퍼 상태">
        <thead>
          <tr class="border-b border-[var(--color-border-default)] text-left text-[var(--color-fg-muted)]">
            <th scope="col" class="pb-2 pr-3 font-normal">키퍼</th>
            <th scope="col" class="pb-2 pr-3 font-normal">단계</th>
            <th scope="col" class="pb-2 pr-3 font-normal">활동</th>
            <th scope="col" class="pb-2 pr-3 font-normal">마지막 활동</th>
            <th scope="col" class="pb-2 pr-3 font-normal text-right">회전 수</th>
          </tr>
        </thead>
        <tbody>
          ${allKeepers.map(k => {
            const lastActivityMs = k.last_activity_ago_s != null
              ? Date.now() - k.last_activity_ago_s * 1000
              : null
            const isPaused = isKeeperPaused(k)
            const isCrashed = isKeeperCrashed(k)

            return html`
              <tr
                key=${k.name}
                class="v2-monitoring-row group border-b border-[var(--color-border-default)]/40 hover:bg-[var(--color-bg-surface)]"
              >
                <td class="py-2 pr-3 font-medium">
                  <button
                    class="v2-monitoring-action flex items-center gap-1 text-left text-[var(--color-fg-secondary)] group-hover:text-[var(--color-fg-primary)] hover:underline"
                    onClick=${() => navigate('monitoring', { section: 'agents', keeper: k.name })}
                    aria-label="${k.name} 상세 보기"
                  >
                    ${k.emoji ? html`<span class="mr-1" aria-hidden="true">${k.emoji}</span>` : null}
                    <span class="font-mono text-2xs">${k.name}</span>
                  </button>
                </td>
                <td class="py-2 pr-3">
                  <${PhaseDot} phase=${k.lifecycle_phase ?? k.phase} />
                  ${isPaused ? html`
                    <span class="ml-1.5 inline-flex items-center text-3xs text-[var(--paused)] font-semibold">⏸ 일시정지</span>
                  ` : null}
                </td>
                <td
                  class="py-2 pr-3 text-[var(--color-fg-muted)] capitalize"
                  title=${k.pipeline_stage_detail ? `${k.pipeline_stage ?? 'unknown'} · ${pipelineStageDetailLabel(k.pipeline_stage_detail)} · ${k.pipeline_stage_detail}` : undefined}
                >
                  <span>${k.pipeline_stage ?? '—'}</span>
                  ${k.pipeline_stage === 'offline' && k.pipeline_stage_detail ? html`
                    <span class="ml-1.5 text-3xs opacity-70">${pipelineStageDetailLabel(k.pipeline_stage_detail)}</span>
                  ` : null}
                </td>
                <td class="py-2 pr-3 text-[var(--color-fg-muted)] tabular-nums whitespace-nowrap">
                  ${lastActivityMs
                    ? html`<${TimeAgo} timestamp=${lastActivityMs} />`
                    : html`<span class="text-[var(--color-fg-disabled)]">—</span>`
                  }
                </td>
                <td class="py-2 text-right tabular-nums ${isCrashed ? 'text-[var(--bad-light)]' : 'text-[var(--color-fg-muted)]'}">
                  ${k.total_turns ?? k.turn_count ?? '—'}
                </td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

function LedgerCount({ value }: { value: number | null }) {
  return value == null
    ? html`<span class="text-[var(--color-fg-disabled)]">알 수 없음</span>`
    : html`<span class="tabular-nums">${value.toLocaleString()}</span>`
}

function LedgerMetric({
  label,
  value,
}: {
  label: string
  value: number | null
}) {
  return html`
    <div class="v2-monitoring-card rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
      <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-muted)]">${label}</div>
      <div class="mt-1 text-sm font-semibold text-[var(--color-fg-secondary)]">
        <${LedgerCount} value=${value} />
      </div>
    </div>
  `
}

function KeeperLedgerStatus({ keeper }: { keeper: DashboardKeeperReactionLedgerKeeperHealth }) {
  const latestRecordedAtMs = keeper.latest_recorded_at_unix == null
    ? null
    : keeper.latest_recorded_at_unix * 1000

  return html`
    <tr
      key=${keeper.keeper_name}
      class="v2-monitoring-row border-b border-[var(--color-border-default)]/40 align-top"
      data-keeper-reaction-ledger-row=${keeper.keeper_name}
    >
      <td class="py-2 pr-3">
        <div class="font-mono text-2xs font-semibold text-[var(--color-fg-secondary)]">${keeper.keeper_name}</div>
        <div class="mt-1 text-3xs text-[var(--color-fg-muted)]">
          상태 ${keeper.status ?? '알 수 없음'} · 집계 ${keeper.counts_complete === true ? '완전' : keeper.counts_complete === false ? '불완전' : '알 수 없음'}
        </div>
        <details class="mt-1 text-3xs text-[var(--color-fg-muted)]">
          <summary class="cursor-pointer">durable event 집계</summary>
          <dl class="mt-1 grid grid-cols-[max-content_1fr] gap-x-2 gap-y-0.5">
            <dt>schema</dt><dd class="break-all">${keeper.schema ?? '알 수 없음'}</dd>
            <dt>operator action</dt><dd>${keeper.operator_action_required == null ? '알 수 없음' : keeper.operator_action_required ? '필요' : '불필요'}</dd>
            <dt>pending ID limit</dt><dd><${LedgerCount} value=${keeper.pending_id_display_limit} /></dd>
            <dt>rows</dt><dd><${LedgerCount} value=${keeper.row_count} /></dd>
            <dt>stimuli</dt><dd><${LedgerCount} value=${keeper.stimulus_count} /></dd>
            <dt>reactions</dt><dd><${LedgerCount} value=${keeper.reaction_count} /></dd>
            <dt>turn started</dt><dd><${LedgerCount} value=${keeper.turn_started_count} /></dd>
            <dt>queue ACK</dt><dd><${LedgerCount} value=${keeper.event_queue_ack_count} /></dd>
            <dt>queue requeue</dt><dd><${LedgerCount} value=${keeper.event_queue_requeue_count} /></dd>
            <dt>queue escalation</dt><dd><${LedgerCount} value=${keeper.event_queue_escalation_count} /></dd>
            <dt>queue external input</dt><dd><${LedgerCount} value=${keeper.event_queue_external_input_count} /></dd>
          </dl>
        </details>
        ${keeper.read_error ? html`
          <div class="mt-1 break-all text-3xs text-[var(--color-status-bad)]" role="alert">
            읽기 오류: ${keeper.read_error}
          </div>
        ` : null}
      </td>
      <td class="py-2 pr-3"><${LedgerCount} value=${keeper.pending_stimulus_count} /></td>
      <td class="py-2 pr-3"><${LedgerCount} value=${keeper.in_progress_stimulus_count} /></td>
      <td class="py-2 pr-3"><${LedgerCount} value=${keeper.acked_stimulus_count} /></td>
      <td class="py-2 pr-3"><${LedgerCount} value=${keeper.escalated_stimulus_count} /></td>
      <td class="py-2 pr-3"><${LedgerCount} value=${keeper.external_input_requested_stimulus_count} /></td>
      <td class="py-2 pr-3"><${LedgerCount} value=${keeper.orphan_reaction_stimulus_count} /></td>
      <td class="py-2 pr-3">
        <div><${LedgerCount} value=${keeper.cursor_ack_count} /> ACK</div>
        <div class="mt-0.5 text-3xs text-[var(--color-fg-muted)]">
          <${LedgerCount} value=${keeper.cursor_swept_stimulus_count} /> swept
        </div>
      </td>
      <td class="py-2 min-w-56">
        ${keeper.latest_stimulus_id ? html`
          <code class="block break-all text-3xs text-[var(--color-fg-secondary)]" title=${keeper.latest_stimulus_id}>
            ${keeper.latest_stimulus_id}
          </code>
        ` : html`<span class="text-[var(--color-fg-disabled)]">식별자 없음</span>`}
        <div class="mt-1 text-3xs text-[var(--color-fg-muted)]">
          ${latestRecordedAtMs == null
            ? '기록 시각 알 수 없음'
            : html`마지막 기록 <${TimeAgo} timestamp=${latestRecordedAtMs} />`}
        </div>
        ${keeper.pending_stimulus_ids.length > 0 ? html`
          <div class="mt-2" data-keeper-pending-stimulus-ids=${keeper.keeper_name}>
            <div class="text-3xs text-[var(--color-fg-muted)]">
              pending ID${keeper.pending_ids_truncated === true ? ' (일부)' : ''}
            </div>
            ${keeper.pending_stimulus_ids.map(stimulusId => html`
              <code key=${stimulusId} class="mt-0.5 block break-all text-3xs text-[var(--color-status-warn)]">${stimulusId}</code>
            `)}
          </div>
        ` : keeper.pending_stimulus_count != null && keeper.pending_stimulus_count > 0 ? html`
          <div class="mt-2 text-3xs text-[var(--color-fg-muted)]">
            pending ID 관측 미포함 · limit ${keeper.pending_id_display_limit ?? '알 수 없음'}
          </div>
        ` : null}
      </td>
    </tr>
  `
}

/** Durable reaction-ledger projection from the runtime health SSOT. */
export function ReactionLedgerPanel({
  ledger,
}: {
  ledger: DashboardKeeperReactionLedgerHealth | null
}) {
  if (ledger == null) {
    return html`
      <div
        class="rounded border border-[var(--warn-20)] bg-[var(--warn-10)] px-4 py-3 text-xs text-[var(--color-status-warn)]"
        data-keeper-reaction-ledger-unavailable
        role="status"
      >
        반응 ledger 관측값을 사용할 수 없습니다. 런타임 health 응답과 source 상태를 확인하세요.
      </div>
    `
  }

  const observationIncomplete = ledger.counts_complete !== true
  const hasDiscoveryErrors =
    ledger.keeper_name_discovery_errors.length > 0
    || ledger.reaction_store_discovery_errors.length > 0
  const hasReadErrors = ledger.keepers.some(keeper => keeper.read_error != null)
  const requiresAttention =
    ledger.operator_action_required === true
    || observationIncomplete
    || hasDiscoveryErrors
    || hasReadErrors

  return html`
    <section
      class="v2-monitoring-surface flex flex-col gap-3"
      aria-label="Keeper reaction ledger"
      data-keeper-reaction-ledger-status=${ledger.status ?? 'unknown'}
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h4 class="text-xs font-semibold text-[var(--color-fg-secondary)]">Durable reaction ledger</h4>
          <div class="mt-0.5 text-3xs text-[var(--color-fg-muted)]">
            schema ${ledger.schema ?? '알 수 없음'} · keeper ${ledger.keeper_count == null ? '알 수 없음' : ledger.keeper_count.toLocaleString()}
          </div>
        </div>
        <div class=${`rounded px-2 py-1 text-2xs font-semibold ${requiresAttention ? 'bg-[var(--warn-10)] text-[var(--color-status-warn)]' : 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'}`}>
          ${ledger.status ?? '상태 알 수 없음'} · 집계 ${ledger.counts_complete === true ? '완전' : ledger.counts_complete === false ? '불완전' : '알 수 없음'}
        </div>
      </div>

      ${ledger.status_reasons.length > 0 ? html`
        <div class="rounded border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]" role="status">
          ${ledger.status_reasons.map(reason => html`<div key=${reason} class="break-all">${reason}</div>`)}
        </div>
      ` : null}

      ${observationIncomplete ? html`
        <div class="rounded border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]" role="status">
          집계 완전성이 ${ledger.counts_complete === false ? '보장되지 않습니다' : '관측되지 않았습니다'}. 아래의 알 수 없음 값을 0으로 해석하지 마세요.
        </div>
      ` : null}

      <div>
        <div class="mb-2 text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">인과 상태</div>
        <div class="grid grid-cols-2 gap-2 md:grid-cols-3 xl:grid-cols-6">
          <${LedgerMetric} label="pending" value=${ledger.pending_stimulus_count} />
          <${LedgerMetric} label="in progress" value=${ledger.in_progress_stimulus_count} />
          <${LedgerMetric} label="acked" value=${ledger.acked_stimulus_count} />
          <${LedgerMetric} label="escalated" value=${ledger.escalated_stimulus_count} />
          <${LedgerMetric} label="external input" value=${ledger.external_input_requested_stimulus_count} />
          <${LedgerMetric} label="orphan reaction" value=${ledger.orphan_reaction_stimulus_count} />
        </div>
      </div>

      <div>
        <div class="mb-2 text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">Durable event projection</div>
        <div class="grid grid-cols-2 gap-2 md:grid-cols-4 xl:grid-cols-6">
          <${LedgerMetric} label="stimuli" value=${ledger.stimulus_count} />
          <${LedgerMetric} label="reactions" value=${ledger.reaction_count} />
          <${LedgerMetric} label="turn started" value=${ledger.turn_started_count} />
          <${LedgerMetric} label="queue ACK" value=${ledger.event_queue_ack_count} />
          <${LedgerMetric} label="queue requeue" value=${ledger.event_queue_requeue_count} />
          <${LedgerMetric} label="cursor ACK" value=${ledger.cursor_ack_count} />
        </div>
      </div>

      <details class="rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-2xs">
        <summary class="cursor-pointer font-semibold text-[var(--color-fg-secondary)]">관측 범위와 원본 집계 증거</summary>
        <div class="mt-2 grid gap-3 lg:grid-cols-2">
          <dl class="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-[var(--color-fg-muted)]">
            <dt>operator action</dt><dd>${ledger.operator_action_required == null ? '알 수 없음' : ledger.operator_action_required ? '필요' : '불필요'}</dd>
            <dt>empty</dt><dd>${ledger.empty == null ? '알 수 없음' : ledger.empty ? '예' : '아니오'}</dd>
            <dt>rows</dt><dd><${LedgerCount} value=${ledger.row_count} /></dd>
            <dt>pending ID limit / keeper</dt><dd><${LedgerCount} value=${ledger.pending_id_display_limit_per_keeper} /></dd>
            <dt>queue escalation</dt><dd><${LedgerCount} value=${ledger.event_queue_escalation_count} /></dd>
            <dt>queue external input</dt><dd><${LedgerCount} value=${ledger.event_queue_external_input_count} /></dd>
            <dt>cursor swept</dt><dd><${LedgerCount} value=${ledger.cursor_swept_stimulus_count} /></dd>
            <dt>read errors</dt><dd><${LedgerCount} value=${ledger.read_error_count} /></dd>
            <dt>keeper discovery errors</dt><dd><${LedgerCount} value=${ledger.keeper_name_discovery_error_count} /></dd>
            <dt>store discovery errors</dt><dd><${LedgerCount} value=${ledger.reaction_store_discovery_error_count} /></dd>
          </dl>
          <dl class="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-[var(--color-fg-muted)]">
            <dt>metadata keepers</dt>
            <dd class="break-all">${ledger.keeper_names.length > 0 ? ledger.keeper_names.join(', ') : '없음'}</dd>
            <dt>store keepers</dt>
            <dd class="break-all">
              ${ledger.reaction_store_discovered_keeper_names.length > 0
                ? ledger.reaction_store_discovered_keeper_names.join(', ')
                : '없음'}
              · count ${ledger.reaction_store_discovered_keeper_count ?? '알 수 없음'}
            </dd>
            <dt>pending projection</dt>
            <dd>
              ${ledger.pending_by_keeper.length === 0 ? '없음' : ledger.pending_by_keeper.map(pending => html`
                <div key=${pending.keeper_name} class="break-all" data-ledger-pending-projection=${pending.keeper_name}>
                  ${pending.keeper_name}: ${pending.pending_stimulus_count.toLocaleString()}
                  ${pending.pending_ids_truncated === true ? ' · IDs 일부' : ''}
                  ${pending.pending_stimulus_ids.length > 0 ? ` · ${pending.pending_stimulus_ids.join(', ')}` : ''}
                </div>
              `)}
            </dd>
          </dl>
        </div>
      </details>

      ${hasDiscoveryErrors ? html`
        <div class="rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-2xs text-[var(--color-status-bad)]" role="alert">
          ${ledger.keeper_name_discovery_errors.map(error => html`
            <div key=${`keeper:${error}`} class="break-all">keeper discovery: ${error}</div>
          `)}
          ${ledger.reaction_store_discovery_errors.map(error => html`
            <div key=${`store:${error}`} class="break-all">reaction store discovery: ${error}</div>
          `)}
        </div>
      ` : null}

      ${ledger.decode_errors.length > 0 ? html`
        <div class="rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2 text-2xs text-[var(--color-status-bad)]" role="alert" data-ledger-decode-errors>
          ${ledger.decode_errors.map(error => html`
            <div key=${error} class="break-all">projection decode: ${error}</div>
          `)}
        </div>
      ` : null}

      ${ledger.keepers.length === 0 ? html`
        <${EmptyState} message=${ledger.empty === true ? '기록된 keeper reaction 없음' : 'keeper별 reaction 관측값 없음'} />
      ` : html`
        <div class="overflow-x-auto" role="region" aria-label="Keeper별 reaction ledger 상태">
          <table class="v2-monitoring-table w-full text-xs" aria-label="Keeper별 reaction ledger 상태">
            <thead>
              <tr class="border-b border-[var(--color-border-default)] text-left text-[var(--color-fg-muted)]">
                <th scope="col" class="pb-2 pr-3 font-normal">Keeper</th>
                <th scope="col" class="pb-2 pr-3 font-normal">Pending</th>
                <th scope="col" class="pb-2 pr-3 font-normal">진행</th>
                <th scope="col" class="pb-2 pr-3 font-normal">ACK</th>
                <th scope="col" class="pb-2 pr-3 font-normal">Escalated</th>
                <th scope="col" class="pb-2 pr-3 font-normal">외부 입력</th>
                <th scope="col" class="pb-2 pr-3 font-normal">Orphan</th>
                <th scope="col" class="pb-2 pr-3 font-normal">Cursor</th>
                <th scope="col" class="pb-2 font-normal">최근 stimulus / pending IDs</th>
              </tr>
            </thead>
            <tbody>
              ${ledger.keepers.map(keeper => html`<${KeeperLedgerStatus} key=${keeper.keeper_name} keeper=${keeper} />`)}
            </tbody>
          </table>
        </div>
      `}
    </section>
  `
}

/** Operator-pause panel — keepers currently in paused phase. */
function PausedKeepersPanel({ allKeepers }: { allKeepers: Keeper[] }) {
  const pausedKeepers = allKeepers.filter(isKeeperPaused)

  if (pausedKeepers.length === 0) {
    return html`
      <div class="rounded border border-[var(--ok-20)] bg-[var(--ok-10)] px-4 py-3 text-xs text-[var(--color-status-ok)]">
        ✓ 일시정지된 키퍼 없음 — 모든 키퍼가 정상 운영 중입니다
      </div>
    `
  }

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      ${pausedKeepers.length > 0 ? html`
        <div>
          <div class="mb-2 text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">
            현재 일시정지 (${pausedKeepers.length})
          </div>
          <div class="flex flex-col gap-2" role="list">
            ${pausedKeepers.map(k => {
              return html`
                <div
                  key=${k.name}
                  class="v2-monitoring-card flex flex-wrap items-center gap-3 rounded border border-[var(--paused-20)] bg-[var(--paused-10)] px-4 py-2.5"
                  role="listitem"
                >
                  <div class="font-mono text-xs font-semibold text-[var(--paused)]">
                    ⏸ ${k.name}
                  </div>
                  <div class="flex flex-wrap gap-2 text-2xs text-[var(--color-fg-muted)]">
                    ${k.runtime_blocker_summary || k.attention_reason ? html`
                      <span class="rounded bg-[var(--warn-10)] px-1.5 py-0.5 text-[var(--color-status-warn)]">
                        ${k.runtime_blocker_summary ?? k.attention_reason}
                      </span>
                    ` : null}
                    <button
                      class="v2-monitoring-action rounded bg-[var(--accent-10)] px-2 py-0.5 text-[var(--color-accent-fg)] hover:bg-[var(--accent-20)] transition-colors"
                      onClick=${(e: Event) => {
                        e.stopPropagation()
                        navigate('monitoring', { section: 'agents', keeper: k.name })
                      }}
                    >상세 보기 →</button>
                  </div>
                </div>
              `
            })}
          </div>
        </div>
      ` : null}
    </div>
  `
}

// ── View type ──────────────────────────────────────────────────────────────

type ReactivityView = 'health' | 'lifecycle' | 'events' | 'pause'

const DEFAULT_REACTIVITY_VIEW: ReactivityView = 'health'

const VIEW_CHIPS: Array<{ key: ReactivityView; label: string; title?: string }> = [
  { key: DEFAULT_REACTIVITY_VIEW, label: '상태 그리드',     title: '전체 키퍼 phase/활동 빠른 뷰' },
  { key: 'lifecycle',        label: '상태 전환',       title: '키퍼 FSM 전환 타임라인' },
  { key: 'events', label: '생명주기 이벤트', title: '수퍼바이저 생명주기 이벤트 (Started, Restarted, Dead_cleaned 등)' },
  { key: 'pause',            label: '일시정지',        title: '현재 일시정지된 키퍼' },
]

// ── Main component ─────────────────────────────────────────────────────────

/** Keeper Reactivity Monitor — real-time keeper lifecycle observability. */
export function KeeperReactivityMonitor({ defaultView }: { defaultView?: ReactivityView }) {
  const activeView = useSignal<ReactivityView>(defaultView ?? DEFAULT_REACTIVITY_VIEW)

  useEffect(() => {
    if (activeView.value === 'lifecycle') {
      void refreshKeeperPhaseTimeline()
    } else if (activeView.value === 'events') {
      void refreshKeeperLifecycleTimeline()
    }
  }, [activeView.value])

  const allKeepers = keepers.value
  const reactionLedger = shellRuntimeResolution.value?.fleet_safety?.keeper_reaction_ledger ?? null

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <div class="flex flex-col gap-0.5">
          <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">키퍼 반응성 모니터</h3>
        </div>
      </div>

      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${activeView.value}
        onChange=${(v: ReactivityView) => { activeView.value = v }}
        size="sm"
        tone="accent"
      />

      <div>
        ${activeView.value === 'health'
          ? html`
            <div class="flex flex-col gap-4">
              <${ReactionLedgerPanel} ledger=${reactionLedger} />
              <${HealthGrid} allKeepers=${allKeepers} />
            </div>
          `
        : activeView.value === 'lifecycle'
          ? html`<${KeeperPhaseTimeline} />`
        : activeView.value === 'events'
          ? html`<${KeeperLifecycleTimeline} />`
        : html`<${PausedKeepersPanel} allKeepers=${allKeepers} />`}
      </div>
    </div>
  `
}
