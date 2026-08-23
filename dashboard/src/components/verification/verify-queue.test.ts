import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { cleanup, render, screen, fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { VerificationRequestsResponse } from '../../api/dashboard-misc'
import type { Task } from '../../types'
import { goals, keepers, tasks } from '../../store'

// ── Mock async-state ──────────────────────────────────

const mockState = signal({
  loading: false,
  error: null as string | null,
  data: null as VerificationRequestsResponse | null,
})
const mockLoad = vi.fn()

vi.mock('../../lib/async-state', () => ({
  createManagedAsyncResource: () => ({
    state: mockState,
    load: mockLoad,
    cancel: vi.fn(),
  }),
}))

// ── Mock API ──────────────────────────────────────────

vi.mock('../../api/dashboard-misc', () => ({
  fetchVerificationRequests: vi.fn(),
}))

const submitVerificationVerdict = vi.fn()
vi.mock('../../api/dashboard-verification-verdict', () => ({
  submitVerificationVerdict: (...args: unknown[]) => submitVerificationVerdict(...args),
}))

// ── Mock router ───────────────────────────────────────

const navigateMock = vi.fn()
vi.mock('../../router', () => ({
  navigate: (...args: unknown[]) => navigateMock(...args),
}))

import { VerifyQueue } from './verify-queue'

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'task-1',
    title: 'compact lock 재진입 수정',
    status: 'awaiting_verification',
    priority: 9,
    assignee: 'sangsu',
    goal_id: 'goal-1',
    contract: {
      completion_contract: ['open_fds 회귀 (41 유지)', 'scheduler 스위트 84/84'],
    },
    ...overrides,
  }
}

function requestsResponse(rows: Partial<VerificationRequestsResponse['requests'][number]>[] = []): VerificationRequestsResponse {
  return {
    updated_at: '2026-08-23T05:00:00Z',
    total: rows.length,
    requests: rows.map((row, i) => ({
      request_id: `vr-${i}`,
      task_id: 'task-1',
      task_title: 'compact lock 재진입 수정',
      request_kind: 'normal',
      request_summary: '',
      next_action: null,
      created_at: '2026-08-23T04:50:00Z',
      submitted_by: 'sangsu',
      completion_contract: [],
      required_artifacts: [],
      submitted_evidence: [],
      evidence_projection_error: null,
      ...row,
    })),
  }
}

function confirmAllGateRows(container: Element) {
  const rows = container.querySelectorAll('.vq-gate-row')
  rows.forEach(row => fireEvent.click(row))
}

beforeEach(() => {
  mockState.value = { loading: false, error: null, data: requestsResponse() }
  mockLoad.mockReset()
  submitVerificationVerdict.mockReset()
  submitVerificationVerdict.mockResolvedValue({ ok: true, message: 'committed', noop: false })
  navigateMock.mockReset()
  tasks.value = []
  goals.value = []
  keepers.value = []
})

afterEach(() => {
  cleanup()
  tasks.value = []
  goals.value = []
  keepers.value = []
})

