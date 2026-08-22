import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { render } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { html } from 'htm/preact'
import { KeeperConversationPanel } from '../components/keeper-shared'
import { setStoredToken } from '../api/core'
import { shellAuthSummary } from '../store'

const KEEPER = 'sangsu'
const FIXTURE_STATE_KEY = 'masc.keeper-operation-e2e.v1'

type FixtureOperationState =
  | { kind: 'Queued' }
  | { kind: 'Running'; startedAt: number }
  | { kind: 'Succeeded'; completedAt: number; outcomeRef: string }
  | {
      kind: 'Failed'
      completedAt: number
      failureKind: string
      detail: string
      outcomeRef: string | null
    }
  | { kind: 'Cancelled'; completedAt: number }

type FixtureOperation = {
  operationId: string
  sequence: number
  createdAt: number
  input: Record<string, unknown> | null
  state: FixtureOperationState
}

type FixtureState = {
  nextSequence: number
  operations: FixtureOperation[]
}

const streamControllers = new Map<string, ReadableStreamDefaultController<Uint8Array>>()
const encoder = new TextEncoder()

function emptyState(): FixtureState {
  return { nextSequence: 1, operations: [] }
}

function loadState(): FixtureState {
  try {
    const raw = sessionStorage.getItem(FIXTURE_STATE_KEY)
    if (!raw) return emptyState()
    const parsed = JSON.parse(raw) as FixtureState
    return Array.isArray(parsed.operations) && Number.isSafeInteger(parsed.nextSequence)
      ? parsed
      : emptyState()
  } catch {
    return emptyState()
  }
}

let fixtureState = loadState()

function persistState(): void {
  sessionStorage.setItem(FIXTURE_STATE_KEY, JSON.stringify(fixtureState))
  window.dispatchEvent(new CustomEvent('keeper-operation-fixture-change'))
}

function operationWire(operation: FixtureOperation): Record<string, unknown> {
  const common: Record<string, unknown> = {
    schema: 'masc.keeper_chat_operation.v1',
    operation_id: operation.operationId,
    sequence: String(operation.sequence),
    created_at: operation.createdAt,
    input: operation.input,
    state: operation.state.kind,
  }
  switch (operation.state.kind) {
    case 'Queued':
      return common
    case 'Running':
      return { ...common, started_at: operation.state.startedAt }
    case 'Succeeded':
      return {
        ...common,
        completed_at: operation.state.completedAt,
        outcome_ref: operation.state.outcomeRef,
      }
    case 'Failed':
      return {
        ...common,
        completed_at: operation.state.completedAt,
        failure_kind: operation.state.failureKind,
        failure_detail: operation.state.detail,
        outcome_ref: operation.state.outcomeRef,
      }
    case 'Cancelled':
      return { ...common, completed_at: operation.state.completedAt }
  }
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function requestPath(input: RequestInfo | URL): string {
  const raw = input instanceof Request ? input.url : String(input)
  const url = new URL(raw, window.location.origin)
  return `${url.pathname}${url.search}`
}

function requestMethod(input: RequestInfo | URL, init?: RequestInit): string {
  if (typeof init?.method === 'string') return init.method.toUpperCase()
  return input instanceof Request ? input.method.toUpperCase() : 'GET'
}

async function requestJson(input: RequestInfo | URL, init?: RequestInit): Promise<Record<string, unknown>> {
  const body = init?.body ?? (input instanceof Request ? await input.clone().text() : null)
  if (typeof body !== 'string' || body.trim() === '') return {}
  return JSON.parse(body) as Record<string, unknown>
}

function queueCount(): number {
  return fixtureState.operations.filter(operation => operation.state.kind === 'Queued').length
}

function waitingInventory(): Record<string, unknown> {
  const running = fixtureState.operations.find(operation => operation.state.kind === 'Running')
  const queued = fixtureState.operations.filter(operation => operation.state.kind === 'Queued')
  const waitingOn = [
    ...(running
      ? [{
          keeper_name: KEEPER,
          source: 'chat_operation_running',
          waiting_on: 'keeper_turn',
          wake_producer: 'keeper_owner_actor',
          next_action: 'keeper_owner_settle_operation',
          detail: { operation_id: running.operationId },
        }]
      : []),
    ...queued.map(operation => ({
      keeper_name: KEEPER,
      source: 'chat_operation_queued',
      waiting_on: 'owner_fifo',
      wake_producer: 'keeper_owner_actor',
      next_action: 'keeper_owner_start_fifo_head',
      detail: { operation_id: operation.operationId },
    })),
  ]
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v3',
    source: 'server_keeper_waiting_inventory',
    generated_at: new Date().toISOString(),
    supported_states: ['idle', 'busy', 'waiting', 'deferred'],
    keeper_count_known: true,
    keeper_count: 1,
    waiting_keeper_count: waitingOn.length > 0 ? 1 : 0,
    row_count: waitingOn.length,
    keepers: [{
      keeper_name: KEEPER,
      state: running ? 'busy' : queued.length > 0 ? 'waiting' : 'idle',
      waiting_count: waitingOn.length,
      waiting_on: waitingOn,
    }],
  }
}

