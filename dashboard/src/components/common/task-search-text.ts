import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchTaskSearchText, type TaskSearchDocument } from '../../api/task-search-text'
import type { Task } from '../../types'

export type TaskSearchText =
  | { kind: 'ready'; tasks: readonly Task[] }
  | { kind: 'loading' }
  | { kind: 'error'; retry: () => void }

type RequestState =
  | { key: string; kind: 'loading' }
  | { key: string; kind: 'ready'; documents: Map<string, TaskSearchDocument> }
  | { key: string; kind: 'error' }

export function useTaskSearchText(tasks: readonly Task[], query: string): TaskSearchText {
  const required = query.trim() ? tasks.filter(task => task.detail_level === 'summary') : []
  const key = JSON.stringify(required.map(task => JSON.stringify([task.id, task.description_revision])).sort())
  const [attempt, setAttempt] = useState(0)
  const [request, setRequest] = useState<RequestState | null>(null)
  useEffect(() => {
    if (required.length === 0 || (request?.kind === 'ready' && request.key === key)) return
    let cancelled = false
    setRequest({ key, kind: 'loading' })
    void fetchTaskSearchText().then(documents => {
      const complete = required.every(task => {
        const document = documents.get(task.id)
        return document && task.description_revision === document.description_revision
      })
      if (!cancelled) setRequest(complete ? { key, kind: 'ready', documents } : { key, kind: 'error' })
    }).catch(() => { if (!cancelled) setRequest({ key, kind: 'error' }) })
    return () => { cancelled = true }
  }, [key, attempt])
  if (required.length === 0) return { kind: 'ready', tasks }
  if (request?.key !== key || request.kind === 'loading') return { kind: 'loading' }
  if (request.kind === 'error') return { kind: 'error', retry: () => setAttempt(value => value + 1) }
  return { kind: 'ready', tasks: tasks.map(task => task.detail_level === 'summary'
    ? { ...task, description: request.documents.get(task.id)!.description } : task) }
}

export function TaskSearchFeedback({ state }: { state: TaskSearchText }) {
  if (state.kind === 'ready') return null
  if (state.kind === 'loading') return html`<div role="status">전체 설명에서 검색하는 중...</div>`
  return html`<div role="alert">검색 데이터를 확인하지 못했습니다. 목록을 새로고침한 뒤 다시 시도하세요.
    <button type="button" onClick=${state.retry}>검색 다시 시도</button></div>`
}
