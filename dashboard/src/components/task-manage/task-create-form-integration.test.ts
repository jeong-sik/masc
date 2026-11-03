// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  callMcpToolAtIdentity: vi.fn(),
  showToast: vi.fn(),
  refreshExecution: vi.fn(),
  refreshGoals: vi.fn(),
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool: mocks.callMcpTool,
  callMcpToolAtIdentity: mocks.callMcpToolAtIdentity,
  mcpCallFailureDisposition: () => 'outcome_unknown',
}))
vi.mock('../common/toast', () => ({ showToast: mocks.showToast }))
vi.mock('../../store', () => ({ refreshExecution: mocks.refreshExecution, refreshGoals: mocks.refreshGoals }))

import { TaskCreateForm, resetForm } from './task-create-form'
import { showTaskCreate, taskCreating } from './task-manage-state'

function inputDraft(title: string, description: string, priority: string) {
  const titleInput = screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement
  const descriptionInput = screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement
  const priorityInput = screen.getByRole('combobox') as HTMLSelectElement
  fireEvent.input(titleInput, { target: { value: title } })
  fireEvent.input(descriptionInput, { target: { value: description } })
  priorityInput.value = priority
  fireEvent(priorityInput, new Event('change', { bubbles: true }))
}

describe('Task creation draft ownership', () => {
  beforeEach(() => {
    showTaskCreate.value = false
    taskCreating.value = false
    resetForm()
    vi.resetAllMocks()
    mocks.refreshExecution.mockResolvedValue(undefined)
    mocks.refreshGoals.mockResolvedValue(undefined)
  })

  afterEach(() => {
    cleanup()
    showTaskCreate.value = false
    resetForm()
  })

  it('finishes the submitted draft after a successful current request', async () => {
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true }
    mocks.callMcpToolAtIdentity.mockResolvedValueOnce(undefined)
    render(html`<${TaskCreateForm} goalId="goal-a" goalDispatch=${dispatch} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Submitted task', 'Submitted detail', '2')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))

    await waitFor(() => expect(showTaskCreate.value).toBe(false))
    expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mocks.showToast).toHaveBeenCalledWith('태스크 생성 완료', 'success')
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('3')
  })

  it('keeps the new Goal draft when an earlier Goal creation succeeds late', async () => {
    let resolveCreate!: () => void
    let firstIsCurrent = true
    const first = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => firstIsCurrent }
    const second = { ...first, isCurrent: () => true }
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<void>(resolve => { resolveCreate = resolve }))
    const view = render(html`<${TaskCreateForm} goalId="goal-a" goalDispatch=${first} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('First request', 'First detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())

    firstIsCurrent = false
    view.rerender(html`<${TaskCreateForm} goalId="goal-b" goalDispatch=${second} />`)
    inputDraft('New draft', 'New detail', '2')
    resolveCreate()
    await waitFor(() => expect(taskCreating.value).toBe(false))

    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('New draft')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('New detail')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('2')
    expect(showTaskCreate.value).toBe(true)
    expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
  })

  it('keeps a reopened draft even when the original Goal is still current', async () => {
    let resolveCreate!: () => void
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true }
    mocks.callMcpToolAtIdentity.mockImplementationOnce(() => new Promise<void>(resolve => { resolveCreate = resolve }))
    render(html`<${TaskCreateForm} goalId="goal-a" goalDispatch=${dispatch} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Same text', 'Same detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce())

    fireEvent.click(screen.getByRole('button', { name: '취소' }))
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Same text', 'Same detail', '1')
    resolveCreate()
    await waitFor(() => expect(taskCreating.value).toBe(false))

    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('Same text')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('Same detail')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('1')
    expect(showTaskCreate.value).toBe(true)
    expect(mocks.callMcpToolAtIdentity).toHaveBeenCalledOnce()
    expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
  })

  it('keeps the shared draft after navigating from Planning to a Goal', async () => {
    let resolveCreate!: () => void
    mocks.callMcpTool.mockImplementationOnce(() => new Promise<void>(resolve => { resolveCreate = resolve }))
    const planning = render(html`<${TaskCreateForm} />`)
    fireEvent.click(screen.getByRole('button', { name: '태스크 추가' }))
    await screen.findByPlaceholderText('예: runtime config introspection 정리')
    inputDraft('Planning task', 'Planning detail', '1')
    fireEvent.click(screen.getByRole('button', { name: 'backlog에 추가' }))
    await waitFor(() => expect(mocks.callMcpTool).toHaveBeenCalledOnce())

    planning.unmount()
    const dispatch = { workspace: { basePath: '/a', mascRoot: '/a/.masc' },
      identity: { revision: 1, actor: 'dashboard' }, isCurrent: () => true }
    render(html`<${TaskCreateForm} goalId="goal-a" goalDispatch=${dispatch} />`)
    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('Planning task')
    resolveCreate()
    await waitFor(() => expect(taskCreating.value).toBe(false))

    expect((screen.getByPlaceholderText('예: runtime config introspection 정리') as HTMLInputElement).value).toBe('Planning task')
    expect((screen.getByPlaceholderText(/배경, 재현 조건/) as HTMLTextAreaElement).value).toBe('Planning detail')
    expect((screen.getByRole('combobox') as HTMLSelectElement).value).toBe('1')
    expect(showTaskCreate.value).toBe(true)
    expect(mocks.callMcpTool).toHaveBeenCalledOnce()
    expect(mocks.showToast).toHaveBeenCalledWith(expect.stringContaining('이전 요청'), 'warning')
  })
})
