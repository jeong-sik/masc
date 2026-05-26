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
  keepers,
} from '../store'
import type { Keeper } from '../types'
import {
  keeperActionVisibility,
  isKeeperOperatorTargetable,
} from '../lib/keeper-predicates'

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

type KeeperActionKey = 'pause' | 'resume' | 'wakeup' | 'boot' | 'shutdown'

/** Execute a lifecycle action for a single keeper with toast feedback. */
async function runKeeperAction(
  name: string,
  action: KeeperActionKey,
): Promise<void> {
  const labels: Record<KeeperActionKey, string> = {
    pause: '일시정지',
    resume: '재개',
    wakeup: '깨우기',
    boot: '기동',
    shutdown: '종료',
  }

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
      showToast(`${name} ${labels[action]}됨`, 'success')
      afterAction()
    } else {
      revert?.()
      showToast(res.error ?? `${labels[action]} 실패`, 'error')
    }
  } catch {
    revert?.()
    showToast(`${labels[action]} 실패`, 'error')
  }
}

// ── Per-keeper row ────────────────────────────────────────────────────────

function KeeperActionRow({ keeper }: { keeper: Keeper }) {
  const busy = useSignal(false)
  const vis = keeperActionVisibility(keeper)

  async function handle(action: KeeperActionKey) {
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

  return html`
    <article
      class="flex flex-wrap items-center gap-2 px-3 py-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
      data-testid="keeper-action-row"
      aria-label="${keeper.name} 액션"
    >
      <div class="flex items-center gap-2 min-w-0 flex-1">
        <span class="text-xs font-semibold text-[var(--color-fg-secondary)] truncate max-w-28">${keeper.name}</span>
        <${KeeperPhaseBadge} phase=${keeper.phase} compact />
        <!--
          RFC-0135 §1.2: the previous auxiliary "일시정지" <span> at this
          position duplicated KeeperPhaseBadge's "⏸ 일시정지" output and
          colocated the *state noun* "일시정지" with the *verb button*
          "일시정지" later in the row — the user reported this as
          confusing on 2026-05-19. The badge already renders the state;
          this slot is intentionally empty so the action buttons own the
          verb meaning. PR-7 will further disambiguate by appending "하기"
          to verb-button labels.
        -->
      </div>
      <div class="flex items-center gap-1 shrink-0">
        ${vis.canBoot
          ? html`<${ActionButton}
              variant="ok"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('boot')}
              title="기동: offline keeper 를 다시 시작합니다 (offline → running)"
            >기동하기<//>`
          : null}
        ${vis.canPause
          ? html`<${ActionButton}
              variant="ghost"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('pause')}
              title="일시정지: 실행 중인 keeper 를 일시 멈춥니다 (running → paused, 현재 turn 은 정상 종료)"
            >일시정지하기<//>`
          : null}
        ${vis.canResume
          ? html`<${ActionButton}
              variant="ok"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('resume')}
              title="재개: 일시정지된 keeper 를 다시 실행합니다 (paused → running)"
            >재개하기<//>`
          : null}
        ${vis.canWake && !vis.canBoot
          ? html`<${ActionButton}
              variant="warn"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('wakeup')}
              title="깨우기: idle 또는 stuck 상태에서 다음 turn 을 즉시 시도합니다. 실행 중이어도 노출되는 이유는 cascade/oas/turn timeout 같은 stuck signal 이 backend 보다 먼저 frontend 에 보이는 케이스를 다루기 위함입니다."
            >깨우기<//>`
          : null}
        ${vis.canShutdown
          ? html`<${ActionButton}
              variant="danger"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('shutdown')}
              title="종료: keeper 를 완전 종료합니다 (running/paused → offline, fiber + 리소스 정리)"
            >종료하기<//>`
          : null}
      </div>
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
  const labels: Record<BulkKeeperDirectiveAction, string> = {
    pause: '일시정지',
    resume: '재개',
    wakeup: '깨우기',
  }
  // Optimistic: apply patch to every requested name. If the server
  // reports partial failure we revert only the failed names.
  const reverts = applyOptimisticKeeperDirectives(names, action)
  const revertAll = (): void => {
    for (const revert of reverts.values()) revert()
  }
  try {
    const res = await bulkKeeperDirective(names, action)
    if (res.ok && res.succeeded === res.requested) {
      showToast(`${res.succeeded}개 keeper ${labels[action]}됨`, 'success')
      afterAction()
    } else if (res.ok && res.succeeded > 0) {
      const failedRows = res.results.filter(r => !r.ok)
      for (const row of failedRows) reverts.get(row.name)?.()
      const failed = failedRows.map(r => r.name).join(', ')
      showToast(
        `${res.succeeded}/${res.requested} ${labels[action]}됨 — 실패: ${failed}`,
        'warning',
      )
      afterAction()
    } else {
      revertAll()
      showToast(`전체 ${labels[action]} 실패`, 'error')
    }
  } catch {
    revertAll()
    showToast(`전체 ${labels[action]} 실패`, 'error')
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

  if (keeperList.length === 0) {
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
        <div class="flex gap-1.5" data-testid="keeper-action-panel-bulk">
          ${resumableNames.length > 0
            ? html`<${ActionButton}
                variant="ok"
                size="sm"
                disabled=${bulkBusy.value}
                onClick=${async () => {
                  const ok = await requestConfirm({
                    title: `${resumableNames.length}개 keeper 전체 재개`,
                    message: 'paused → running 으로 전환합니다.',
                    confirmText: '재개',
                  })
                  if (ok) await runBulk(resumableNames, 'resume')
                }}
                title="현재 paused 인 ${resumableNames.length}개 keeper 를 한 번에 재개합니다."
              >전체 재개 (${resumableNames.length})<//>`
            : null}
          ${pausableNames.length > 0
            ? html`<${ActionButton}
                variant="ghost"
                size="sm"
                disabled=${bulkBusy.value}
                onClick=${async () => {
                  const ok = await requestConfirm({
                    title: `${pausableNames.length}개 keeper 전체 일시정지`,
                    message: 'running → paused 로 전환합니다. 현재 turn 은 정상 종료됩니다.',
                    confirmText: '일시정지',
                  })
                  if (ok) await runBulk(pausableNames, 'pause')
                }}
                title="현재 running 인 ${pausableNames.length}개 keeper 를 한 번에 일시정지합니다."
              >전체 일시정지 (${pausableNames.length})<//>`
            : null}
        </div>
      </div>
      ${online.length === 0
        ? html`<div class="text-2xs text-[var(--color-fg-muted)]">온라인 키퍼 없음</div>`
        : html`
          <div class="flex flex-col gap-1.5" role="list">
            ${online.map(k => html`<${KeeperActionRow} keeper=${k} key=${k.name} />`)}
          </div>
        `}
    </section>
  `
}
