import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { shellAuthSummary, tasks } from '../../store'
import { navigate } from '../../router'
import { callMcpTool } from '../../api/mcp'
import { requestConfirm } from '../common/confirm-dialog'
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

vi.mock('../../router', () => ({
  navigate: vi.fn(),
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool: vi.fn().mockResolvedValue('{"before_tokens":1000,"after_tokens":800,"phase_after":"Running"}'),
}))

vi.mock('../common/confirm-dialog', () => ({
  requestConfirm: vi.fn().mockResolvedValue(true),
}))

function mkKeeper(partial: Partial<Keeper>): Keeper {
  return { name: 'masc-improver', status: 'running', ...partial } as Keeper
}
function mkTask(partial: Partial<Task>): Task {
  return { id: 'T-0', title: 'task', ...partial } as Task
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
  shellAuthSummary.value = null
  vi.clearAllMocks()
})

describe('KeeperWorkspaceRail', () => {
  const keeper = mkKeeper({
    active_model_label: 'sonnet-4.6',
    runtime_canonical: 'oas·seoul-1',
    context_ratio: 0.62,
    context_tokens: 124000,
    context_max: 200000,
    compaction_profile: 'balanced',
    compaction_ratio_gate: 0.72,
    compaction_message_gate: 120,
    recent_tool_names: ['masc_amplitude_query', 'masc_board_metrics'],
  })

  it('renders the runtime / throughput vitals', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('런타임 · 처리량')
    expect(container.textContent).toContain('sonnet-4.6')
    expect(container.textContent).toContain('oas·seoul-1')
  })

  it('hides the model cell when no model was reported', () => {
    const k = mkKeeper({ runtime_canonical: 'runpod_gemma' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('런타임 · 처리량')
    expect(container.textContent).toContain('runpod_gemma')
    expect(container.textContent).not.toContain('모델')
    expect(container.textContent).not.toContain('—')
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

  it('opens the planning task detail when an owned task is clicked', () => {
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    fireEvent.click(getByRole('button', { name: /태스크 열기: T-4412/ }))
    expect(navigate).toHaveBeenCalledWith('workspace', { section: 'planning', task: 'T-4412' })
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

  it('uses explicit attention reason text instead of a vague maintenance label', () => {
    const k = mkKeeper({ needs_attention: true, attention_reason: 'approval_pending', next_human_action: 'resolve_approval' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('approval_pending · resolve_approval')
    expect(container.textContent).not.toContain('점검이 필요합니다')
  })

  it('labels unqualified attention flags as missing cause data', () => {
    const k = mkKeeper({ needs_attention: true })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('runtime_attention.needs_attention=true · 원인/조치 미수신')
    expect(container.textContent).not.toContain('점검이 필요합니다')
  })

  it('renders the auto-compact threshold label', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('compact 72%')
    expect(container.textContent).toContain('ratio_gate 72%')
    expect(container.textContent).toContain('profile balanced')
    expect(container.textContent).toContain('message_gate 120')
  })

  it('renders context metrics as missing when only a zero default exists', () => {
    const k = mkKeeper({ context_ratio: 0, compaction_count: 0, last_compaction_ago_s: 0 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('컨텍스트 사용량 미수신')
    expect(container.textContent).toContain('컴팩트 기록 없음')
    expect(container.textContent).not.toContain('윈도우 사용량')
    expect(container.querySelector('.kw-meter')).toBeNull()
    expect(container.textContent).not.toContain('마지막 컴팩트 0초 전')
    const button = container.querySelector('.kw-compact-btn') as HTMLButtonElement | null
    expect(button).not.toBeNull()
    expect(button?.disabled).toBe(true)
  })

  it('shows token-only context without a fake window percentage', () => {
    const k = mkKeeper({ context_ratio: 0, context_tokens: 37800 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('윈도우 사용률 미수신')
    expect(container.textContent).toContain('37.8k')
    expect(container.textContent).not.toContain('윈도우 사용량')
    expect(container.querySelector('.kw-meter')).toBeNull()
    expect(container.textContent).toContain('compact ratio_gate는 50%입니다')
  })

  it('runs overflow compaction without force through the existing MCP tool', async () => {
    shellAuthSummary.value = { effective_role: 'worker', default_role: 'worker' } as typeof shellAuthSummary.value
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${mkKeeper({ ...keeper, phase: 'Overflowed' })} onToggleDetail=${() => {}} />`)
    fireEvent.click(getByRole('button', { name: '지금 compact' }))

    await waitFor(() => {
      expect(callMcpTool).toHaveBeenCalledWith('masc_keeper_compact', {
        name: 'masc-improver',
        force: false,
      })
    })
    expect(requestConfirm).not.toHaveBeenCalled()
  })

  it('confirms before forcing compaction on running keepers', async () => {
    shellAuthSummary.value = { effective_role: 'worker', default_role: 'worker' } as typeof shellAuthSummary.value
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${mkKeeper({ ...keeper, phase: 'Running' })} onToggleDetail=${() => {}} />`)
    fireEvent.click(getByRole('button', { name: '지금 compact' }))

    await waitFor(() => {
      expect(requestConfirm).toHaveBeenCalledWith(expect.objectContaining({
        title: 'Force keeper compact',
        confirmText: 'Force compact',
      }))
      expect(callMcpTool).toHaveBeenCalledWith('masc_keeper_compact', {
        name: 'masc-improver',
        force: true,
      })
    })
  })

  it('does not compact running keepers when force confirmation is cancelled', async () => {
    vi.mocked(requestConfirm).mockResolvedValueOnce(false)
    shellAuthSummary.value = { effective_role: 'worker', default_role: 'worker' } as typeof shellAuthSummary.value
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${mkKeeper({ ...keeper, phase: 'Running' })} onToggleDetail=${() => {}} />`)
    fireEvent.click(getByRole('button', { name: '지금 compact' }))

    await waitFor(() => expect(requestConfirm).toHaveBeenCalled())
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('fires onToggleDetail from the 운영 상세 button', () => {
    const onToggle = vi.fn()
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${onToggle} />`)
    const btn = container.querySelector('.kw-detail-btn') as HTMLElement
    expect(btn).toBeTruthy()
    expect(btn.textContent).toContain('운영 상세')
    fireEvent.click(btn)
    expect(onToggle).toHaveBeenCalled()
  })

  it('shows the empty state when no tasks are owned', () => {
    tasks.value = []
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} onToggleDetail=${() => {}} />`)
    expect(container.textContent).toContain('할당된 태스크 없음')
  })
})