function emit(operationId: string, event: Record<string, unknown>): void {
  const controller = streamControllers.get(operationId)
  if (!controller) throw new Error(`No live stream for ${operationId}`)
  controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`))
}

function startHead(): void {
  const head = fixtureState.operations
    .filter(operation => operation.state.kind === 'Queued')
    .sort((left, right) => left.sequence - right.sequence)[0]
  if (!head) return
  head.state = { kind: 'Running', startedAt: Date.now() / 1000 }
  persistState()
  emit(head.operationId, { type: 'RUN_STARTED', runId: `run-${head.operationId}` })
  emit(head.operationId, { type: 'CUSTOM', name: 'KEEPER_STREAM_PING', value: null })
  emit(head.operationId, {
    type: 'CUSTOM',
    name: 'KEEPER_THINKING_DELTA',
    value: { index: 0, delta: '요청 내용을 검토하고 있습니다.' },
  })
  emit(head.operationId, {
    type: 'TOOL_CALL_START',
    toolCallId: `tool-${head.operationId}`,
    toolCallName: 'keeper_context_status',
  })
  emit(head.operationId, {
    type: 'TOOL_CALL_ARGS',
    toolCallId: `tool-${head.operationId}`,
    delta: '{"scope":"current"}',
  })
}

function finishRunning(): void {
  const running = fixtureState.operations.find(operation => operation.state.kind === 'Running')
  if (!running) return
  emit(running.operationId, {
    type: 'TOOL_CALL_END',
    toolCallId: `tool-${running.operationId}`,
  })
  emit(running.operationId, {
    type: 'TEXT_MESSAGE_START',
    messageId: `message-${running.operationId}`,
  })
  emit(running.operationId, {
    type: 'TEXT_MESSAGE_CONTENT',
    messageId: `message-${running.operationId}`,
    delta: '대기 요청도 이제 같은 말풍선에서 실시간으로 답변합니다.',
  })
  emit(running.operationId, {
    type: 'TEXT_MESSAGE_END',
    messageId: `message-${running.operationId}`,
  })
  running.input = null
  running.state = {
    kind: 'Succeeded',
    completedAt: Date.now() / 1000,
    outcomeRef: `turn-${running.operationId}`,
  }
  persistState()
  emit(running.operationId, { type: 'RUN_FINISHED', runId: `run-${running.operationId}` })
  streamControllers.get(running.operationId)?.close()
  streamControllers.delete(running.operationId)
}

function interruptRunningAndReload(): void {
  const running = fixtureState.operations.find(operation => operation.state.kind === 'Running')
  if (!running) return
  running.input = null
  running.state = {
    kind: 'Failed',
    completedAt: Date.now() / 1000,
    failureKind: 'Interrupted_by_restart',
    detail: 'Owner restarted while the operation child was running',
    outcomeRef: null,
  }
  persistState()
  history.replaceState(null, '', window.location.pathname)
  window.location.reload()
}

async function fixtureFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const path = requestPath(input)
  const method = requestMethod(input, init)
  if (path === '/api/v1/dashboard/dev-token' && method === 'GET') {
    return json({ token: 'fixture-token', actor: 'dashboard', role: 'admin' })
  }
  if (path === `/api/v1/keepers/${KEEPER}/chat/history` && method === 'GET') return json([])
  if (path === `/api/v1/keepers/${KEEPER}/waiting-inventory` && method === 'GET') {
    return json(waitingInventory())
  }
  if (path.startsWith(`/api/v1/keepers/${KEEPER}/chat/operations?`) && method === 'GET') {
    const operations = fixtureState.operations
      .filter(operation => operation.state.kind === 'Queued')
      .sort((left, right) => left.sequence - right.sequence)
      .map(operationWire)
    return json({
      schema: 'masc.keeper_chat_operations.list.v1',
      state: 'Queued',
      operations,
    })
  }
  if (path === '/api/v1/keepers/chat/stream' && method === 'POST') {
    const body = await requestJson(input, init)
    const operationId = String(body.request_id ?? '')
    const message = String(body.message ?? '')
    const operation: FixtureOperation = {
      operationId,
      sequence: fixtureState.nextSequence++,
      createdAt: Date.now() / 1000,
      input: {
        schema: 'masc.keeper_chat_operation.input.v1',
        message,
        user_blocks: Array.isArray(body.user_blocks)
          ? body.user_blocks
          : [{ type: 'text', text: message }],
        turn_instructions: null,
        surface_context: null,
        attachments: [],
      },
      state: { kind: 'Queued' },
    }
    fixtureState.operations.push(operation)
    persistState()
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        streamControllers.set(operationId, controller)
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({
          type: 'CUSTOM',
          name: 'KEEPER_CHAT_OPERATION_ACCEPTED',
          value: {
            operation_id: operationId,
            state: 'Queued',
            queued_count: queueCount(),
          },
        })}\n\n`))
      },
      cancel() {
        streamControllers.delete(operationId)
      },
    })
    return new Response(stream, {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    })
  }
  const operationMatch = path.match(
    new RegExp(`^/api/v1/keepers/${KEEPER}/chat/operations/([^/?]+)(?:/(edit|move-to-end|cancel))?$`),
  )
  if (operationMatch) {
    const operationId = decodeURIComponent(operationMatch[1] ?? '')
    const action = operationMatch[2]
    const operation = fixtureState.operations.find(candidate => candidate.operationId === operationId)
    if (!operation) return json({ error: 'unknown_operation' }, 404)
    if (!action && method === 'GET') return json(operationWire(operation))
    if (method !== 'POST' || operation.state.kind !== 'Queued') {
      return json({ error: 'not_queued' }, 409)
    }
    if (action === 'edit') {
      const body = await requestJson(input, init)
      operation.input = body.input as Record<string, unknown>
    } else if (action === 'move-to-end') {
      operation.sequence = fixtureState.nextSequence++
    } else if (action === 'cancel') {
      operation.input = null
      operation.state = { kind: 'Cancelled', completedAt: Date.now() / 1000 }
      streamControllers.get(operationId)?.close()
      streamControllers.delete(operationId)
    }
    persistState()
    return json(operationWire(operation))
  }
  if (path.includes('/tool-call') || path.includes('/tool-calls')) return json([])
  return json({ error: `Unhandled fixture request: ${method} ${path}` }, 404)
}

