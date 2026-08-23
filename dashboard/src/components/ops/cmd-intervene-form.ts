// MASC Dashboard — Command Intervene form + Gate links (keeper-v2 command.jsx parity)
//
// Design: prototypes/keeper-v2/command.jsx — CmdOps (cmd-form/cmd-text/cmd-actions)
// and the Gate/HITL link panel (cmd-gatelinks).
// Live wiring:
//   · action dispatch → dispatchOperatorAction (operator action endpoint) via
//     executeAction; server accepts broadcast / namespace_pause / namespace_resume
//     (target_type=workspace) and keeper_message (target_type=keeper).
//   · target options → operatorSnapshot keepers (real snapshot rows).
//   · Gate pending count → gateData.approval_queue length.
// Gaps (no live signal, design option omitted): 태스크 인계 요청(handoff) — the
// operator action endpoint has no handoff action type; keeper-scoped pause/resume
// goes through the keeper directive API on Monitor → Keeper Fleet, not this form.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { operatorActionBusy, operatorSnapshot } from '../../operator-store'
import { gateData } from '../gate-store'
import { showToast } from '../common/toast'
import { replaceRoute } from '../../router'
import { executeAction } from './helpers'

type CmdAction = 'broadcast' | 'keeper_message' | 'namespace_pause' | 'namespace_resume'

const CMD_ACTIONS: { value: CmdAction; label: string }[] = [
  { value: 'broadcast', label: '브로드캐스트 · 전체' },
  { value: 'keeper_message', label: 'keeper 직접 메시지' },
  { value: 'namespace_pause', label: '일시정지' },
  { value: 'namespace_resume', label: '재개' },
]

const FLEET_TARGET = 'fleet'

export function CmdInterveneForm() {
  const [action, setAction] = useState<CmdAction>('keeper_message')
  const [target, setTarget] = useState<string>(FLEET_TARGET)
  const [message, setMessage] = useState('')
  const keepers = operatorSnapshot.value?.keepers ?? []
  const busy = operatorActionBusy.value

  const send = async () => {
    const body = message.trim()
    if (!body || busy) return
    let result: unknown = null
    if (action === 'keeper_message') {
      if (target === FLEET_TARGET) {
        showToast('keeper 직접 메시지는 대상 keeper 를 선택해야 합니다.', 'warning')
        return
      }
      result = await executeAction({
        action_type: 'keeper_message',
        target_type: 'keeper',
        target_id: target,
        payload: { message: body },
        successMessage: 'keeper 메시지를 전달했습니다.',
      })
    } else if (action === 'broadcast') {
      result = await executeAction({
        action_type: 'broadcast',
        target_type: 'workspace',
        payload: { message: body },
        successMessage: '브로드캐스트를 전송했습니다.',
      })
    } else {
      if (target !== FLEET_TARGET) {
        showToast('keeper 개별 일시정지/재개는 Monitor → Keeper Fleet 에서 실행하세요.', 'warning')
        return
      }
      result = await executeAction({
        action_type: action,
        target_type: 'workspace',
        payload: { reason: body },
        successMessage: action === 'namespace_pause'
          ? '네임스페이스를 일시정지했습니다.'
          : '네임스페이스를 재개했습니다.',
      })
    }
    if (result) setMessage('')
  }

  return html`
    <section class="lab-panel" data-testid="cmd-intervene-form">
      <h4>개입 · Intervene</h4>
      <div class="cmd-form">
        <label class="lab-f"><span>action</span>
          <select
            value=${action}
            onChange=${(e: Event) => setAction((e.target as HTMLSelectElement).value as CmdAction)}
          >
            ${CMD_ACTIONS.map(({ value, label }) => html`<option key=${value} value=${value}>${label}</option>`)}
          </select>
        </label>
        <label class="lab-f"><span>target</span>
          <select
            value=${target}
            onChange=${(e: Event) => setTarget((e.target as HTMLSelectElement).value)}
          >
            <option value=${FLEET_TARGET}>Fleet · 전체</option>
            ${keepers.map(keeper => html`<option key=${keeper.name} value=${keeper.name}>${keeper.name}</option>`)}
          </select>
        </label>
        <textarea
          class="cmd-text"
          rows=${4}
          placeholder="대상에게 전달할 내용…"
          value=${message}
          onInput=${(e: Event) => setMessage((e.target as HTMLTextAreaElement).value)}
        ></textarea>
        <div class="cmd-actions">
          <button class="lab-run" disabled=${!message.trim() || busy} onClick=${send}>실행</button>
          <span class="mono dim">되돌릴 수 없는 행동 지시는 Gate 로 라우팅됩니다</span>
        </div>
      </div>
    </section>
  `
}

export function CmdGateLinks() {
  const pending = gateData.value?.approval_queue?.length ?? 0
  return html`
    <section class="lab-panel" data-testid="cmd-gate-links">
      <h4>Gate / HITL</h4>
      <p class="ia-note">이 view 는 Gate surface 와 같은 컴포넌트입니다. 비계층 3모드(Always Allow · LLM Auto Judge · HITL)와 exact Always 규칙은 Gate 에서 관리합니다.</p>
      <div class="cmd-gatelinks">
        <button
          class="tm-lane"
          onClick=${() => replaceRoute('command', { section: 'operations', view: 'gate' })}
        >
          <span class="tm-lane-t">Gate 열기${pending > 0 ? ` · 대기 ${pending}` : ''}</span>
          <span class="tm-lane-m">approvals · nonblocking HITL 큐 + exact Always 규칙</span>
          <span class="tm-lane-o mono">Open</span>
        </button>
      </div>
    </section>
  `
}
