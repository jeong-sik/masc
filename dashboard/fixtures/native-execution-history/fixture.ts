import { h, render } from 'preact'
import { ChatTranscript } from '../../src/components/chat/primitives'
import { operationDeliveryProvenance } from '../../src/keeper-delivery-provenance'
import type { KeeperConversationEntry } from '../../src/types'
import '../../src/styles/ds-theme-tokens.css'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/chat-blocks-v2.css'
import '../../src/styles/skin-v2.css'

// Synthetic transport fixture. Renders the actual conversation consumer;
// it does not stand in for an executed Core journal or installed server.
const operation = 'fixture-completed-operation'
const call = '019a0010-1000-7000-8000-000000000001'
const retry = '019a0010-1000-7000-8000-000000000002'
const cursor = (scope: string, sequence: number) => ({ version: 1, scope_id: scope, sequence })
const opened = (node_id: string, parent_node_id: string | null, node: object, run_id = call) => ({ kind: 'node_opened', node_id, run_id, parent_node_id, node })
const closed = (node_id: string) => ({ kind: 'node_closed', node_id, terminal: { kind: 'succeeded' } })
const payloads = [
  opened('root', null, { kind: 'agent_run', agent_name: '일정 정리' }),
  opened('turn', 'root', { kind: 'agent_turn', ordinal: 1 }),
  opened('tool', 'turn', { kind: 'tool_invocation', tool_name: 'calendar_save' }),
  { kind: 'node_updated', node_id: 'tool', update_kind: 'tool_result', data: { type: 'tool_result', tool_use_id: 'calendar-1', content: '회의 일정을 저장했습니다.' } },
  closed('tool'), closed('turn'), closed('root'),
]
const requests: string[] = []
Object.assign(window, { nativeHistoryFixtureRequests: requests })
window.fetch = async (input) => {
  const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url, location.href)
  requests.push(url.pathname + url.search)
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
  if (url.pathname.endsWith('/native-calls')) return json({ schema: 'masc.native_execution_calls.v1', operation_id: operation, execution_operation_id: operation,
    calls: [{ call_id: call, runtime_id: 'native.primary', trace_id: 'original-trace' }, { call_id: retry, runtime_id: 'native.secondary', trace_id: 'later-trace' }], next_after_call_id: null })
  if (url.pathname.endsWith('/events') && url.pathname.includes('/native-calls/')) {
    if (new URLSearchParams(location.search).has('missing')) return json({ error: 'journal_missing', message: '저장된 실행 기록을 찾을 수 없습니다.' }, 404)
    const selected = url.pathname.includes(retry) ? retry : call
    const after = url.searchParams.has('after') ? JSON.parse(url.searchParams.get('after')!).sequence : 0
    const source = selected === call ? payloads : [opened('retry-root', null, { kind: 'agent_run', agent_name: '다음 모델에서 이어진 호출' }, retry), closed('retry-root')]
    const end = Math.min(source.length, after + 3)
    const events = source.slice(after, end).map((payload, index) => ({ event_id: `${selected}-event-${after + index + 1}`, run_id: selected,
      correlation_id: `${selected}-correlation`, seq: after + index + 1, parent_event_id: null, payload }))
    return json({ schema: 'masc.native_execution_events.v1', operation_id: operation, execution_operation_id: operation, call_id: selected,
      events, next_cursor: cursor(selected, end), high_watermark: cursor(selected, source.length), has_more: end < source.length })
  }
  throw new Error(`Unexpected fixture request: ${url.pathname}`)
}
const entries: KeeperConversationEntry[] = [
  { id: 'fixture-user', role: 'user', source: 'direct_user', label: '운영자', text: '다음 회의 일정을 정리하고 저장해 줘.', delivery: 'delivered',
    deliveryProvenance: operationDeliveryProvenance(operation, 'accepted_user') },
  { id: 'fixture-answer', role: 'assistant', source: 'direct_assistant', label: 'Keeper', text: '회의 일정을 저장했습니다.', delivery: 'delivered',
    deliveryProvenance: operationDeliveryProvenance(operation, 'terminal_result') },
]
render(h('div', null,
  h('p', null, '합성 응답으로 확인하는 대화 화면 · 실제 서버/실행 검증 아님'),
  h(ChatTranscript, { entries, keeperName: 'fixture-keeper', emptyText: '', groupToolCalls: true, showMetadata: false })), document.getElementById('fixture')!)
