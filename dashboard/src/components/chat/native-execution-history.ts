import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { storedTokenRevision } from '../../api/token-revision'
import { ApiRequestError } from '../../api/core'
import { fetchNativeCalls, fetchNativeEvents } from '../../api/keeper-native-history'
import type { NativeCallPage, NativeCursor, NativeEvent, NativeEventPage } from '../../api/keeper-native-history'
import { isAbortError } from '../../lib/async-state'

interface Props { keeper: string; operation: string; turnComplete: boolean }
interface ObservedNode {
  id: string
  parent: string | null
  label: string
  result: 'succeeded' | 'failed' | 'cancelled' | null
  detail: string | null
  data: unknown
}

function observedNodes(events: NativeEvent[]): ObservedNode[] {
  const nodes = new Map<string, ObservedNode>()
  for (const event of events) {
    const payload = event.payload
    if (payload.kind === 'node_opened') {
      if (nodes.has(payload.node_id)) throw new Error('같은 실행 노드가 중복됐습니다.')
      nodes.set(payload.node_id, { id: payload.node_id, parent: payload.parent_node_id,
        label: payload.node.label, result: null, detail: null, data: null })
    } else {
      const node = nodes.get(payload.node_id)
      if (!node) throw new Error('실행 노드의 시작 기록이 없습니다.')
      if (payload.kind === 'node_closed') {
        node.result = payload.terminal.kind
        node.detail = payload.terminal.detail
      } else if (payload.data !== null) {
        node.data = payload.data
      }
    }
  }
  for (const node of nodes.values()) {
    const seen = new Set([node.id])
    let parent = node.parent
    while (parent !== null) {
      if (seen.has(parent)) throw new Error('실행 노드의 상위 관계가 순환합니다.')
      seen.add(parent)
      parent = nodes.get(parent)?.parent ?? null
    }
  }
  return [...nodes.values()]
}

function NodeList({ events }: { events: NativeEvent[] }) {
  const projection = useMemo(() => {
    try { return { nodes: observedNodes(events), error: null } }
    catch (error) { return { nodes: [], error: error instanceof Error ? error.message : String(error) } }
  }, [events])
  if (projection.error) return html`<p role="alert">${projection.error}</p>`
  const byId = new Map(projection.nodes.map(node => [node.id, node]))
  const depth = (node: ObservedNode): number => {
    let parent = node.parent
    let count = 0
    while (parent !== null) {
      const ancestor = byId.get(parent)
      if (!ancestor) break
      count += 1
      parent = ancestor.parent
    }
    return count
  }
  return html`<ol class="m-0 list-none p-0" aria-label="실행 노드">
    ${projection.nodes.map(node => html`<li key=${node.id} class="border-l border-[var(--color-border-default)] py-1"
      style=${{ marginLeft: `${depth(node) * 12}px`, paddingLeft: '8px' }} data-native-node=${node.id}>
      <span class="font-medium">${node.label}</span>
      <span class="ml-2 text-[var(--color-fg-muted)]">${node.result === 'succeeded' ? '완료'
        : node.result === 'failed' ? '실패' : node.result === 'cancelled' ? '취소' : '종료 기록 미수신'}</span>
      ${node.detail ? html`<p class="my-1" role=${node.result === 'failed' ? 'alert' : undefined}>${node.detail}</p>` : null}
      ${node.data !== null ? html`<details><summary>내용 보기</summary><pre class="max-h-64 overflow-auto whitespace-pre-wrap break-words">${JSON.stringify(node.data, null, 2)}</pre></details>` : null}
    </li>`)}
  </ol>`
}

