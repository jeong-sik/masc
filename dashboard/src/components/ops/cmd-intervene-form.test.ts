import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { OperatorSnapshot } from '../../types'

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

const { executeAction, showToast, replaceRoute } = vi.hoisted(() => ({
  executeAction: vi.fn(),
  showToast: vi.fn(),
  replaceRoute: vi.fn(),
}))

vi.mock('./helpers', () => ({ executeAction }))
vi.mock('../common/toast', () => ({ showToast }))
vi.mock('../../router', () => ({ replaceRoute }))

import { operatorActionBusy, operatorSnapshot } from '../../operator-store'
import { CmdGateLinks, CmdInterveneForm } from './cmd-intervene-form'

function seedSnapshot(keepers: { name: string }[]): void {
  operatorSnapshot.value = {
    root: { paused: false, namespace: 'default' },
    sessions: [],
    keepers,
    recent_messages: [],
    available_actions: [],
  } as unknown as OperatorSnapshot
}

function setTextarea(container: HTMLElement, value: string): void {
  const textarea = container.querySelector('textarea.cmd-text') as HTMLTextAreaElement
  textarea.value = value
  textarea.dispatchEvent(new Event('input'))
}

function setSelect(container: HTMLElement, selector: string, value: string): void {
  const select = container.querySelector(selector) as HTMLSelectElement
  select.value = value
  select.dispatchEvent(new Event('change'))
}

