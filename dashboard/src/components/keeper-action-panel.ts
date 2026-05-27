// Keeper Action Panel — fleet-level pause/resume/restart/boot controls.
//
// Surfaces per-keeper lifecycle actions that previously required
// navigating into the keeper detail view. Designed for the Ops tab
// so operators can intervene quickly without losing fleet context.
//
// Actions available per keeper:
//   pause     → POST /api/v1/keepers/:name/directive  { action: "pause" }
//   resume    → POST /api/v1/keepers/:name/directive  { action: "resume" }
//   wakeup    → POST /api/v1/keepers/:name/directive  { action: "wakeup" }
//   boot      → POST /api/v1/keepers/:name/boot
//   shutdown  → POST /api/v1/keepers/:name/shutdown
//
// All action functions are already in api/keeper.ts; this component
// wires them to a fleet grid without touching the detail view.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { CARD_STANDARD } from './common/card'
import { ActionButton } from './common/button'
import { requestConfirm } from './common/confirm-dialog'
import { showToast } from './common/toast'
import { KeeperPhaseBadge } from './keeper-phase-indicator'
import {
  bootKeeper,
  bulkKeeperDirective,
  pauseKeeper,
  resumeKeeper,
  shutdownKeeper,
  wakeKeeper,
} from '../api/keeper'
import type { BulkKeeperDirectiveAction } from '../api/keeper'
import {
  applyOptimisticKeeperDirective,
  applyOptimisticKeeperDirectives,
  invalidateDashboardCache,
  refreshDashboard,
  refreshExecution,
  executionLoaded,
  executionLoading,
  keepers,
} from '../store'
import type { Keeper } from '../types'
import {
  keeperActionVisibility,
  isKeeperOperatorTargetable,
} from '../lib/keeper-predicates'
import { keeperPauseDisplay } from '../lib/keeper-runtime-display'

// ── Shared helpers ────────────────────────────────────────────────────────

function afterAction(): void {
  invalidateDashboardCache()
  // Reconcile the optimistic patch against the authoritative server
  // snapshot. `force: true` was a dead signal in the bootstrap path of
  // `refreshDashboard` (only consumed by the fallback) — drop it so we
  // don't lie about what the call does.
  void refreshDashboard().catch(err => {
    const message = err instanceof Error ? err.message : 'dashboard refresh failed'
    showToast(message, 'warning')
  })
}

export type KeeperActionKey = 'pause' | 'resume' | 'wakeup' | 'boot' | 'shutdown'

/**
 * Single source of truth for keeper-action 한국어 라벨.
 *
 * 같은 action 의 라벨이 file 내 4 표면(toast/bulk-toast/full-button/compact-button)
 * 에 어형만 달리한 채 hardcoded 되어 있던 SSOT 위반을 통합했다. 어형 3 종이
 * 다른 *이유* 가 있다 (raw 라벨 통합이 아니라 어형별 entry 를 가짐):
 *
 *   noun    — toast 메시지의 어미 합성용 ("${noun}됨", "${noun} 실패", "전체 ${noun}").
 *   verb    — fleet-level row 의 full 버튼 텍스트. "하기" suffix 가 붙은 동사.
 *   compact — KEEPER OPERATIONS 인라인 행에 들어가는 좁은 버튼 텍스트.
 *
 * RFC-0135 §1.2 와의 호환: `keeperPauseDisplay` 의 verb-suffix 규약 ("하기") 을
 * 따른다. 한 라벨을 변경하려면 *모든 어형* 을 함께 검토해 라벨 어휘와 어형
 * 규약이 분리되지 않게 한다.
 */
interface KeeperActionLabel {
  /** "${name} ${noun}됨" / "${noun} 실패" / "전체 ${noun}" 의 어근. */
  noun: string
  /** Fleet-level full row 버튼 텍스트 (verb + 하기 suffix 규약). */
  verb: string
  /** KEEPER OPERATIONS 인라인 컴팩트 버튼 텍스트. */
  compact: string
}

const KEEPER_ACTION_LABELS: Record<KeeperActionKey, KeeperActionLabel> = {
  pause:    { noun: '일시정지', verb: '일시정지하기', compact: '멈춤' },
  resume:   { noun: '재개',     verb: '재개하기',     compact: '재개' },
  wakeup:   { noun: '깨우기',   verb: '깨우기',       compact: '깨움' },
  boot:     { noun: '기동',     verb: '기동하기',     compact: '기동' },
  shutdown: { noun: '종료',     verb: '종료하기',     compact: '종료' },
}

