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
      return 'Inspect status and diagnostics for the selected keeper.'
    case 'keeper_recover':
      return 'Hand the selected keeper to the recovery flow.'
    case 'keeper_github_identity_status':
      return 'Inspect GitHub identity status for the selected keeper.'
    case 'keeper_github_identity_login_prepare':
      return 'Generate GitHub login preparation details for the selected keeper.'
    default:
      return 'Available in the server catalog; dedicated UI adapter is still pending.'
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
      successMessage: `Requested ${actionTypeLabel(action.action_type)} for ${selectedName}`,
    })
  }

  return html`
    <section class="${CARD_STANDARD} flex flex-col gap-3" data-testid="keeper-utilities-panel" aria-label="Keeper utilities">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-40 flex-1">
          <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">Keeper Utilities</h3>
          <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">
            Server-backed actions from the available_actions catalog.
          </p>
        </div>
        <${Select}
          class="shrink-0 px-3 py-2 text-xs min-w-36 max-w-full"
          ariaLabel="Keeper utility target"
          value=${selectedName}
          disabled=${busy || onlineKeepers.length === 0}
          options=${onlineKeepers.length === 0
            ? [{ value: '', label: 'No online keepers' }]
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
              class="rounded-[var(--r-1)] border border-[var(--white-8)] bg-[var(--white-2)] p-3"
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
                  ${adapted ? (action.confirm_required ? 'Request' : 'Run') : 'Pending'}
                <//>
              </div>
            </article>
          `
        })}
      </div>
    </section>
  `
}
