import { get } from './core'

export interface NativeCursor {
  version: 1
  scope_id: string
  sequence: number
}

export interface NativeCall {
  call_id: string
  runtime_id: string
  trace_id: string
}

export interface NativeCallPage {
  execution_operation_id: string
  calls: NativeCall[]
  next_after_call_id: string | null
}

export type NativeNodeKind = 'agent_run' | 'agent_turn' | 'provider_attempt'
  | 'output_block' | 'tool_invocation' | 'tool_attempt'

export type NativePayload =
  | { kind: 'node_opened'; node_id: string; run_id: string; parent_node_id: string | null
      node: { kind: NativeNodeKind; label: string } }
  | { kind: 'node_updated'; node_id: string; update_kind: string; data: unknown }
  | { kind: 'node_closed'; node_id: string; terminal: { kind: 'succeeded' | 'failed' | 'cancelled'; detail: string | null } }

export interface NativeEvent {
  event_id: string
  run_id: string
  correlation_id: string
  seq: number
  parent_event_id: string | null
  payload: NativePayload
}

export interface NativeEventPage {
  execution_operation_id: string
  call_id: string
  events: NativeEvent[]
  next_cursor: NativeCursor
  high_watermark: NativeCursor
  has_more: boolean
}

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error('실행 이력 응답이 올바르지 않습니다.')
  return value as Record<string, unknown>
}

function text(value: unknown): string {
  if (typeof value !== 'string' || value.length === 0) throw new Error('실행 이력 식별자가 올바르지 않습니다.')
  return value
}

function nullableText(value: unknown): string | null {
  return value === null ? null : text(value)
}

function ordinal(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) throw new Error('실행 이력 순서가 올바르지 않습니다.')
  return value
}

function array(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error('실행 이력 목록이 올바르지 않습니다.')
  return value
}

function cursor(value: unknown): NativeCursor {
  const obj = record(value)
  if (obj.version !== 1 || Object.keys(obj).length !== 3) throw new Error('실행 이력 커서를 읽을 수 없습니다.')
  return { version: 1, scope_id: text(obj.scope_id), sequence: ordinal(obj.sequence) }
}

function payload(value: unknown): NativePayload {
  const obj = record(value)
  const node_id = text(obj.node_id)
  switch (obj.kind) {
    case 'node_opened': {
      const node = record(obj.node)
      let label: string
      switch (node.kind) {
        case 'agent_run': label = text(node.agent_name); break
        case 'agent_turn': label = `턴 ${ordinal(node.ordinal)}`; break
        case 'provider_attempt': label = `모델 호출 ${ordinal(node.ordinal)}`; break
        case 'output_block': label = '응답'; break
        case 'tool_invocation': label = text(node.tool_name); break
        case 'tool_attempt': label = '도구 실행'; break
        default: throw new Error('알 수 없는 실행 노드입니다.')
      }
      return { kind: 'node_opened', node_id, run_id: text(obj.run_id), parent_node_id: nullableText(obj.parent_node_id),
        node: { kind: node.kind, label } }
    }
    case 'node_updated':
      return { kind: 'node_updated', node_id, update_kind: text(obj.update_kind), data: obj.data }
    case 'node_closed': {
      const terminal = record(obj.terminal)
      if (terminal.kind !== 'succeeded' && terminal.kind !== 'failed' && terminal.kind !== 'cancelled') throw new Error('알 수 없는 실행 결과입니다.')
      return { kind: 'node_closed', node_id, terminal: { kind: terminal.kind,
        detail: typeof terminal.detail === 'string' ? terminal.detail : typeof terminal.reason === 'string' ? terminal.reason : null } }
    }
    default: throw new Error('알 수 없는 실행 이벤트입니다.')
  }
}

function basePath(keeper: string, operation: string): string {
  return `/api/v1/keepers/${encodeURIComponent(keeper)}/chat/operations/${encodeURIComponent(operation)}/native-calls`
}

export async function fetchNativeCalls(keeper: string, operation: string, after: string | null, signal?: AbortSignal): Promise<NativeCallPage> {
  const params = new URLSearchParams({ limit: '50' })
  if (after !== null) params.set('after_call_id', after)
  const obj = record(await get<unknown>(`${basePath(keeper, operation)}?${params}`, { signal, consumeWithinTimeout: true }))
  if (obj.schema !== 'masc.native_execution_calls.v1' || obj.operation_id !== operation) throw new Error('다른 요청의 실행 이력이 도착했습니다.')
  const calls = array(obj.calls).map(raw => {
    const call = record(raw)
    return { call_id: text(call.call_id), runtime_id: text(call.runtime_id), trace_id: text(call.trace_id) }
  })
  if (new Set(calls.map(call => call.call_id)).size !== calls.length) throw new Error('실행 호출 식별자가 중복됐습니다.')
  const next_after_call_id = nullableText(obj.next_after_call_id)
  if (next_after_call_id !== null && next_after_call_id !== calls.at(-1)?.call_id) throw new Error('실행 이력 페이지가 연결되지 않습니다.')
  return { execution_operation_id: text(obj.execution_operation_id), calls, next_after_call_id }
}

export async function fetchNativeEvents(keeper: string, operation: string, call: string,
  after: NativeCursor | null, through: NativeCursor | null, signal?: AbortSignal): Promise<NativeEventPage> {
  const params = new URLSearchParams({ limit: '200' })
  if (after !== null) params.set('after', JSON.stringify(after))
  if (through !== null) params.set('through', JSON.stringify(through))
  const obj = record(await get<unknown>(`${basePath(keeper, operation)}/${encodeURIComponent(call)}/events?${params}`, { signal, consumeWithinTimeout: true }))
  if (obj.schema !== 'masc.native_execution_events.v1' || obj.operation_id !== operation || obj.call_id !== call) throw new Error('다른 호출의 실행 이력이 도착했습니다.')
  const next_cursor = cursor(obj.next_cursor)
  const high_watermark = cursor(obj.high_watermark)
  if (next_cursor.scope_id !== high_watermark.scope_id || next_cursor.sequence > high_watermark.sequence
    || (after !== null && (after.scope_id !== next_cursor.scope_id || next_cursor.sequence < after.sequence))
    || (through !== null && (through.scope_id !== high_watermark.scope_id || through.sequence !== high_watermark.sequence))) throw new Error('실행 이력 커서 범위가 달라졌습니다.')
  let previous = after?.sequence ?? 0
  const events = array(obj.events).map(raw => {
    const event = record(raw)
    const seq = ordinal(event.seq)
    if (seq <= previous || seq > next_cursor.sequence) throw new Error('실행 이력 순서가 바뀌었습니다.')
    previous = seq
    return { event_id: text(event.event_id), run_id: text(event.run_id), correlation_id: text(event.correlation_id),
      seq, parent_event_id: nullableText(event.parent_event_id), payload: payload(event.payload) }
  })
  if (typeof obj.has_more !== 'boolean'
    || obj.has_more !== (next_cursor.sequence < high_watermark.sequence)
    || (obj.has_more && next_cursor.sequence <= (after?.sequence ?? 0))) throw new Error('실행 이력 페이지 범위가 올바르지 않습니다.')
  return { execution_operation_id: text(obj.execution_operation_id), call_id: call, events, next_cursor, high_watermark, has_more: obj.has_more }
}
