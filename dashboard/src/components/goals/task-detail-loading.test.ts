import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { act } from 'preact/test-utils'
import type { Task } from '../../types'

vi.mock('../../api/actions', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/actions')>(),
  fetchTaskEvents: vi.fn().mockResolvedValue([]),
  fetchTaskDetail: vi.fn(),
}))
vi.mock('../../api/dashboard', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/dashboard')>(),
  fetchAgentTimeline: vi.fn(),
}))
import { fetchAgentTimeline } from '../../api/dashboard'
import { fetchTaskDetail } from '../../api/actions'
import { selectedTask } from './task-detail-selection'
import { closeTaskDetail, openTaskDetail, retryTaskDetails, taskDetailsState, switchToActivityTab, activeTab, activityError, activityLoading, activityEvents } from './task-detail-state'
import { TaskDetailOverlay } from './task-detail-overlay'

function pending<T>() {
  let resolve!: (value: T) => void
  let reject!: (error: Error) => void
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
const summary = (id: string): Task => ({ id, title: id, detail_level: 'summary' })
const complete = (id: string): Task => ({ id, title: id, detail_level: 'full', description: 'complete description' })
const settle = async () => { await Promise.resolve(); await Promise.resolve() }
let host: HTMLDivElement
beforeEach(() => {
  vi.mocked(fetchTaskDetail).mockReset()
  vi.mocked(fetchAgentTimeline).mockReset()
  closeTaskDetail()
  host = document.createElement('div')
  document.body.append(host)
})
afterEach(() => { render(null, host); host.remove(); closeTaskDetail() })

describe('task details loaded on demand', () => {
  it('keeps complete rows immediate and avoids another request', () => {
    openTaskDetail(complete('a'))
    expect(fetchTaskDetail).not.toHaveBeenCalled()
    expect(taskDetailsState.value.kind).toBe('ready')
  })
  it('renders loading, visible failure and retry before complete details', async () => {
    const first = pending<Task>()
    vi.mocked(fetchTaskDetail).mockReturnValueOnce(first.promise).mockResolvedValueOnce(complete('a'))
    await act(async () => { openTaskDetail(summary('a')); render(html`<${TaskDetailOverlay} />`, host) })
    expect(host.textContent).toContain('작업 상세 불러오는 중')
    await act(async () => { first.reject(new Error('service unavailable')); await settle() })
    expect(host.textContent).toContain('service unavailable')
    const retry = [...host.querySelectorAll('button')].find(x => x.textContent === '다시 시도')
    expect(retry).toBeTruthy()
    await act(async () => { retry!.click(); await settle() })
    expect(selectedTask.value?.description).toBe('complete description')
    await vi.waitFor(() => expect(host.textContent).toContain('complete description'))
    expect(taskDetailsState.value.kind).toBe('ready')
  })
  it('ignores old responses after switching, closing and reopening the same id', async () => {
    const old = pending<Task>()
    const newer = pending<Task>()
    vi.mocked(fetchTaskDetail).mockReturnValueOnce(old.promise).mockReturnValueOnce(newer.promise)
    openTaskDetail(summary('a'))
    closeTaskDetail()
    openTaskDetail(summary('a'))
    old.resolve({ ...complete('a'), description: 'stale' })
    await settle()
    expect(taskDetailsState.value.kind).toBe('loading')
    expect(selectedTask.value?.description).toBeUndefined()
    newer.resolve(complete('a'))
    await settle()
    expect(selectedTask.value?.description).toBe('complete description')
    const late = pending<Task>()
    vi.mocked(fetchTaskDetail).mockReturnValueOnce(late.promise)
    openTaskDetail(summary('b'))
    openTaskDetail(complete('c'))
    late.reject(new Error('stale failure'))
    await settle()
    expect(selectedTask.value?.id).toBe('c')
    expect(taskDetailsState.value.kind).toBe('ready')
  })
  it.each(['assignee-b', undefined])('waits for full assignee %s before activity', async assignee => {
    const detail = pending<Task>()
    const row = { ...summary('a'), assignee: 'assignee-a' }
    vi.mocked(fetchTaskDetail).mockReturnValueOnce(detail.promise)
    vi.mocked(fetchAgentTimeline).mockReturnValue(new Promise(() => {}))
    await act(async () => { openTaskDetail(row); render(html`<${TaskDetailOverlay} />`, host) })
    const activity = [...host.querySelectorAll('button')].find(x => x.textContent === '담당자 최근 활동')!
    expect(activity.disabled).toBe(true)
    switchToActivityTab(row)
    expect(activeTab.value).toBe('overview')
    expect(fetchAgentTimeline).not.toHaveBeenCalled()
    await act(async () => { detail.resolve({ ...complete('a'), assignee }); await settle() })
    expect(activeTab.value).toBe('overview')
    await vi.waitFor(() => expect(host.textContent).toContain('complete description'))
    // Even a stale callback carrying summary A must use the current full row.
    switchToActivityTab(row)
    if (assignee) {
      expect(fetchAgentTimeline).toHaveBeenCalledWith(assignee, 24, 200)
      expect(activeTab.value).toBe('activity')
    } else {
      expect(fetchAgentTimeline).not.toHaveBeenCalled()
      expect(activeTab.value).toBe('overview')
      expect(host.textContent).not.toContain('담당자 최근 활동')
    }
  })
  it('discards activity from the previous assignee while full detail arrives', async () => {
    const timeline = pending<Awaited<ReturnType<typeof fetchAgentTimeline>>>()
    vi.mocked(fetchAgentTimeline).mockReturnValueOnce(timeline.promise)
    const old = { ...complete('a'), assignee: 'assignee-a' }
    openTaskDetail(old)
    switchToActivityTab(old)
    expect(activityLoading.value).toBe(true)
    const detail = pending<Task>()
    vi.mocked(fetchTaskDetail).mockReturnValueOnce(detail.promise)
    openTaskDetail({ ...summary('a'), assignee: 'assignee-a' })
    detail.resolve({ ...complete('a'), assignee: undefined })
    await settle()
    timeline.reject(new Error('stale assignee failure'))
    await settle()
    expect(activeTab.value).toBe('overview')
    expect(activityLoading.value).toBe(false)
    expect(activityError.value).toBeNull()
    expect(activityEvents.value).toEqual([])
  })
  it('does not submit duplicate retry while loading', () => {
    vi.mocked(fetchTaskDetail).mockReturnValue(new Promise(() => {}))
    openTaskDetail(summary('a'))
    retryTaskDetails()
    expect(fetchTaskDetail).toHaveBeenCalledTimes(1)
  })
})