describe('VerifyQueue', () => {
  it('renders the empty treatment when nothing awaits verification', () => {
    const { container } = render(html`<${VerifyQueue} />`)
    expect(container.querySelector('.vq-clear')).toBeTruthy()
    expect(screen.getByText('검증 대기 요청이 없습니다')).toBeTruthy()
    expect(container.querySelector('.vq-bar-t')?.textContent).toBe('검증 요청 큐')
    expect(container.querySelector('.vq-bar-lane')?.textContent).toBe('검증 레인')
  })

  it('renders stack cards from awaiting_verification tasks with gate rows from the contract', () => {
    tasks.value = [makeTask()]
    goals.value = [{ id: 'goal-1', title: 'p99 SLO 회복', priority: 9, phase: 'executing', created_at: '', updated_at: '' }]
    const { container } = render(html`<${VerifyQueue} />`)

    expect(container.querySelector('.vq-card')).toBeTruthy()
    expect(container.querySelector('.vq-req-id')?.textContent).toBe('task-1 · P9')
    expect(container.querySelector('.vq-req-title')?.textContent).toBe('compact lock 재진입 수정')
    expect(container.querySelector('.vq-req-goal')?.textContent).toContain('p99 SLO 회복')

    const rows = container.querySelectorAll('.vq-gate-row')
    expect(rows.length).toBe(2)
    expect(rows[0]?.querySelector('.vq-gate-ev')?.textContent).toBe('open_fds 회귀 (41 유지)')
    expect(rows[0]?.querySelector('.vq-gate-out')?.textContent).toBe('미지원')
    expect(container.querySelector('.vq-gate-h .n')?.textContent).toBe('0/2 확인')
  })

  it('gates 승인 behind operator confirmation of every gate row, then commits the verdict', async () => {
    tasks.value = [makeTask()]
    const { container } = render(html`<${VerifyQueue} />`)

    const approve = screen.getByText('✓ 승인 · 통과') as HTMLButtonElement
    expect(approve.disabled).toBe(true)

    confirmAllGateRows(container)
    expect(container.querySelector('.vq-gate-h .n')?.textContent).toBe('2/2 확인')
    expect(approve.disabled).toBe(false)
    expect(container.querySelector('.vq-card.pinned')).toBeTruthy()

    fireEvent.click(approve)
    await waitFor(() => {
      expect(submitVerificationVerdict).toHaveBeenCalledWith({ taskId: 'task-1', decision: 'approve' })
    })
    await waitFor(() => {
      expect(container.querySelector('.vq-verdict.approved')).toBeTruthy()
    })
    expect(container.querySelector('.vq-verdict-body')?.textContent).toContain('승인 · 통과')
    expect(container.querySelector('.vq-verdict-body')?.textContent).toContain('task → done')
    // resolved task leaves the queue; empty treatment appears
    expect(container.querySelector('.vq-clear')).toBeTruthy()
  })

  it('collects a reject reason via chips and commits a reject verdict', async () => {
    tasks.value = [makeTask()]
    const { container } = render(html`<${VerifyQueue} />`)

    fireEvent.click(screen.getByText('✕ 반려'))
    expect(container.querySelector('.vq-form')).toBeTruthy()
    fireEvent.click(screen.getByText('게이트 증거 미충족'))
    const textarea = container.querySelector('.vq-form textarea') as HTMLTextAreaElement
    expect(textarea.value).toBe('게이트 증거 미충족')

    fireEvent.click(screen.getByText('✕ 반려하고 반송'))
    await waitFor(() => {
      expect(submitVerificationVerdict).toHaveBeenCalledWith({
        taskId: 'task-1',
        decision: 'reject',
        reason: '게이트 증거 미충족',
      })
    })
    await waitFor(() => {
      expect(container.querySelector('.vq-verdict.rejected')).toBeTruthy()
    })
    expect(container.querySelector('.vq-verdict-body')?.textContent).toContain('“게이트 증거 미충족”')
  })

  it('surfaces mutation errors inline and keeps the task in the queue', async () => {
    submitVerificationVerdict.mockRejectedValue(new Error('Task task-1 is done; operator evidence and verdicts require awaiting_verification'))
    tasks.value = [makeTask()]
    const { container } = render(html`<${VerifyQueue} />`)

    confirmAllGateRows(container)
    fireEvent.click(screen.getByText('✓ 승인 · 통과'))
    await waitFor(() => {
      expect(container.querySelector('[role="alert"]')?.textContent).toContain('awaiting_verification')
    })
    expect(container.querySelector('.vq-card')).toBeTruthy()
    expect(container.querySelector('.vq-verdict')).toBeFalsy()
  })

  it('renders evidence projection failure as a failed gate row and bad stat', () => {
    tasks.value = [makeTask()]
    mockState.value = {
      loading: false,
      error: null,
      data: requestsResponse([{ evidence_projection_error: 'snapshot decode failed' }]),
    }
    const { container } = render(html`<${VerifyQueue} />`)

    const rows = container.querySelectorAll('.vq-gate-row')
    expect(rows.length).toBe(3)
    expect(rows[0]?.querySelector('.vq-gate-out')?.textContent).toBe('실패')
    expect(container.querySelector('.vq-bar-stat.bad')?.textContent).toContain('1 증거 실패')
  })

  it('falls back to the request contract when the task carries none, and shows the submit memo', () => {
    tasks.value = [makeTask({ contract: null })]
    mockState.value = {
      loading: false,
      error: null,
      data: requestsResponse([{
        completion_contract: ['p99 측정 < 400ms'],
        request_summary: 'open_fds·스위트 통과 · p99 측정 남음',
      }]),
    }
    const { container } = render(html`<${VerifyQueue} />`)

    expect(container.querySelector('.vq-gate-ev')?.textContent).toBe('p99 측정 < 400ms')
    const notes = [...container.querySelectorAll('.vq-note')].map(n => n.textContent)
    expect(notes.some(t => t?.includes('제출 메모 · open_fds·스위트 통과 · p99 측정 남음'))).toBe(true)
    const submitted = [...container.querySelectorAll('.vq-submitted')].map(n => n.textContent)
    expect(submitted.some(t => t?.includes('제출'))).toBe(true)
  })

  it('renders a rerun note and handoff note from task fields', () => {
    tasks.value = [makeTask({
      predecessor_task_id: 'task-0',
      handoff_context: { summary: 'compact 경로 소유 인계', next_step: 'operator 승인 후 머지' },
    })]
    const { container } = render(html`<${VerifyQueue} />`)

    expect(container.querySelector('.vq-note.rerun')?.textContent).toContain('task-0')
    const notes = [...container.querySelectorAll('.vq-note')].map(n => n.textContent)
    expect(notes.some(t => t?.includes('핸드오프 · compact 경로 소유 인계 → operator 승인 후 머지'))).toBe(true)
  })

  it('links the submitter to the keeper surface when the actor is a known keeper', () => {
    keepers.value = [{ name: 'sangsu', status: 'running' }]
    tasks.value = [makeTask()]
    const { container } = render(html`<${VerifyQueue} />`)

    const sub = container.querySelector('.vq-sub') as HTMLButtonElement
    expect(sub).toBeTruthy()
    expect(sub.textContent).toContain('sangsu')
    fireEvent.click(sub)
    expect(navigateMock).toHaveBeenCalledWith('monitoring', { section: 'agents', view: 'keepers', keeper: 'sangsu' })
  })

  it('jumps to the owning goal from the goal link', () => {
    tasks.value = [makeTask()]
    goals.value = [{ id: 'goal-1', title: 'p99 SLO 회복', priority: 9, phase: 'executing', created_at: '', updated_at: '' }]
    render(html`<${VerifyQueue} />`)

    fireEvent.click(screen.getByText('↳ p99 SLO 회복'))
    expect(navigateMock).toHaveBeenCalledWith('workspace', { section: 'planning', goal: 'goal-1' })
  })

  it('switches to the split layout with master list and detail', () => {
    tasks.value = [makeTask(), makeTask({ id: 'task-2', title: '두 번째 요청', priority: 3 })]
    const { container } = render(html`<${VerifyQueue} />`)

    fireEvent.click(screen.getByText('분할 검토'))
    expect(container.querySelector('.vq.vq-lay-split')).toBeTruthy()
    const rows = container.querySelectorAll('.vq-splitrow')
    expect(rows.length).toBe(2)
    expect(container.querySelector('.vq-detail .vq-req-title')?.textContent).toBe('compact lock 재진입 수정')

    fireEvent.click(rows[1] as HTMLElement)
    expect(container.querySelector('.vq-detail .vq-req-title')?.textContent).toBe('두 번째 요청')
  })

  it('switches to the triage layout and expands a card for gate review', () => {
    tasks.value = [makeTask()]
    const { container } = render(html`<${VerifyQueue} />`)

    fireEvent.click(screen.getByText('트리아지'))
    expect(container.querySelector('.vq.vq-lay-triage')).toBeTruthy()
    expect(container.querySelector('.vq-tri')).toBeTruthy()
    expect(container.querySelector('.vq-tri-gate-n')?.textContent).toBe('0/2')
    expect(container.querySelector('.vq-gate')).toBeFalsy()

    fireEvent.click(screen.getByText('게이트 증거 검토 →'))
    expect(container.querySelector('.vq-tri .vq-gate')).toBeTruthy()
    expect(screen.getByText('↑ 접기')).toBeTruthy()

    fireEvent.click(screen.getByText('↑ 접기'))
    expect(container.querySelector('.vq-tri .vq-gate')).toBeFalsy()
  })

  it('omits the goal link when the task has no goal', () => {
    tasks.value = [makeTask({ goal_id: null })]
    const { container } = render(html`<${VerifyQueue} />`)
    expect(container.querySelector('.vq-req-goal')).toBeFalsy()
  })
})