window.fetch = fixtureFetch
setStoredToken('fixture-admin-token', { source: 'manual' })
shellAuthSummary.value = {
  enabled: true,
  require_token: true,
  token_present: true,
  token_valid: true,
  token_agent: 'dashboard',
  requested_agent: 'dashboard',
  effective_agent: 'dashboard',
  effective_role: 'admin',
  auth_error_code: null,
  auth_error_detail: null,
  can_keeper_msg: true,
  keeper_msg_error: null,
}

function OperationFixtureStatus() {
  const [, setVersion] = useState(0)
  useEffect(() => {
    const update = () => setVersion(version => version + 1)
    window.addEventListener('keeper-operation-fixture-change', update)
    return () => window.removeEventListener('keeper-operation-fixture-change', update)
  }, [])
  const states = fixtureState.operations.map(operation => operation.state.kind)
  const interrupted = fixtureState.operations.filter(operation => (
    operation.state.kind === 'Failed'
    && operation.state.failureKind === 'Interrupted_by_restart'
  )).length
  return html`
    <div class="mb-3 flex flex-wrap gap-2" data-testid="fixture-operation-status">
      <strong>Operation lane</strong>
      <span>Queued ${states.filter(state => state === 'Queued').length}</span>
      <span>Running ${states.filter(state => state === 'Running').length}</span>
      <span>Succeeded ${states.filter(state => state === 'Succeeded').length}</span>
      <span>Cancelled ${states.filter(state => state === 'Cancelled').length}</span>
      <span>Interrupted ${interrupted}</span>
    </div>
  `
}

function KeeperChatOperationFixture() {
  return html`
    <main class="min-h-screen px-4 py-6" style="background: var(--bg-deep);" data-queued-stream-fixture>
      <section class="mx-auto max-w-[1000px]">
        <h1 class="mb-3 text-xl font-semibold" style="color: var(--text-main);">
          Keeper operation stream contract
        </h1>
        <${OperationFixtureStatus} />
        <div class="mb-3 flex flex-wrap gap-2">
          <button data-testid="fixture-start-head" type="button" onClick=${startHead}>FIFO head 실행</button>
          <button data-testid="fixture-finish-running" type="button" onClick=${finishRunning}>Running 완료</button>
          <button data-testid="fixture-restart-running" type="button" onClick=${interruptRunningAndReload}>Running 중 재시작</button>
        </div>
        <${KeeperConversationPanel}
          keeperName=${KEEPER}
          placeholder="Keeper에게 메시지"
          layout="primary"
        />
      </section>
    </main>
  `
}

if (new URLSearchParams(window.location.search).has('reset')) {
  sessionStorage.removeItem(FIXTURE_STATE_KEY)
  localStorage.clear()
  fixtureState = emptyState()
  persistState()
}

const root = document.getElementById('app')
if (root) render(html`<${KeeperChatOperationFixture} />`, root)
