import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { ActionButton } from '../common/button'
import { CARD_STANDARD } from '../common/card'
import { Select } from '../common/select'
import { operatorActionBusy, operatorSnapshot } from '../../operator-store'
import type { OperatorActionDescriptor } from '../../types'
import { actionTypeLabel, executeAction, normalizeStatus } from './helpers'

const ADAPTED_KEEPER_ACTIONS = new Set([
  'keeper_probe',
  'keeper_recover',
  'keeper_github_identity_status',
  'keeper_github_identity_login_prepare',
])

const HANDLED_ELSEWHERE_ACTIONS = new Set([
  'broadcast',
  'keeper_message',
  'namespace_pause',
  'namespace_resume',
  'room_pause',
  'room_resume',
  'social_sweep',
  'task_inject',
])

function visibleKeeperAction(action: OperatorActionDescriptor): boolean {
  if (action.target_type !== 'keeper') return false
  return ADAPTED_KEEPER_ACTIONS.has(action.action_type)
    || !HANDLED_ELSEWHERE_ACTIONS.has(action.action_type)
}

function actionDescription(action: OperatorActionDescriptor): string {
  const description = action.description?.trim()
  if (description) return description
  switch (action.action_type) {
    case 'keeper_probe':
      return '선택한 keeper의 상태와 진단 정보를 확인합니다.'
    case 'keeper_recover':
      return '선택한 keeper를 복구 플로우로 넘깁니다.'
    case 'keeper_github_identity_status':
      return '선택한 keeper의 GitHub identity 상태를 확인합니다.'
    case 'keeper_github_identity_login_prepare':
      return '선택한 keeper의 GitHub login 준비 정보를 생성합니다.'
    default:
      return '서버 catalog에는 있지만 아직 전용 UI adapter가 없습니다.'
  }
}

export function KeeperUtilitiesPanel() {
  const selectedKeeper = useSignal('')
  const snapshot = operatorSnapshot.value
  const busy = operatorActionBusy.value
  const actions = (snapshot?.available_actions ?? []).filter(visibleKeeperAction)
  if (actions.length === 0) return null

  const onlineKeepers = (snapshot?.keepers ?? [])
    .filter(keeper => normalizeStatus(keeper.status) !== 'offline')
  const selectedName = onlineKeepers.some(keeper => keeper.name === selectedKeeper.value)
    ? selectedKeeper.value
    : (onlineKeepers[0]?.name ?? '')

  async function runAction(action: OperatorActionDescriptor) {
    if (!selectedName || !ADAPTED_KEEPER_ACTIONS.has(action.action_type)) return
    await executeAction({
      action_type: action.action_type,
      target_type: 'keeper',
      target_id: selectedName,
      payload: {},
      successMessage: `${selectedName} ${actionTypeLabel(action.action_type)} 실행을 요청했습니다`,
    })
  }

  return html`
    <section class="${CARD_STANDARD} flex flex-col gap-3" data-testid="keeper-utilities-panel" aria-label="키퍼 유틸리티">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">키퍼 유틸리티</h3>
          <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">
            서버 available_actions catalog 기준으로 노출합니다.
          </p>
        </div>
        <${Select}
          class="shrink-0 px-3 py-2 text-xs min-w-36"
          ariaLabel="키퍼 유틸리티 대상"
          value=${selectedName}
          disabled=${busy || onlineKeepers.length === 0}
          options=${onlineKeepers.length === 0
            ? [{ value: '', label: '온라인 keeper 없음' }]
            : onlineKeepers.map(keeper => ({ value: keeper.name, label: keeper.name }))}
          onInput=${(v: string) => { selectedKeeper.value = v }}
        />
      </div>

      <div class="grid gap-2">
        ${actions.map(action => {
          const adapted = ADAPTED_KEEPER_ACTIONS.has(action.action_type)
          const disabled = busy || !selectedName || !adapted
          return html`
            <article
              key=${`${action.target_type}:${action.action_type}`}
              class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3"
              data-testid="keeper-utility-action"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="text-xs font-semibold text-[var(--color-fg-secondary)]">${actionTypeLabel(action.action_type)}</div>
                  <div class="mt-1 text-2xs leading-[1.45] text-[var(--color-fg-muted)]">${actionDescription(action)}</div>
                  ${adapted
                    ? null
                    : html`<div class="mt-1 text-2xs font-medium text-warn">UI adapter pending</div>`}
                </div>
                <${ActionButton}
                  variant=${adapted ? 'subtle' : 'ghost'}
                  size="sm"
                  disabled=${disabled}
                  onClick=${() => { void runAction(action) }}
                >
                  ${adapted ? (action.confirm_required ? '요청' : '실행') : '대기'}
                <//>
              </div>
            </article>
          `
        })}
      </div>
    </section>
  `
}