describe('CmdInterveneForm (keeper-v2 command parity)', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    executeAction.mockReset()
    executeAction.mockResolvedValue({ status: 'ok' })
    showToast.mockReset()
    replaceRoute.mockReset()
    operatorActionBusy.value = false
    seedSnapshot([{ name: 'masc-improver' }, { name: 'nick0cave' }])
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the design vocabulary (cmd-form/cmd-text/cmd-actions/lab-run)', async () => {
    render(html`<${CmdInterveneForm} />`, container)
    await flushUi()

    expect(container.querySelector('.lab-panel h4')?.textContent).toBe('개입 · Intervene')
    expect(container.querySelector('.cmd-form')).not.toBeNull()
    expect(container.querySelectorAll('.cmd-form .lab-f')).toHaveLength(2)
    expect(container.querySelector('textarea.cmd-text')?.getAttribute('placeholder')).toBe('대상에게 전달할 내용…')
    expect(container.querySelector('.cmd-actions .lab-run')?.textContent).toBe('실행하기')
    expect(container.querySelector('.cmd-actions .mono.dim')?.textContent)
      .toBe('되돌릴 수 없는 행동 지시는 Gate 로 라우팅됩니다')

    const options = Array.from(container.querySelectorAll('.cmd-form select option')).map(o => o.textContent)
    expect(options.slice(0, 4)).toEqual([
      '브로드캐스트 · 전체',
      'keeper 직접 메시지',
      '일시정지',
      '재개',
    ])
    // handoff(태스크 인계 요청) has no live operator action type — omitted on purpose.
    expect(options).not.toContain('태스크 인계 요청')
  })

  it('lists snapshot keepers as message targets', async () => {
    render(html`<${CmdInterveneForm} />`, container)
    await flushUi()

    const targetOptions = Array.from(
      container.querySelectorAll('.cmd-form .lab-f:nth-of-type(2) select option'),
    ).map(o => (o as HTMLOptionElement).value)
    expect(targetOptions).toEqual(['fleet', 'masc-improver', 'nick0cave'])
  })

  it('disables 실행 while the message is empty', async () => {
    render(html`<${CmdInterveneForm} />`, container)
    await flushUi()

    const run = container.querySelector('.lab-run') as HTMLButtonElement
    expect(run.disabled).toBe(true)

    setTextarea(container, 'scheduler 재진입 패치 먼저 올려주세요')
    await flushUi()
    expect((container.querySelector('.lab-run') as HTMLButtonElement).disabled).toBe(false)
  })

  it('dispatches keeper_message with the selected keeper target', async () => {
    render(html`<${CmdInterveneForm} />`, container)
    await flushUi()

    setSelect(container, '.cmd-form .lab-f:nth-of-type(2) select', 'masc-improver')
    setTextarea(container, '비용 원장 정리 먼저')
    await flushUi()
    ;(container.querySelector('.lab-run') as HTMLButtonElement).click()
    await flushUi()

    expect(executeAction).toHaveBeenCalledWith({
      action_type: 'keeper_message',
      target_type: 'keeper',
      target_id: 'masc-improver',
      payload: { message: '비용 원장 정리 먼저' },
      successMessage: 'keeper 메시지를 전달했습니다.',
    })
    // Cleared after a successful dispatch.
    expect((container.querySelector('textarea.cmd-text') as HTMLTextAreaElement).value).toBe('')
  })

  it('refuses keeper_message without a keeper target (no fake fleet DM)', async () => {
    render(html`<${CmdInterveneForm} />`, container)
    await flushUi()

    setTextarea(container, '대상 없이 보낼 수 없다')
    await flushUi()
    ;(container.querySelector('.lab-run') as HTMLButtonElement).click()
    await flushUi()

    expect(executeAction).not.toHaveBeenCalled()
    expect(showToast).toHaveBeenCalledWith('keeper 직접 메시지는 대상 keeper 를 선택해야 합니다.', 'warning')
  })

  it('dispatches broadcast to the workspace with payload.message', async () => {
    render(html`<${CmdInterveneForm} />`, container)
    await flushUi()

    setSelect(container, '.cmd-form .lab-f:nth-of-type(1) select', 'broadcast')
    setTextarea(container, '오늘 18:00 배포 창')
    await flushUi()
    ;(container.querySelector('.lab-run') as HTMLButtonElement).click()
    await flushUi()

    expect(executeAction).toHaveBeenCalledWith({
      action_type: 'broadcast',
      target_type: 'workspace',
      payload: { message: '오늘 18:00 배포 창' },
      successMessage: '브로드캐스트를 전송했습니다.',
    })
  })

  it('dispatches namespace_pause with payload.reason on the fleet target', async () => {
    render(html`<${CmdInterveneForm} />`, container)
    await flushUi()

    setSelect(container, '.cmd-form .lab-f:nth-of-type(1) select', 'namespace_pause')
    setTextarea(container, '비용 원장 정리 전까지 정지')
    await flushUi()
    ;(container.querySelector('.lab-run') as HTMLButtonElement).click()
    await flushUi()

    expect(executeAction).toHaveBeenCalledWith({
      action_type: 'namespace_pause',
      target_type: 'workspace',
      payload: { reason: '비용 원장 정리 전까지 정지' },
      successMessage: '네임스페이스를 일시정지했습니다.',
    })
  })

  it('redirects keeper-scoped pause to Monitor instead of pausing the namespace', async () => {
    render(html`<${CmdInterveneForm} />`, container)
    await flushUi()

    setSelect(container, '.cmd-form .lab-f:nth-of-type(1) select', 'namespace_pause')
    setSelect(container, '.cmd-form .lab-f:nth-of-type(2) select', 'nick0cave')
    setTextarea(container, '개별 정지 시도')
    await flushUi()
    ;(container.querySelector('.lab-run') as HTMLButtonElement).click()
    await flushUi()

    expect(executeAction).not.toHaveBeenCalled()
    expect(showToast).toHaveBeenCalledWith(
      'keeper 개별 일시정지/재개는 Monitor → Keeper Fleet 에서 실행하세요.',
      'warning',
    )
  })
})

describe('CmdGateLinks (keeper-v2 command parity)', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    replaceRoute.mockReset()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders cmd-gatelinks with a tm-lane to the gate view', async () => {
    render(html`<${CmdGateLinks} />`, container)
    await flushUi()

    expect(container.querySelector('.lab-panel h4')?.textContent).toBe('Gate / HITL')
    const lane = container.querySelector('.cmd-gatelinks .tm-lane')
    expect(lane).not.toBeNull()
    expect(lane?.querySelector('.tm-lane-t')?.textContent).toBe('Gate 열기')
    expect(lane?.querySelector('.tm-lane-m')?.textContent)
      .toBe('approvals · nonblocking HITL 큐 + exact Always 규칙')
    expect(lane?.querySelector('.tm-lane-o')?.textContent).toBe('Open')
  })

  it('navigates to the gate view on click', async () => {
    render(html`<${CmdGateLinks} />`, container)
    await flushUi()

    ;(container.querySelector('.tm-lane') as HTMLButtonElement).click()
    await flushUi()

    expect(replaceRoute).toHaveBeenCalledWith('command', { section: 'operations', view: 'gate' })
  })
})