/** Execute a lifecycle action for a single keeper with toast feedback. */
export async function runKeeperAction(
  name: string,
  action: KeeperActionKey,
): Promise<void> {
  const noun = KEEPER_ACTION_LABELS[action].noun

  // Optimistic UI: pause/resume/wakeup mutate `paused` + phase locally
  // before the POST returns so the row's button set flips instantly. On
  // failure we revert. Boot/shutdown stay server-driven (richer state
  // transitions).
  const revert =
    action === 'pause' || action === 'resume' || action === 'wakeup'
      ? applyOptimisticKeeperDirective(name, action)
      : null
  try {
    let res: { ok: boolean; error?: string }
    switch (action) {
      case 'pause':    res = await pauseKeeper(name);    break
      case 'resume':   res = await resumeKeeper(name);   break
      case 'wakeup':   res = await wakeKeeper(name);     break
      case 'boot':     res = await bootKeeper(name);     break
      case 'shutdown': res = await shutdownKeeper(name); break
    }
    if (res.ok) {
      showToast(`${name} ${noun}됨`, 'success')
      afterAction()
    } else {
      revert?.()
      showToast(res.error ?? `${noun} 실패`, 'error')
    }
  } catch {
    revert?.()
    showToast(`${noun} 실패`, 'error')
  }
}

// ── Shared button group ───────────────────────────────────────────────────

/**
 * KeeperActionButtons — reusable lifecycle button group for a single keeper.
 *
 * Used by both the fleet-level KeeperActionPanel row and by inline action
 * cells inside the KEEPER OPERATIONS table (`agent-roster.ts`). When mounted
 * inside another clickable parent (a row that handles selection), pass
 * `stopPropagation` so button clicks don't bubble to row selection.
 *
 * Visible verbs match phase semantics (canBoot/canPause/canResume/canWake/
 * canShutdown) and shutdown is gated by a confirm dialog.
 */
