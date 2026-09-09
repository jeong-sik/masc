// Confirm one durable purge operation; the server owns lane shutdown and cleanup.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'

import type { Keeper } from '../../types'
import { purgeKeeper, KEEPER_PURGE_ARTIFACTS } from '../../api/keeper-lifecycle'
import { markKeeperPurgePending, refreshKeeperDeletions } from '../../store'
import { KEEPER_STATUS_LABEL_KO, type KeeperOperationalState } from '../../lib/keeper-operational-state'
import { showToast } from '../common/toast'
import { KeeperBadge } from '../keeper-badge'

export interface RegistryDeregisterProps {
  readonly keeper: Keeper
  readonly state: KeeperOperationalState
  readonly onClose: () => void
}

/** 실행 중인 키퍼의 종료도 같은 삭제 작업에 포함된다. */
export function deregisterStopsRunningKeeper(state: KeeperOperationalState): boolean {
  return state.kind === 'running' || state.kind === 'stuck'
}

export function RegistryDeregister({ keeper, state, onClose }: RegistryDeregisterProps) {
  const busy = useSignal(false)
  const running = deregisterStopsRunningKeeper(state)

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
      const result = await purgeKeeper(keeper.name)
      // The durable inventory remains visible after the Keeper row is removed.
      markKeeperPurgePending(keeper.name)
      void refreshKeeperDeletions()
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
                    이 키퍼는 <b>실행 중</b>입니다. 삭제 작업이 레인 종료와
                    소유 Task 정리를 확인한 뒤 파일을 제거합니다.
                  </span>
                </div>
              `
            : html`
                <div class="reg-confirm-msg">
                  <b>${keeper.name}</b> 키퍼를 영구 제거합니다.
                </div>
              `}
          <p>설정과 기록도 함께 삭제하며 되돌릴 수 없습니다.</p>
          <ul>${KEEPER_PURGE_ARTIFACTS.map(item => html`<li key=${item}>${item}</li>`)}</ul>
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
                  ${busy.value ? '삭제 요청 중…' : '종료 후 영구 제거'}
                </button>
              `
            : html`
                <button
                  class="reg-btn danger"
                  disabled=${busy.value}
                  data-testid="registry-deregister-submit"
                  onClick=${remove}
                >
                  영구 제거
                </button>
              `}
        </div>
      </div>
    </div>
  `
}