function ScopedHistory({ keeper, operation, turnComplete }: Props) {
  const [open, setOpen] = useState(false)
  const [refresh, setRefresh] = useState(0)
  const [calls, setCalls] = useState<NativeCallPage | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const [callsLoading, setCallsLoading] = useState(false)
  const [callsError, setCallsError] = useState<string | null>(null)
  const [events, setEvents] = useState<NativeEventPage | null>(null)
  const [eventsLoading, setEventsLoading] = useState(false)
  const [eventsError, setEventsError] = useState<string | null>(null)
  const callRequest = useRef<AbortController | null>(null)
  const eventRequest = useRef<AbortController | null>(null)
  const executionLeader = useRef<string | null>(null)
  const errorText = (error: unknown) => error instanceof ApiRequestError
    ? error.detail ?? '실행 이력을 읽지 못했습니다.'
    : error instanceof Error ? error.message : String(error)

  const loadCalls = useCallback(async (after: string | null) => {
    callRequest.current?.abort()
    const controller = new AbortController()
    callRequest.current = controller
    setCallsLoading(true)
    setCallsError(null)
    try {
      const page = await fetchNativeCalls(keeper, operation, after, controller.signal)
      if (controller.signal.aborted) return
      if (after !== null && executionLeader.current !== page.execution_operation_id) throw new Error('실행 이력의 요청 연결이 달라졌습니다.')
      executionLeader.current = page.execution_operation_id
      setCalls(previous => {
        if (after === null) return page
        return { ...page, calls: [...(previous?.calls ?? []), ...page.calls] }
      })
      if (after === null) setSelected(page.calls[0]?.call_id ?? null)
    } catch (error) {
      if (!controller.signal.aborted && !isAbortError(error)) setCallsError(errorText(error))
    } finally {
      if (!controller.signal.aborted) setCallsLoading(false)
    }
  }, [keeper, operation])

  useEffect(() => {
    setCalls(null)
    setSelected(null)
    if (open) void loadCalls(null)
    return () => { callRequest.current?.abort(); eventRequest.current?.abort() }
  }, [open, refresh, turnComplete, loadCalls])

  const execution = calls?.execution_operation_id
  const loadEvents = useCallback(async (after: NativeCursor | null, through: NativeCursor | null) => {
    if (selected === null || execution === undefined) return
    eventRequest.current?.abort()
    const controller = new AbortController()
    eventRequest.current = controller
    setEventsLoading(true)
    setEventsError(null)
    try {
      const page = await fetchNativeEvents(keeper, operation, selected, after, through, controller.signal)
      if (controller.signal.aborted) return
      if (page.execution_operation_id !== execution) throw new Error('실행 이력의 요청 연결이 달라졌습니다.')
      setEvents(previous => after === null ? page : { ...page, events: [...(previous?.events ?? []), ...page.events] })
    } catch (error) {
      if (!controller.signal.aborted && !isAbortError(error)) setEventsError(errorText(error))
    } finally {
      if (!controller.signal.aborted) setEventsLoading(false)
    }
  }, [keeper, operation, selected, execution])

  useEffect(() => {
    setEvents(null)
    if (open) void loadEvents(null, null)
    return () => { eventRequest.current?.abort() }
  }, [open, loadEvents, refresh, turnComplete])

  const currentEvents = events?.call_id === selected ? events : null
  return html`<section class="chat-block-trace ${open ? 'open' : ''}" data-native-execution-history>
    <button type="button" class="chat-block-trace-hd" aria-expanded=${open} onClick=${() => setOpen(value => !value)}>
      <span class="chat-block-trace-chev" aria-hidden="true">${open ? '▾' : '▸'}</span><span class="chat-block-trace-label">Core 실행 이력</span>
    </button>
    ${open ? html`<div class="px-3 pb-3 text-sm">
      <div class="mb-2 flex items-center gap-2"><button type="button" class="btn btn-secondary" onClick=${() => setRefresh(value => value + 1)}>새로 고침</button>
        ${!turnComplete ? html`<span>새 기록은 새로 고침으로 확인할 수 있습니다.</span>` : null}</div>
      ${callsError ? html`<p role="alert">${callsError}</p>` : null}
      ${callsLoading ? html`<p role="status">호출 이력을 읽고 있습니다…</p>` : null}
      ${calls && calls.calls.length === 0 ? html`<p>이 요청에 연결된 Core 호출 기록이 없습니다.</p>` : null}
      ${calls?.calls.length ? html`<label>호출 <select aria-label="실행 호출" value=${selected ?? ''} onChange=${(event: Event) => setSelected((event.currentTarget as HTMLSelectElement).value)}>
        ${calls.calls.map((call, index) => html`<option key=${call.call_id} value=${call.call_id}>${index + 1} · ${call.runtime_id}</option>`)}
      </select></label>` : null}
      ${calls?.next_after_call_id ? html`<button type="button" class="btn btn-secondary ml-2" disabled=${callsLoading} onClick=${() => void loadCalls(calls.next_after_call_id)}>호출 더 읽기</button>` : null}
      ${eventsError ? html`<p role="alert">${eventsError}</p>` : null}
      ${eventsLoading ? html`<p role="status">실행 기록을 읽고 있습니다…</p>` : null}
      ${currentEvents ? html`<${NodeList} events=${currentEvents.events} />
        ${currentEvents.has_more ? html`<button type="button" class="btn btn-secondary mt-2" disabled=${eventsLoading}
          onClick=${() => void loadEvents(currentEvents.next_cursor, currentEvents.high_watermark)}>실행 기록 더 읽기</button>` : html`<p class="mt-2 text-[var(--color-fg-muted)]">관측한 범위의 기록을 모두 읽었습니다.</p>`}` : null}
    </div>` : null}
  </section>`
}

export function NativeExecutionHistory(props: Props) {
  const revision = storedTokenRevision.value
  return html`<${ScopedHistory} key=${JSON.stringify([props.keeper, props.operation, revision])} ...${props} />`
}
