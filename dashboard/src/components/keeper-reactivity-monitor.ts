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
import { keepers } from '../store'
import { navigate } from '../router'
import { KeeperPhaseBadge, pipelineStageDetailLabel } from './keeper-phase-indicator'
import { KeeperPhaseTimeline, refreshKeeperPhaseTimeline } from './keeper-phase-strip'
import { KeeperLifecycleTimeline, refreshKeeperLifecycleTimeline } from './keeper-lifecycle-timeline'
import { isKeeperCrashed, isKeeperPaused } from '../lib/keeper-predicates'
import { TimeAgo } from './common/time-ago'
import { EmptyState } from './common/feedback-state'
import { FilterChips } from './common/filter-chips'
import type { Keeper } from '../types'

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
              <${HealthGrid} allKeepers=${allKeepers} />
              <div>
                <div class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)] mb-2">재시작 예산 게이지</div>
              </div>
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
