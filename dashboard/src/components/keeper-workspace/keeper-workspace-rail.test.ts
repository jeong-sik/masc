import { cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { tasks } from '../../store'
import { KeeperWorkspaceRail } from './keeper-workspace-rail'
import type { Keeper, Task } from '../../types'

// The recent-tool-calls section now lazy-loads via fetchKeeperToolCalls (rather
// than rendering keeper.recent_tool_names). Stub it so these rail tests never hit
// the network; its rendering is covered directly in keeper-workspace-tool-calls.test.ts.
vi.mock('../../api/dashboard', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api/dashboard')>()
  return {
    ...actual,
    fetchKeeperToolCalls: vi.fn().mockResolvedValue({
      keeper: 'masc-improver',
      count: 0,
      source: 'tool_call_io',
      entries: [],
    }),
  }
})

function mkKeeper(partial: Partial<Keeper>): Keeper {
  return { name: 'masc-improver', status: 'running', ...partial } as Keeper
}
function mkTask(partial: Partial<Task>): Task {
  return { id: 'T-0', title: 'task', ...partial } as Task
}

async function flushPromises(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

beforeEach(() => {
  tasks.value = [
    mkTask({ id: 'T-4412', title: '세그먼트 리텐션 대시보드', status: 'in_progress', assignee: 'masc-improver' }),
    mkTask({ id: 'T-9999', title: '남의 태스크', status: 'todo', assignee: 'someone-else' }),
  ]
})

afterEach(() => {
  cleanup()
  tasks.value = []
  vi.useRealTimers()
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
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('런타임 · 처리량')
    expect(container.textContent).toContain('sonnet-4.6')
    expect(container.textContent).toContain('oas·seoul-1')
  })

  it('renders the context-window occupancy percent', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('컨텍스트 점유')
    expect(container.textContent).toContain('62%')
    expect(container.textContent).toContain('124.0k')
  })

  it('lists only the keeper-owned tasks', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('T-4412')
    expect(container.textContent).not.toContain('T-9999')
  })

  it('renders the attention section from live blocked-task signal', () => {
    const k = mkKeeper({ blocked_task_count: 2 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('주의')
    expect(container.textContent).toContain('차단된 태스크 2건')
  })

  it('omits the attention section when there is nothing to surface', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).not.toContain('차단된 태스크')
  })

  it('renders the auto-compact threshold label', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('compact 85%')
  })

  it('fires onToggleDetail from the 상세 보기 button', () => {
    const onToggle = vi.fn()
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${onToggle} />`)
    const btn = container.querySelector('.kw-detail-btn') as HTMLElement
    expect(btn).toBeTruthy()
    fireEvent.click(btn)
    expect(onToggle).toHaveBeenCalled()
  })

  it('shows the empty state when no tasks are owned', () => {
    tasks.value = []
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('할당된 태스크 없음')
  })

  it('shows the manual compact button in idle state', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    const btn = container.querySelector('.kw-compact-btn') as HTMLButtonElement
    expect(btn).toBeTruthy()
    expect(btn.textContent).toContain('지금 컴팩트')
    expect(btn.disabled).toBe(false)
  })

  it('runs manual compaction, shows busy/done states, and adds a snapshot', async () => {
    vi.useFakeTimers()
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    const btn = container.querySelector('.kw-compact-btn') as HTMLButtonElement

    fireEvent.click(btn)
    expect(container.textContent).toContain('압축 중…')
    expect((container.querySelector('.kw-compact-btn') as HTMLButtonElement).disabled).toBe(true)

    await vi.advanceTimersByTimeAsync(1500)
    await flushPromises()

    expect(container.textContent).toContain('컴팩션 스냅샷')
    expect(container.textContent).toContain('활성 태스크 소유권·상태')
    expect(container.textContent).toContain('초기 분석 turn')
    expect(container.textContent).toContain('중복된 사고')
    expect(container.textContent).toContain('완료')
    // Live ratio override is lower than the original 62%.
    expect(container.textContent).not.toContain('62%')

    await vi.advanceTimersByTimeAsync(2600)
    await flushPromises()

    expect((container.querySelector('.kw-compact-btn') as HTMLButtonElement).textContent).toContain('지금 컴팩트')
  })

  it('accumulates multiple compaction snapshots', async () => {
    vi.useFakeTimers()
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)

    for (let i = 0; i < 2; i++) {
      fireEvent.click(container.querySelector('.kw-compact-btn') as HTMLButtonElement)
      await vi.advanceTimersByTimeAsync(1500)
      await flushPromises()
    }

    expect(container.querySelectorAll('.kw-cmp-snap').length).toBe(2)
  })

  it('resets snapshots and live ratio when the keeper changes', async () => {
    vi.useFakeTimers()
    const { container, rerender } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)

    fireEvent.click(container.querySelector('.kw-compact-btn') as HTMLButtonElement)
    await vi.advanceTimersByTimeAsync(1500)
    await flushPromises()

    expect(container.querySelectorAll('.kw-cmp-snap').length).toBe(1)
    expect(container.textContent).not.toContain('62%')

    const other = mkKeeper({ name: 'other-keeper', context_ratio: 0.3, context_tokens: 60000, context_max: 200000 })
    rerender(html`<${KeeperWorkspaceRail} keeper=${other} onToggleDetail=${() => {}} />`)

    expect(container.querySelectorAll('.kw-cmp-snap').length).toBe(0)
    expect(container.textContent).toContain('30%')
  })
})
