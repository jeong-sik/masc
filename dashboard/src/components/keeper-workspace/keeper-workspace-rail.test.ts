import { render } from 'preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { tasks } from '../../store'
import { KeeperWorkspaceRail } from './keeper-workspace-rail'
import type { Keeper, Task } from '../../types'

function mkKeeper(partial: Partial<Keeper>): Keeper {
  return { name: 'masc-improver', status: 'running', ...partial } as Keeper
}
function mkTask(partial: Partial<Task>): Task {
  return { id: 'T-0', title: 'task', ...partial } as Task
}

let host: HTMLElement

beforeEach(() => {
  tasks.value = [
    mkTask({ id: 'T-4412', title: '세그먼트 리텐션 대시보드', status: 'in_progress', assignee: 'masc-improver' }),
    mkTask({ id: 'T-9999', title: '남의 태스크', status: 'todo', assignee: 'someone-else' }),
  ]
  host = document.createElement('div')
  document.body.appendChild(host)
})

afterEach(() => {
  render(null, host)
  host.remove()
  tasks.value = []
})

describe('KeeperWorkspaceRail', () => {
  const keeper = mkKeeper({
    active_model_label: 'sonnet-4.6',
    runtime_canonical: 'oas·seoul-1',
    context_ratio: 0.62,
    context_tokens: 124000,
    context_max: 200000,
    recent_tool_names: ['masc_amplitude_query', 'masc_board_metrics'],
  })

  it('renders the runtime / throughput vitals', () => {
    render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`, host)
    expect(host.textContent).toContain('런타임 · 처리량')
    expect(host.textContent).toContain('sonnet-4.6')
    expect(host.textContent).toContain('oas·seoul-1')
  })

  it('renders the context-window occupancy percent', () => {
    render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`, host)
    expect(host.textContent).toContain('컨텍스트 점유')
    expect(host.textContent).toContain('62%')
    expect(host.textContent).toContain('124.0k')
  })

  it('lists only the keeper-owned tasks', () => {
    render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`, host)
    expect(host.textContent).toContain('T-4412')
    expect(host.textContent).not.toContain('T-9999')
  })

  it('renders recent tool calls', () => {
    render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`, host)
    expect(host.textContent).toContain('최근 도구 호출')
    expect(host.textContent).toContain('masc_amplitude_query')
  })

  it('renders the attention section from live blocked-task signal', () => {
    const k = mkKeeper({ blocked_task_count: 2 })
    render(html`<${KeeperWorkspaceRail} keeper=${k} onToggleDetail=${() => {}} />`, host)
    expect(host.textContent).toContain('주의')
    expect(host.textContent).toContain('차단된 태스크 2건')
  })

  it('omits the attention section when there is nothing to surface', () => {
    render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`, host)
    expect(host.textContent).not.toContain('차단된 태스크')
  })

  it('renders the auto-compact threshold label', () => {
    render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`, host)
    expect(host.textContent).toContain('compact 85%')
  })

  it('fires onToggleDetail from the 상세 보기 button', () => {
    const onToggle = vi.fn()
    render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${onToggle} />`, host)
    const btn = host.querySelector('.kw-detail-btn') as HTMLElement
    expect(btn).toBeTruthy()
    btn.click()
    expect(onToggle).toHaveBeenCalled()
  })

  it('shows the empty state when no tasks are owned', () => {
    tasks.value = []
    render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`, host)
    expect(host.textContent).toContain('할당된 태스크 없음')
  })
})
