// Keeper lifecycle button group — reusable single-keeper action controls.
//
// Used by Monitor → Keeper Fleet (AgentRoster rows + keeper detail page).
// Fleet-level grid was removed when Command → Operations stopped duplicating
// the Monitor roster (2026-05-28).
//
// Actions available per keeper:
//   pause     → POST /api/v1/keepers/:name/directive  { action: "pause" }
//   resume    → POST /api/v1/keepers/:name/directive  { action: "resume" }
//   wakeup    → POST /api/v1/keepers/:name/directive  { action: "wakeup" }
//   boot      → POST /api/v1/keepers/:name/boot
//   shutdown  → POST /api/v1/keepers/:name/shutdown

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { ActionButton } from './common/button'
import { requestConfirm } from './common/confirm-dialog'
import { showToast } from './common/toast'
import {
  bootKeeper,
  pauseKeeper,
  resumeKeeper,
  shutdownKeeper,
  wakeKeeper,
} from '../api/keeper'
import {
  applyOptimisticKeeperDirective,
  refreshKeeperRuntimeStatus,
} from '../store'
import type { Keeper } from '../types'
import { keeperActionVisibility } from '../lib/keeper-predicates'

// ── Shared helpers ────────────────────────────────────────────────────────

function afterAction(): void {
  // Reconcile the optimistic patch against the authoritative server
  // snapshots that drive status UI: execution rows for the roster and light
  // shell runtime-health for top-strip / roster aggregate counts. This avoids
  // the old full `refreshDashboard()` bootstrap while keeping every status
  // surface on the same post-action truth source.
  void refreshKeeperRuntimeStatus({ force: true }).catch(err => {
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
      class="flex items-center gap-1 shrink-0 v2-monitoring-action"
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
            title="깨우기: idle 또는 stuck 상태에서 다음 turn 을 즉시 시도합니다. 실행 중이어도 노출되는 이유는 runtime/oas/turn timeout 같은 stuck signal 이 backend 보다 먼저 frontend 에 보이는 케이스를 다루기 위함입니다."
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
