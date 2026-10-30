import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useTaskSearchText, TaskSearchFeedback } from './task-search-text'
import { filterTasksByQuery } from '../goals/goal-helpers'
import * as api from '../../api/task-search-text'
import type { Task } from '../../types'

const rev = 'a'.repeat(64)
const summary: Task = { id: 'task-1', title: 'Task', detail_level: 'summary', description: 'preview', description_revision: rev }
function Harness({ tasks, query }: { tasks: Task[]; query: string }) {
  const state = useTaskSearchText(tasks, query)
  return state.kind === 'ready'
    ? h('div', { 'data-testid': 'matches' }, filterTasksByQuery(state.tasks, query).map(task => task.id).join(','))
    : h(TaskSearchFeedback, { state })
}
const documents = (description: string, revision = rev) => new Map([['task-1', { id: 'task-1', description, description_revision: revision }]])
afterEach(() => { cleanup(); vi.restoreAllMocks() })

describe('deferred task search', () => {
  it('does not fetch without a query or when rows already contain full text', () => {
    const fetch = vi.spyOn(api, 'fetchTaskSearchText')
    const view = render(h(Harness, { tasks: [summary], query: '' }))
    view.rerender(h(Harness, { tasks: [{ ...summary, detail_level: 'full' }], query: 'preview' }))
    expect(screen.getByTestId('matches').textContent).toBe('task-1')
    expect(fetch).not.toHaveBeenCalled()
  })

  it('finds distant Unicode text and excludes unrelated IDs', async () => {
    const rows = documents('x'.repeat(65536) + ' 끝단 Σİß')
    rows.set('other', { id: 'other', description: '끝단', description_revision: rev })
    const fetch = vi.spyOn(api, 'fetchTaskSearchText').mockResolvedValue(rows)
    const view = render(h(Harness, { tasks: [summary], query: '끝단' }))
    await vi.waitFor(() => expect(screen.getByTestId('matches').textContent).toBe('task-1'))
    view.rerender(h(Harness, { tasks: [summary], query: 'σi\u0307ß' }))
    expect(screen.getByTestId('matches').textContent).toBe('task-1')
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('reuses ready text after row reorder and clearing then reentering search', async () => {
    const second = { ...summary, id: 'task-2', title: 'Second task' }
    const rows = documents('match')
    rows.set(second.id, { id: second.id, description: 'match', description_revision: rev })
    const fetch = vi.spyOn(api, 'fetchTaskSearchText').mockResolvedValue(rows)
    const view = render(h(Harness, { tasks: [summary, second], query: 'match' }))
    await vi.waitFor(() => expect(screen.getByTestId('matches').textContent).toBe('task-1,task-2'))
    view.rerender(h(Harness, { tasks: [second, summary], query: 'match' }))
    expect(screen.getByTestId('matches').textContent).toBe('task-2,task-1')
    view.rerender(h(Harness, { tasks: [second, summary], query: '' }))
    expect(screen.getByTestId('matches').textContent).toBe('task-2,task-1')
    view.rerender(h(Harness, { tasks: [second, summary], query: 'match' }))
    await new Promise(resolve => requestAnimationFrame(resolve))
    expect(screen.getByTestId('matches').textContent).toBe('task-2,task-1')
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  it('reports a missing required document instead of using preview text', async () => {
    vi.spyOn(api, 'fetchTaskSearchText').mockResolvedValue(new Map())
    render(h(Harness, { tasks: [summary], query: 'preview' }))
    await vi.waitFor(() => expect(screen.getByRole('alert')).toBeTruthy())
    expect(screen.queryByTestId('matches')).toBeNull()
  })

  it('shows errors rather than an empty result and retries', async () => {
    const fetch = vi.spyOn(api, 'fetchTaskSearchText').mockRejectedValueOnce(new Error('offline'))
      .mockResolvedValueOnce(documents('match'))
    render(h(Harness, { tasks: [summary], query: 'match' }))
    await vi.waitFor(() => expect(screen.getByRole('alert')).toBeTruthy())
    expect(screen.queryByTestId('matches')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: '검색 다시 시도' }))
    await vi.waitFor(() => expect(screen.getByTestId('matches').textContent).toBe('task-1'))
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('does not search text from a different description revision', async () => {
    vi.spyOn(api, 'fetchTaskSearchText').mockResolvedValue(documents('match', 'b'.repeat(64)))
    render(h(Harness, { tasks: [summary], query: 'match' }))
    await vi.waitFor(() => expect(screen.getByRole('alert')).toBeTruthy())
    expect(screen.queryByTestId('matches')).toBeNull()
  })

  it('discards an old response after the task revision changes', async () => {
    let finish!: (value: ReturnType<typeof documents>) => void
    const old = new Promise<ReturnType<typeof documents>>(resolve => { finish = resolve })
    const fetch = vi.spyOn(api, 'fetchTaskSearchText').mockReturnValueOnce(old)
      .mockResolvedValueOnce(documents('current', 'b'.repeat(64)))
    const view = render(h(Harness, { tasks: [summary], query: 'current' }))
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(1))
    view.rerender(h(Harness, { tasks: [{ ...summary, description_revision: 'b'.repeat(64) }], query: 'current' }))
    await vi.waitFor(() => expect(screen.getByTestId('matches').textContent).toBe('task-1'))
    finish(documents('obsolete'))
    await old
    await new Promise(resolve => requestAnimationFrame(resolve))
    expect(screen.getByTestId('matches').textContent).toBe('task-1')
  })
})
