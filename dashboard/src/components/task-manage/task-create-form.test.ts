// @vitest-environment happy-dom
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { TaskCreateForm, resetForm } from './task-create-form'
import { showTaskCreate, taskCreating } from './task-manage-state'

const mockCreateTask = vi.fn()

vi.mock('./task-manage-state', async () => {
  const actual = await vi.importActual<typeof import('./task-manage-state')>('./task-manage-state')
  return {
    ...actual,
    createTask: (...args: any[]) => mockCreateTask(...args),
  }
})

const flush = () => new Promise<void>((r) => setTimeout(() => r(), 10))

describe('TaskCreateForm', () => {
  beforeEach(() => {
    showTaskCreate.value = false
    taskCreating.value = false
    resetForm()
    mockCreateTask.mockReset()
    mockCreateTask.mockResolvedValue(true)
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('renders collapsed state with add button', () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    expect(container.querySelector('.v2-workspace-surface')).not.toBeNull()
    expect(container.textContent).toContain('태스크 추가')
  })

  it('shows backlog priority help text', () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    expect(container.textContent).toContain('P1')
    expect(container.textContent).toContain('가장 높습니다')
  })

  it('expands to full form when showTaskCreate is true', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    await flush()
    expect(container.querySelector('.v2-workspace-surface')).not.toBeNull()
    expect(container.textContent).toContain('새 태스크')
    expect(container.textContent).toContain('backlog에 추가')
    expect(container.textContent).toContain('취소')
  })

  it('has required title input with placeholder', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    await flush()
    const input = container.querySelector('input') as HTMLInputElement
    expect(input).not.toBeNull()
    expect(input.placeholder).toContain('runtime config')
  })

  it('has description textarea', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    await flush()
    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    expect(textarea).not.toBeNull()
  })

  it('has priority select with 4 options', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    await flush()
    const select = container.querySelector('select') as HTMLSelectElement
    expect(select).not.toBeNull()
    expect(select.querySelectorAll('option').length).toBe(4)
  })

  it('disables submit button when title is empty', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    await flush()
    const buttons = container.querySelectorAll('button')
    const submitBtn = Array.from(buttons).find((b) => b.textContent?.includes('backlog에 추가'))
    expect(submitBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('enables submit button after typing title', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    await flush()
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'New Task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    const buttons = container.querySelectorAll('button')
    const submitBtn = Array.from(buttons).find((b) => b.textContent?.includes('backlog에 추가'))
    expect(submitBtn?.hasAttribute('disabled')).toBe(false)
  })

  it('calls createTask with form data on submit', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    await flush()
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'My Task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    const buttons = container.querySelectorAll('button')
    const submitBtn = Array.from(buttons).find((b) => b.textContent?.includes('backlog에 추가'))!
    submitBtn.click()
    await flush()
    expect(mockCreateTask).toHaveBeenCalledOnce()
    expect(mockCreateTask).toHaveBeenCalledWith(
      expect.objectContaining({
        title: 'My Task',
        description: '',
        priority: 3,
      }),
    )
  })

  it('shows loading text while creating', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    taskCreating.value = true
    await flush()
    expect(container.textContent).toContain('추가 중...')
  })

  it('collapses and resets on cancel click', async () => {
    const container = document.createElement('div')
    render(html`<${TaskCreateForm} />`, container)
    showTaskCreate.value = true
    await flush()
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'partial'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flush()
    const buttons = container.querySelectorAll('button')
    const cancelBtn = Array.from(buttons).find((b) => b.textContent?.includes('취소'))!
    cancelBtn.click()
    await flush()
    expect(showTaskCreate.value).toBe(false)
  })
})
