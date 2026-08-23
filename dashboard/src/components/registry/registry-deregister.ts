// MASC v2 — Registry 등록 해제 confirm (design: registry.jsx RegDeregister).
// The design's "drain 후 등록 해제" maps to real control-plane calls:
// shutdownKeeper (drain — 정상 종료) followed by purgeKeeper (레지스트리 제거).
// Purge answers 202 with an operation id and deletes asynchronously, so the
// row is marked purge-pending and the operator gets the operation id in a
// toast — same contract as keeper-action-panel's purge flow.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'

import type { Keeper } from '../../types'
import { purgeKeeper, shutdownKeeper } from '../../api/keeper-lifecycle'
import { markKeeperPurgePending } from '../../store'
import { KEEPER_STATUS_LABEL_KO, type KeeperOperationalState } from '../../lib/keeper-operational-state'
import { showToast } from '../common/toast'
import { KeeperBadge } from '../keeper-badge'

export interface RegistryDeregisterProps {
  readonly keeper: Keeper
  readonly state: KeeperOperationalState
  readonly onClose: () => void
}

/** 실행 중(running/stuck)이면 drain 없는 purge는 소유 태스크를 잃는다. */
export function deregisterNeedsDrain(state: KeeperOperationalState): boolean {
  return state.kind === 'running' || state.kind === 'stuck'
}

export function RegistryDeregister({ keeper, state, onClose }: RegistryDeregisterProps) {
  const busy = useSignal(false)
  const running = deregisterNeedsDrain(state)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  async function remove() {
    if (busy.value) return
    busy.value = true
    try {
      if (running) {
        const drained = await shutdownKeeper(keeper.name)
        if (!drained.ok) {
          showToast(drained.error ?? `${keeper.name} drain 실패`, 'error')
          return
        }
      }
      const result = await purgeKeeper(keeper.name)
      // The server deletes asynchronously; the roster row stays until a
      // refresh stops returning this keeper, so mark it pending first.
      markKeeperPurgePending(keeper.name)
      showToast(`${keeper.name} 등록 해제 요청됨 (operation ${result.operation_id})`, 'success')
      onClose()
    } catch (err) {
      showToast(err instanceof Error ? err.message : '등록 해제 실패', 'error')
    } finally {
      busy.value = false
    }
  }

  return html`
    <div class="reg-overlay" onClick=${onClose}>
      <div
        class="reg-dialog"
        style="max-width:460px;"
        role="dialog"
        aria-label="Keeper 등록 해제"
        onClick=${(e: Event) => e.stopPropagation()}
      >
        <div class="reg-dlg-h">
          <div>
            <span class="rd-eyebrow">등록 해제</span>
            <h3>Keeper 등록 해제</h3>
          </div>
          <button class="reg-dlg-x" title="닫기 (Esc)" onClick=${onClose}>✕</button>
        </div>
        <div class="reg-dlg-body">
          <div class="reg-confirm-kref">
            <${KeeperBadge} id=${keeper.name} size="lg" />
            <div class="ck-meta">
              <div class="ck-name">${keeper.koreanName ?? keeper.name}</div>
              <div class="ck-sub">${keeper.name} · ${KEEPER_STATUS_LABEL_KO[state.kind]}</div>
            </div>
          </div>
          ${running
            ? html`
                <div class="reg-confirm-warn">
                  <span class="cw-ico">⚠</span>
                  <span class="cw-txt">
                    이 keeper는 <b>실행 중</b>입니다. 소유 태스크를 잃지 않으려면
                    등록 해제 전에 먼저 <b>drain</b>(정상 종료)해야 합니다.
                  </span>
                </div>
              `
            : html`
                <div class="reg-confirm-msg">
                  레지스트리에서 <b>${keeper.name}</b>를 제거합니다. worktree와
                  매니페스트 참조가 해제됩니다. 같은 파일을 참조하는 다른 keeper는
                  영향받지 않습니다.
                </div>
              `}
        </div>
        <div class="reg-dlg-foot">
          <span class="rf-spacer"></span>
          <button class="reg-btn" onClick=${onClose}>취소</button>
          ${running
            ? html`
                <button
                  class="reg-btn danger"
                  disabled=${busy.value}
                  data-testid="registry-deregister-drain"
                  onClick=${remove}
                >
                  ${busy.value ? 'Draining…' : 'drain 후 등록 해제'}
                </button>
              `
            : html`
                <button
                  class="reg-btn danger"
                  disabled=${busy.value}
                  data-testid="registry-deregister-submit"
                  onClick=${remove}
                >
                  등록 해제
                </button>
              `}
        </div>
      </div>
    </div>
  `
}
