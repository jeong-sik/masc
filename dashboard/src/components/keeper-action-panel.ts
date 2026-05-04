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
  pauseKeeper,
  resumeKeeper,
  shutdownKeeper,
  wakeKeeper,
} from '../api/keeper'
import { invalidateDashboardCache, refreshDashboard, keepers } from '../store'
import type { Keeper } from '../types'

// ── Shared helpers ────────────────────────────────────────────────────────

async function afterAction(): Promise<void> {
  invalidateDashboardCache()
  await refreshDashboard({ force: true })
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
      await afterAction()
    } else {
      showToast(res.error ?? `${labels[action]} 실패`, 'error')
    }
  } catch {
    showToast(`${labels[action]} 실패`, 'error')
  }
}

// ── Visibility helpers ────────────────────────────────────────────────────

/** Determine which action buttons are relevant for a keeper's current state. */
export function keeperActionVisibility(keeper: Keeper): {
  canPause: boolean
  canResume: boolean
  canWake: boolean
  canBoot: boolean
  canShutdown: boolean
} {
  const status = (keeper.status ?? '').toLowerCase()
  const phase = (keeper.phase ?? '').toString().toLowerCase()

  const isOffline =
    status === 'offline' ||
    status === 'inactive' ||
    phase === 'offline' ||
    phase === 'stopped' ||
    phase === 'dead' ||
    phase === 'crashed'

  const isRunning =
    status === 'active' ||
    status === 'running' ||
    status === 'idle' ||
    status === 'busy' ||
    phase === 'running' ||
    phase === 'failing' ||
    phase === 'overflowed' ||
    phase === 'compacting' ||
    phase === 'handing_off' ||
    phase === 'draining'

  const isPaused =
    keeper.paused === true || status === 'paused' || phase === 'paused'

  const isStuck =
    phase === 'restarting' ||
    keeper.runtime_blocker_class === 'cascade_exhausted' ||
    keeper.runtime_blocker_class === 'oas_timeout_budget' ||
    keeper.runtime_blocker_class === 'turn_timeout'

  return {
    canPause:    isRunning && !isPaused,
    canResume:   isPaused,
    canWake:     isStuck || (isRunning && !isPaused),
    canBoot:     isOffline,
    canShutdown: isRunning || isPaused,
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
        ${keeper.paused
          ? html`<span class="text-3xs font-semibold text-[var(--paused,var(--color-status-warn))]">일시정지</span>`
          : null}
      </div>
      <div class="flex items-center gap-1 shrink-0">
        ${vis.canBoot
          ? html`<${ActionButton}
              variant="ok"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('boot')}
              title="기동"
            >기동<//>`
          : null}
        ${vis.canPause
          ? html`<${ActionButton}
              variant="ghost"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('pause')}
              title="일시정지"
            >일시정지<//>`
          : null}
        ${vis.canResume
          ? html`<${ActionButton}
              variant="ok"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('resume')}
              title="재개"
            >재개<//>`
          : null}
        ${vis.canWake && !vis.canBoot
          ? html`<${ActionButton}
              variant="warn"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('wakeup')}
              title="깨우기: sleep 중인 keeper를 즉시 깨워 다음 turn을 시도"
            >깨우기<//>`
          : null}
        ${vis.canShutdown
          ? html`<${ActionButton}
              variant="danger"
              size="sm"
              disabled=${busy.value}
              onClick=${() => handle('shutdown')}
              title="종료"
            >종료<//>`
          : null}
      </div>
    </article>
  `
}

// ── Public panel ──────────────────────────────────────────────────────────

/**
 * Fleet-level keeper action panel.
 * Renders one row per online keeper with inline lifecycle action buttons.
 * Intended to be placed in the Ops section alongside QuickIntervene.
 */
export function KeeperActionPanel() {
  const keeperList = keepers.value
  const online = keeperList.filter(k => {
    const s = (k.status ?? '').toLowerCase()
    return s !== 'offline' || k.phase === 'Paused' || k.paused
  })

  if (keeperList.length === 0) {
    return null
  }

  return html`
    <section
      class="${CARD_STANDARD} flex flex-col gap-3"
      data-testid="keeper-action-panel"
      aria-label="키퍼 액션 패널"
    >
      <div>
        <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">Keeper Actions</h3>
        <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">
          Fleet-level lifecycle controls. Pause, resume, wake, boot, or shut down individual keepers.
        </p>
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