export function KeeperActionButtons({
  keeper,
  size = 'sm',
  stopPropagation = false,
  compact = false,
}: {
  keeper: Keeper
  size?: 'sm' | 'md'
  stopPropagation?: boolean
  /** Single-glyph labels (재개/멈춤/깨움/기동/종료) instead of "재개하기" etc. */
  compact?: boolean
}) {
  const busy = useSignal(false)
  const vis = keeperActionVisibility(keeper)

  async function handle(e: Event, action: KeeperActionKey) {
    if (stopPropagation) e.stopPropagation()
    if (busy.value) return
    if (action === 'shutdown') {
      const confirmed = await requestConfirm({
        title: '키퍼 종료',
        message: `${keeper.name} 키퍼를 종료합니까?`,
        tone: 'danger',
      })
      if (!confirmed) return
    }
    busy.value = true
    try {
      await runKeeperAction(keeper.name, action)
    } finally {
      busy.value = false
    }
  }

  // Verb labels match keeperPauseDisplay verb conventions. Compact mode
  // drops the "하기" suffix so the buttons fit inside a narrow row cell.
  const text = (action: KeeperActionKey): string =>
    compact ? KEEPER_ACTION_LABELS[action].compact : KEEPER_ACTION_LABELS[action].verb

  return html`
    <div
      class="flex items-center gap-1 shrink-0"
      data-testid="keeper-action-buttons"
      onClick=${stopPropagation ? (e: Event) => e.stopPropagation() : undefined}
    >
      ${vis.canBoot
        ? html`<${ActionButton}
            variant="ok"
            size=${size}
            disabled=${busy.value}
            onClick=${(e: Event) => handle(e, 'boot')}
            title="기동: offline keeper 를 다시 시작합니다 (offline → running)"
          >${text('boot')}<//>`
        : null}
      ${vis.canPause
        ? html`<${ActionButton}
            variant="ghost"
            size=${size}
            disabled=${busy.value}
            onClick=${(e: Event) => handle(e, 'pause')}
            title="일시정지: 실행 중인 keeper 를 일시 멈춥니다 (running → paused, 현재 turn 은 정상 종료)"
          >${text('pause')}<//>`
        : null}
      ${vis.canResume
        ? html`<${ActionButton}
            variant="ok"
            size=${size}
            disabled=${busy.value}
            onClick=${(e: Event) => handle(e, 'resume')}
            title="재개: 일시정지된 keeper 를 다시 실행합니다 (paused → running)"
          >${text('resume')}<//>`
        : null}
      ${vis.canWake && !vis.canBoot
        ? html`<${ActionButton}
            variant="warn"
            size=${size}
            disabled=${busy.value}
            onClick=${(e: Event) => handle(e, 'wakeup')}
            title="깨우기: idle 또는 stuck 상태에서 다음 turn 을 즉시 시도합니다. 실행 중이어도 노출되는 이유는 cascade/oas/turn timeout 같은 stuck signal 이 backend 보다 먼저 frontend 에 보이는 케이스를 다루기 위함입니다."
          >${text('wakeup')}<//>`
        : null}
      ${vis.canShutdown
        ? html`<${ActionButton}
            variant="danger"
            size=${size}
            disabled=${busy.value}
            onClick=${(e: Event) => handle(e, 'shutdown')}
            title="종료: keeper 를 완전 종료합니다 (running/paused → offline, fiber + 리소스 정리)"
          >${text('shutdown')}<//>`
        : null}
    </div>
  `
}

// ── Per-keeper row ────────────────────────────────────────────────────────

function KeeperActionRow({ keeper }: { keeper: Keeper }) {
  const pauseDisplay = keeperPauseDisplay(keeper)

  return html`
    <article
      class="flex flex-wrap items-start gap-2 px-3 py-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
      data-testid="keeper-action-row"
      aria-label="${keeper.name} 액션${pauseDisplay ? `: ${pauseDisplay.detail}` : ''}"
    >
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2 min-w-0">
          <span class="text-xs font-semibold text-[var(--color-fg-secondary)] truncate max-w-28">${keeper.name}</span>
          <${KeeperPhaseBadge} phase=${keeper.phase} compact />
        </div>
        <!--
          RFC-0135 §1.2: the previous auxiliary "일시정지" <span> at this
          position duplicated KeeperPhaseBadge's "⏸ 일시정지" output and
          colocated the *state noun* "일시정지" with the *verb button*
          "일시정지" later in the row — the user reported this as
          confusing on 2026-05-19. The badge already renders the state;
          the line below carries reason/next-action evidence, not a
          second paused-state noun. Verb buttons keep the "하기" suffix.
        -->
        ${pauseDisplay
          ? html`
            <div
              class="mt-1 max-w-full truncate text-3xs leading-[1.35] text-[var(--color-fg-muted)]"
              title=${pauseDisplay.title}
              data-testid="keeper-pause-detail"
            >
              ${pauseDisplay.detail}
            </div>
          `
          : null}
      </div>
      <${KeeperActionButtons} keeper=${keeper} size="sm" />
    </article>
  `
}

// ── Bulk action helpers ───────────────────────────────────────────────────

/** Apply a directive to N keepers in one round-trip via the bulk endpoint
    and surface the result as a single toast (with partial-failure detail). */
async function runBulkKeeperDirective(
  names: string[],
  action: BulkKeeperDirectiveAction,
): Promise<void> {
  if (names.length === 0) return
  // `BulkKeeperDirectiveAction` is a subset of `KeeperActionKey`, so the
  // single SSOT covers both. Subset-cast here keeps the type-narrow without
  // duplicating the label map.
  const noun = KEEPER_ACTION_LABELS[action as KeeperActionKey].noun
  // Optimistic: apply patch to every requested name. If the server
  // reports partial failure we revert only the failed names.
  const reverts = applyOptimisticKeeperDirectives(names, action)
  const revertAll = (): void => {
    for (const revert of reverts.values()) revert()
  }
  try {
    const res = await bulkKeeperDirective(names, action)
    if (res.ok && res.succeeded === res.requested) {
      showToast(`${res.succeeded}개 keeper ${noun}됨`, 'success')
      afterAction()
    } else if (res.ok && res.succeeded > 0) {
      const failedRows = res.results.filter(r => !r.ok)
      for (const row of failedRows) reverts.get(row.name)?.()
      const failed = failedRows.map(r => r.name).join(', ')
      showToast(
        `${res.succeeded}/${res.requested} ${noun}됨 — 실패: ${failed}`,
        'warning',
      )
      afterAction()
    } else {
      revertAll()
      showToast(`전체 ${noun} 실패`, 'error')
    }
  } catch {
    revertAll()
    showToast(`전체 ${noun} 실패`, 'error')
  }
}

// ── Public panel ──────────────────────────────────────────────────────────

/**
 * Fleet-level keeper action panel.
 * Renders one row per online keeper with inline lifecycle action buttons.
 * Intended to be placed in the Ops section alongside QuickIntervene.
 */
export function KeeperActionPanel() {
  const keeperList = keepers.value
  const loaded = executionLoaded.value
  const loading = executionLoading.value

  useEffect(() => {
    if (loaded || loading) return
    void refreshExecution({ force: true }).catch(err => {
      const message = err instanceof Error ? err.message : 'execution refresh failed'
      showToast(message, 'warning')
    })
  }, [loaded, loading])

  // RFC-0135 PR-9b: route the "should we show this keeper in the action
  // panel?" filter through the typed predicates instead of an inline OR
  // chain — paused keepers should still appear (so operator can resume)
  // even when their status appears offline.
  const online = keeperList.filter(isKeeperOperatorTargetable)
  const bulkBusy = useSignal(false)

  // Partition online keepers by which bulk action is applicable. The
  // typed predicate is authoritative — never derive bulk eligibility from
  // a status string.
  const pausableNames = online
    .filter(k => keeperActionVisibility(k).canPause)
    .map(k => k.name)
  const resumableNames = online
    .filter(k => keeperActionVisibility(k).canResume)
    .map(k => k.name)

  const runBulk = async (
    names: string[],
    action: BulkKeeperDirectiveAction,
  ): Promise<void> => {
    if (bulkBusy.value || names.length === 0) return
    bulkBusy.value = true
    try {
      await runBulkKeeperDirective(names, action)
    } finally {
      bulkBusy.value = false
    }
  }

  if (keeperList.length === 0 && loaded) {
    return null
  }

  return html`
    <section
      class="${CARD_STANDARD} flex flex-col gap-3"
      data-testid="keeper-action-panel"
      aria-label="키퍼 액션 패널"
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">Keeper Actions</h3>
          <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">
            Fleet-level lifecycle controls. Pause, resume, wake, boot, or shut down individual keepers.
          </p>
        </div>
        <div class="flex flex-wrap justify-end gap-1.5" data-testid="keeper-action-panel-bulk">
          ${resumableNames.length > 0
            ? html`<${ActionButton}
                variant="ok"
                size="sm"
                class="whitespace-nowrap"
                disabled=${bulkBusy.value}
                onClick=${async () => {
                  const ok = await requestConfirm({
                    title: `${resumableNames.length}개 keeper 전체 ${KEEPER_ACTION_LABELS.resume.noun}`,
                    message: 'paused → running 으로 전환합니다.',
                    confirmText: KEEPER_ACTION_LABELS.resume.noun,
                  })
                  if (ok) await runBulk(resumableNames, 'resume')
                }}
                title="현재 paused 인 ${resumableNames.length}개 keeper 를 한 번에 ${KEEPER_ACTION_LABELS.resume.verb}."
              >전체 ${KEEPER_ACTION_LABELS.resume.noun} (${resumableNames.length})<//>`
            : null}
          ${pausableNames.length > 0
            ? html`<${ActionButton}
                variant="ghost"
                size="sm"
                class="whitespace-nowrap"
                disabled=${bulkBusy.value}
                onClick=${async () => {
                  const ok = await requestConfirm({
                    title: `${pausableNames.length}개 keeper 전체 ${KEEPER_ACTION_LABELS.pause.noun}`,
                    message: 'running → paused 로 전환합니다. 현재 turn 은 정상 종료됩니다.',
                    confirmText: KEEPER_ACTION_LABELS.pause.noun,
                  })
                  if (ok) await runBulk(pausableNames, 'pause')
                }}
                title="현재 running 인 ${pausableNames.length}개 keeper 를 한 번에 ${KEEPER_ACTION_LABELS.pause.verb}."
              >전체 ${KEEPER_ACTION_LABELS.pause.noun} (${pausableNames.length})<//>`
            : null}
        </div>
      </div>
      ${keeperList.length === 0
        ? html`<div class="text-2xs text-[var(--color-fg-muted)]">Execution SSOT 로딩 중</div>`
        : online.length === 0
          ? html`<div class="text-2xs text-[var(--color-fg-muted)]">온라인 키퍼 없음</div>`
        : html`
          <div class="flex flex-col gap-1.5" role="list">
            ${online.map(k => html`<${KeeperActionRow} keeper=${k} key=${k.name} />`)}
          </div>
        `}
    </section>
  `
}
