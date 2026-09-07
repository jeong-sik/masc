// MASC Dashboard — Keeper operation messaging and SSE streaming

import { asString, isRecord } from '../components/common/normalize'
import type { KeeperConversationAttachment, KeeperUserInputBlock } from '../types'
import {
  apiRequestErrorFromResponse,
  jsonHeaders,
  post,
  fetchControlPlane,
  fetchWithTimeout,
  fetchJsonWithTimeout,
  DEFAULT_GET_TIMEOUT_MS,
} from './core'
import {
  ensureDevToken,
  refreshDevTokenAfterAuthError,
} from './dev-token'
import type { KeeperChatStreamEvent } from '../lib/keeper-chat-stream-contract'
import type {
  KeeperCompositeSnapshot,
  FleetCompositeSnapshot,
} from './schemas/keeper-composite'
import type { KeeperChatHistoryMessage } from './schemas/keeper-chat-history'
import type {
  KeeperTransition,
  KeeperTransitionsResponse,
} from './schemas/keeper-transitions'

export type {
  KeeperCompositeSnapshot,
  KeeperCompositeInvariants,
  KeeperCompositeMeasurement,
  KeeperLastOutcome,
  KeeperLiveTurn,
  KeeperLastSkip,
  KeeperTurnAttempt,
  KeeperBoardCursor,
  KeeperCompositeExecution,
  KeeperRuntimeAttention,
  KeeperSecretProjection,
  KeeperSecretFileMount,
  KeeperPhaseDiagnosis,
  KeeperPhaseDiagnosisRow,
  KeeperCompositePhase,
  KeeperCompositeTurnPhase,
  KeeperCompositeDecisionStage,
  KeeperCompositeRuntimeState,
  FleetCompositeSnapshot,
} from './schemas/keeper-composite'
export type { KeeperChatHistoryMessage } from './schemas/keeper-chat-history'
export type { KeeperTransition, KeeperTransitionsResponse }

export interface KeeperSandboxContainer {
  id: string
  name: string
  image: string
  status: string
  running: boolean | null
  container_kind: string | null
  network_label: string | null
  owner_pid: number | null
}

export interface KeeperSandboxLiveStatus {
  sandbox_profile: string | null
  configured_network_mode: string | null
  effective_mode: string | null
  managed_container_kind: string | null
  containers: KeeperSandboxContainer[] | null
  container_error: string | null
  why_no_container: string | null
  keeper_last_error: string | null
}

function nullableStringField(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function nullableBooleanField(value: unknown): boolean | null {
  return typeof value === 'boolean' ? value : null
}

function nullableIntegerField(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null
}

function parseKeeperSandboxContainer(value: unknown, index: number): KeeperSandboxContainer {
  if (!isRecord(value)) throw new Error(`sandbox_live.containers[${index}] must be an object`)
  const required = (key: 'id' | 'name' | 'image' | 'status'): string => {
    const field = value[key]
    if (typeof field !== 'string') throw new Error(`sandbox_live.containers[${index}].${key} is required`)
    return field
  }
  return {
    id: required('id'),
    name: required('name'),
    image: required('image'),
    status: required('status'),
    running: nullableBooleanField(value.running),
    container_kind: nullableStringField(value.container_kind),
    network_label: nullableStringField(value.network_label),
    owner_pid: nullableIntegerField(value.owner_pid),
  }
}

export function parseKeeperSandboxLiveStatus(value: unknown): KeeperSandboxLiveStatus {
  if (!isRecord(value)) throw new Error('keeper status must be an object')
  if (!isRecord(value.sandbox_live)) throw new Error('keeper status has no sandbox_live observation')
  const live = value.sandbox_live
  let containers: KeeperSandboxContainer[] | null
  if (live.containers == null) {
    containers = null
  } else if (Array.isArray(live.containers)) {
    containers = live.containers.map(parseKeeperSandboxContainer)
  } else {
    throw new Error('sandbox_live.containers must be an array or null')
  }
  return {
    sandbox_profile: nullableStringField(live.sandbox_profile),
    configured_network_mode: nullableStringField(live.configured_network_mode),
    effective_mode: nullableStringField(live.effective_mode),
    managed_container_kind: nullableStringField(live.managed_container_kind),
    containers,
    container_error: nullableStringField(live.container_error),
    why_no_container: nullableStringField(live.why_no_container),
    keeper_last_error: nullableStringField(value.keeper_last_error),
  }
}

export async function fetchKeeperSandboxLiveStatus(
  name: string,
  opts?: { signal?: AbortSignal },
): Promise<KeeperSandboxLiveStatus> {
  const path = `/api/v1/gate/keeper-status?name=${encodeURIComponent(name)}`
  const resp = await fetchWithTimeout(
    path,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw await apiRequestErrorFromResponse('GET', path, resp)
  return parseKeeperSandboxLiveStatus(await resp.json())
}

// --- Runtime trace evidence (split to keeper-runtime-trace.ts) ---
export type {
  KeeperRuntimeTraceTurnIdentity,
  KeeperRuntimeTraceEventBusSummary,
  KeeperRuntimeTraceMemorySummary,
  KeeperRuntimeLensTurnClock,
  KeeperRuntimeLensLifecycleAxis,
  KeeperRuntimeLensProviderLaneAxis,
  KeeperRuntimeLensPayloadRoleAxis,
  KeeperRuntimeLensSourceClockAxis,
  KeeperRuntimeLensConfigDriftAxis,
  KeeperRuntimeLensContextAxis,
  KeeperRuntimeLensMemoryAxis,
  KeeperRuntimeLensAxes,
  KeeperRuntimeLensLaneEvent,
  KeeperRuntimeLensLane,
  KeeperRuntimeLensSwimlanes,
  KeeperRuntimeLensGap,
  KeeperRuntimeLensClockEdgeLinks,
  KeeperRuntimeLensClockEdge,
  KeeperRuntimeLensClockGroup,
  KeeperRuntimeLens,
  KeeperRuntimeTraceLinkedArtifact,
  KeeperRuntimeTraceLinkedArtifacts,
  KeeperRuntimeTraceResponse,
} from './keeper-runtime-trace'
export {
  parseKeeperRuntimeTrace,
  fetchKeeperRuntimeTrace,
} from './keeper-runtime-trace'

// --- Keeper lifecycle (split to keeper-lifecycle.ts) ---
export type {
  KeeperCheckpointCurrentError,
  KeeperCheckpointHistoryError,
  KeeperCheckpointSummary,
  KeeperCheckpointInventory,
  BulkKeeperDirectiveAction,
  BulkKeeperDirectiveResult,
  BulkKeeperDirectiveResponse,
  BulkKeeperResumeTarget,
} from './keeper-lifecycle'
export {
  bootKeeper,
  shutdownKeeper,
  resetKeeper,
  clearKeeper,
  pauseKeeper,
  resumeKeeper,
  wakeKeeper,
  fetchKeeperCheckpoints,
  deleteKeeperHistorySnapshots,
  bulkKeeperDirective,
} from './keeper-lifecycle'

// --- Types ---

export interface KeeperTurnInterruptResult {
  /** The server failed the turn switch. Whether the signal reached the running
   *  fiber, and whether that fiber then ended, are later events this response
   *  cannot report. Read the turn state for the outcome. */
  signalled: boolean
  turn_id?: number
  reason?: string
  detail?: string
}

export async function interruptKeeperTurn(
  keeperName: string,
  opts: { signal?: AbortSignal } = {},
): Promise<KeeperTurnInterruptResult> {
  const path = '/api/v1/keepers/turn/interrupt'
  const resp = await fetchControlPlane(
    path,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify({ name: keeperName.trim() }),
      signal: opts.signal,
    },
  )
  if (!resp.ok) {
    throw await apiRequestErrorFromResponse('POST', path, resp)
  }
  const data = (await resp.json()) as Record<string, unknown>
  return {
    signalled: data.signalled === true,
    turn_id: typeof data.turn_id === 'number' ? data.turn_id : undefined,
    reason: asString(data.reason),
    detail: asString(data.detail),
  }
}

export type {
  KeeperChatCustomEventName,
  KeeperChatStreamEvent,
} from '../lib/keeper-chat-stream-contract'

// A tool call the keeper is holding, as listed by the server registry. This is
// the re-hydration path for waits whose owning stream watcher is gone and the
// fallback when the REQUESTED event predates this view.
export interface KeeperToolApprovalRow {
  keeper: string
  tool_call_id: string
  tool: string
  args: string
  question: string
  because: string
  asked_at: number | null
  timeout_sec: number | null
}

export async function fetchKeeperToolApprovals(
  opts: { signal?: AbortSignal } = {},
): Promise<KeeperToolApprovalRow[]> {
  const path = '/api/v1/keepers/tool-approvals'
  const resp = await fetchControlPlane(path, { method: 'GET', signal: opts.signal })
  if (!resp.ok) {
    throw await apiRequestErrorFromResponse('GET', path, resp)
  }
  const data = (await resp.json()) as Record<string, unknown>
  const rows = Array.isArray(data.pending) ? data.pending : []
  return rows.map((row): KeeperToolApprovalRow => {
    const record = isRecord(row) ? row : {}
    return {
      keeper: asString(record.keeper) ?? '',
      tool_call_id: asString(record.tool_call_id) ?? '',
      tool: asString(record.tool) ?? '',
      args: asString(record.args) ?? '',
      question: asString(record.question) ?? '',
      because: asString(record.because) ?? '',
      asked_at: typeof record.asked_at === 'number' ? record.asked_at : null,
      timeout_sec: typeof record.timeout_sec === 'number' ? record.timeout_sec : null,
    }
  }).filter(row => row.keeper && row.tool_call_id)
}

// Answers a held tool call. `settled: false` on a 200 means the wait was
// already gone (timed out, or answered elsewhere) — the POST still succeeds,
// so the caller reads the flag rather than treating absence of a throw as
// "approved".
export async function answerKeeperToolApproval(
  keeperName: string,
  toolCallId: string,
  decision: 'approve' | 'deny',
  opts: { signal?: AbortSignal } = {},
): Promise<{ settled: boolean; decision: string }> {
  const path = '/api/v1/keepers/tool-approval'
  const resp = await fetchControlPlane(
    path,
    {
      method: 'POST',
      headers: jsonHeaders(),
      body: JSON.stringify({ name: keeperName.trim(), tool_call_id: toolCallId, decision }),
      signal: opts.signal,
    },
  )
  if (!resp.ok) {
    throw await apiRequestErrorFromResponse('POST', path, resp)
  }
  const data = (await resp.json()) as Record<string, unknown>
  return {
    settled: data.settled === true,
    decision: asString(data.decision) ?? decision,
  }
}

// --- SSE streaming ---

function parseSseFrames(chunk: string): { frames: string[]; rest: string } {
  const normalized = chunk.replace(/\r\n/g, '\n')
  const frames: string[] = []
  let start = 0
  for (;;) {
    const split = normalized.indexOf('\n\n', start)
    if (split < 0) {
      return {
        frames,
        rest: normalized.slice(start),
      }
    }
    frames.push(normalized.slice(start, split))
    start = split + 2
  }
}

function parseSseEvent(frame: string): KeeperChatStreamEvent | null {
  const dataLines = frame
    .split('\n')
    .filter(line => line.startsWith('data:'))
    .map(line => line.slice(5).trimStart())
  if (dataLines.length === 0) return null
  try {
    return JSON.parse(dataLines.join('\n')) as KeeperChatStreamEvent
  } catch (err) {
    console.debug('[keeper-stream] SSE frame parse failed', dataLines.join('\n').slice(0, 120), err instanceof Error ? err.message : err)
    return null
  }
}

function isTerminalKeeperStreamEvent(event: KeeperChatStreamEvent): boolean {
  return event.type === 'RUN_FINISHED'
    || event.type === 'RUN_ERROR'
    || (
      event.type === 'CUSTOM'
      && event.name === 'KEEPER_CHAT_OPERATION_ACCEPTED'
      && (
        event.value.state === 'Succeeded'
        || event.value.state === 'Failed'
        || event.value.state === 'Cancelled'
      )
    )
}

export interface StreamAttachment {
  id: string
  type: 'image' | 'file'
  name: string
  size: number
  mimeType: string
  data: string
}

/** Only byte-backed attachments ride the [attachments] wire array — the
 *  server's byte store. A reference (#33728) travels as its user_block
 *  carrier (url / file_id) and sends no bytes at all. */
export function wireAttachments(
  attachments: readonly KeeperConversationAttachment[],
): StreamAttachment[] {
  return attachments.flatMap((att) =>
    att.kind
      ? []
      : [{
          id: att.id,
          type: att.type,
          name: att.name,
          size: att.size,
          mimeType: att.mimeType,
          data: att.data,
        }],
  )
}

/** Co-view context sent from dashboard surfaces such as the Copilot Dock. */
export interface KeeperStreamSurfaceContext {
  label: string
  route: string
  scene: string
  fields: unknown
}

/** Outcome of a keeper chat stream read loop.
 *  `terminal: false` means the connection closed without a
 *  RUN_FINISHED / RUN_ERROR event — the response was cut mid-stream
 *  and callers must not present it as a completed reply. */
export interface KeeperStreamOutcome {
  terminal: boolean
}

export type KeeperChatOperationState =
  | { kind: 'queued' }
  | { kind: 'running'; startedAt: number }
  | { kind: 'succeeded'; completedAt: number; outcomeRef: string }
  | {
      kind: 'failed'
      completedAt: number
      failureKind: string
      detail: string
      outcomeRef: string | null
    }
  | { kind: 'cancelled'; completedAt: number }

export interface KeeperChatOperationInput {
  message: string
  wire: Record<string, unknown>
}

export interface KeeperChatOperation {
  operationId: string
  sequence: string
  createdAt: number
  input: KeeperChatOperationInput | null
  state: KeeperChatOperationState
}

export interface StreamKeeperMessageOptions {
  operationId: string
  signal?: AbortSignal
  onEvent: (event: KeeperChatStreamEvent) => void
  attachments?: KeeperConversationAttachment[]
  userBlocks?: KeeperUserInputBlock[]
  channel?: string
  channelWorkspaceId?: string
  turnInstructions?: string
  surfaceContext?: KeeperStreamSurfaceContext
}

function streamUserBlockToWire(block: KeeperUserInputBlock): Record<string, unknown> {
  if (block.type === 'text') {
    return {
      type: 'text',
      text: block.text,
    }
  }
  // Image reference carriers (#33728): one field names the carrier and the
  // server parses exactly one — attachment_id (bytes), url, or file_id.
  if ('url' in block) {
    return {
      type: 'image',
      url: block.url,
      ...(block.mimeType ? { mime_type: block.mimeType } : {}),
    }
  }
  if ('fileId' in block) {
    return {
      type: 'image',
      file_id: block.fileId,
      ...(block.mimeType ? { mime_type: block.mimeType } : {}),
    }
  }
  return {
    type: block.type,
    attachment_id: block.attachmentId,
    name: block.name,
    mime_type: block.mimeType,
    size: block.size,
  }
}

export async function streamKeeperMessage(
  name: string,
  message: string,
  {
    operationId,
    signal,
    onEvent,
    attachments,
    userBlocks,
    channel,
    channelWorkspaceId,
    turnInstructions,
    surfaceContext,
  }: StreamKeeperMessageOptions,
): Promise<KeeperStreamOutcome> {
  // Direct keeper chat is a mutation path just like MCP tools.  Bootstrap the
  // loopback dashboard credential before constructing the request so a freshly
  // loaded dashboard never emits a misleading 401 "Token required" toast.
  // Existing credentials are left to the typed 401 recovery below; only a
  // missing credential needs the preflight bootstrap. This avoids an extra
  // network round-trip for every message while still preventing the common
  // freshly-loaded-dashboard failure.
  if (!jsonHeaders().Authorization) await ensureDevToken()
  const exactOperationId = operationId.trim()
  if (!exactOperationId) throw new Error('Keeper chat operation id is required')
  const body: Record<string, unknown> = {
    request_id: exactOperationId,
    name,
    message,
  }
  if (channel && channel.trim() !== '') {
    body.channel = channel.trim()
  }
  if (channelWorkspaceId && channelWorkspaceId.trim() !== '') {
    body.channel_workspace_id = channelWorkspaceId.trim()
  }
  if (turnInstructions && turnInstructions.trim() !== '') {
    body.turn_instructions = turnInstructions.trim()
  }
  if (surfaceContext && Object.keys(surfaceContext).length > 0) {
    body.surface_context = surfaceContext
  }
  if (attachments && attachments.length > 0) {
    const wire = wireAttachments(attachments)
    if (wire.length > 0) {
      body.attachments = wire.map(att => ({
        id: att.id,
        type: att.type,
        name: att.name,
        size: att.size,
        mime_type: att.mimeType,
        data: att.data,
      }))
    }
  }
  if (userBlocks && userBlocks.length > 0) {
    body.user_blocks = userBlocks.map(streamUserBlockToWire)
  }
  const requestBody = JSON.stringify(body)
  const streamPath = '/api/v1/keepers/chat/stream'
  const postStream = () => fetch(streamPath, {
    method: 'POST',
    headers: {
      ...jsonHeaders(),
      Accept: 'text/event-stream',
    },
    body: requestBody,
    signal,
  })

  let res = await postStream()

  if (!res.ok) {
    let requestError = await apiRequestErrorFromResponse('POST', streamPath, res)
    if (
      res.status === 401
      && await refreshDevTokenAfterAuthError(requestError.authErrorCode)
    ) {
      res = await postStream()
      if (!res.ok) {
        requestError = await apiRequestErrorFromResponse('POST', streamPath, res)
      }
    }
    if (!res.ok) {
      throw requestError
    }
  }

  if (!res.body) {
    throw new Error('스트리밍 응답 본문 사용 불가')
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  try {
    for (;;) {
      const { done, value } = await reader.read()
      buffer += decoder.decode(value ?? new Uint8Array(), { stream: !done })
      const { frames, rest } = parseSseFrames(buffer)
      buffer = rest
      for (const frame of frames) {
        const event = parseSseEvent(frame)
        if (!event) continue
        onEvent(event)
        if (isTerminalKeeperStreamEvent(event)) {
          try {
            await reader.cancel()
          } catch {
            // Ignore stream cancellation errors after terminal events.
          }
          return { terminal: true }
        }
      }
      if (done) break
    }
    const tail = buffer.trim()
    if (tail) {
      const event = parseSseEvent(tail)
      if (event) {
        onEvent(event)
        if (isTerminalKeeperStreamEvent(event)) return { terminal: true }
      }
    }
    // Connection closed without RUN_FINISHED / RUN_ERROR: mid-stream cut.
    return { terminal: false }
  } finally {
    reader.releaseLock()
  }
}

function parseKeeperChatOperation(value: unknown): KeeperChatOperation {
  if (!isRecord(value) || value.schema !== 'masc.keeper_chat_operation.v1') {
    throw new Error('Keeper chat operation response has an unsupported schema')
  }
  const operationId = asString(value.operation_id, '').trim()
  const sequence = asString(value.sequence, '').trim()
  const createdAt = value.created_at
  const state = asString(value.state, '').trim()
  if (
    !operationId
    || !/^\d+$/.test(sequence)
    || typeof createdAt !== 'number'
    || !Number.isFinite(createdAt)
    || createdAt < 0
  ) {
    throw new Error('Keeper chat operation response is missing identity')
  }
  const input = (() => {
    if (value.input === null) return null
    if (!isRecord(value.input)) {
      throw new Error('Keeper chat operation input must be an object or null')
    }
    const expected = [
      'schema',
      'message',
      'user_blocks',
      'turn_instructions',
      'surface_context',
      'attachments',
    ]
    const names = Object.keys(value.input)
    if (
      names.length !== expected.length
      || names.some(name => !expected.includes(name))
      || value.input.schema !== 'masc.keeper_chat_operation.input.v1'
      || typeof value.input.message !== 'string'
      || !Array.isArray(value.input.user_blocks)
      || !Array.isArray(value.input.attachments)
      || !(value.input.turn_instructions === null || typeof value.input.turn_instructions === 'string')
      || !(value.input.surface_context === null || isRecord(value.input.surface_context))
    ) {
      throw new Error('Keeper chat operation input has an invalid contract')
    }
    return { message: value.input.message, wire: { ...value.input } }
  })()
  const completedAt = value.completed_at
  const outcomeRef = asString(value.outcome_ref, '').trim()
  switch (state) {
    case 'Queued':
      if (!input) throw new Error('Queued Keeper chat operation is missing input')
      return { operationId, sequence, createdAt, input, state: { kind: 'queued' } }
    case 'Running':
      if (typeof value.started_at !== 'number') {
        throw new Error('Running Keeper chat operation is missing started_at')
      }
      return {
        operationId,
        sequence,
        createdAt,
        input,
        state: { kind: 'running', startedAt: value.started_at },
      }
    case 'Succeeded':
      if (typeof completedAt !== 'number' || !outcomeRef) {
        throw new Error('Succeeded Keeper chat operation is missing terminal outcome')
      }
      return {
        operationId,
        sequence,
        createdAt,
        input,
        state: { kind: 'succeeded', completedAt, outcomeRef },
      }
    case 'Failed': {
      const failureKind = asString(value.failure_kind, '').trim()
      const detail = asString(value.failure_detail, '').trim()
      if (typeof completedAt !== 'number' || !failureKind || !detail) {
        throw new Error('Failed Keeper chat operation is missing typed failure')
      }
      return {
        operationId,
        sequence,
        createdAt,
        input,
        state: {
          kind: 'failed',
          completedAt,
          failureKind,
          detail,
          outcomeRef: outcomeRef || null,
        },
      }
    }
    case 'Cancelled':
      if (typeof completedAt !== 'number') {
        throw new Error('Cancelled Keeper chat operation is missing completed_at')
      }
      return { operationId, sequence, createdAt, input, state: { kind: 'cancelled', completedAt } }
    default:
      throw new Error(`Keeper chat operation has unknown state: ${state || '<empty>'}`)
  }
}

export async function fetchKeeperChatOperation(
  keeperName: string,
  operationId: string,
  opts: { signal?: AbortSignal } = {},
): Promise<KeeperChatOperation> {
  const path = `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/operations/${encodeURIComponent(operationId)}`
  const response = await fetchWithTimeout(
    path,
    { headers: jsonHeaders(), signal: opts.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
  const operation = parseKeeperChatOperation(await response.json())
  if (operation.operationId !== operationId) {
    throw new Error('Keeper chat operation response identity mismatch')
  }
  return operation
}

export async function cancelKeeperChatOperation(
  keeperName: string,
  operationId: string,
  opts: { signal?: AbortSignal } = {},
): Promise<KeeperChatOperation> {
  const path = `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/operations/${encodeURIComponent(operationId)}/cancel`
  const response = await fetchControlPlane(path, {
    method: 'POST',
    headers: jsonHeaders(),
    body: '{}',
    signal: opts.signal,
  })
  if (!response.ok) throw await apiRequestErrorFromResponse('POST', path, response)
  const operation = parseKeeperChatOperation(await response.json())
  if (operation.operationId !== operationId || operation.state.kind !== 'cancelled') {
    throw new Error('Keeper chat operation cancellation response is invalid')
  }
  return operation
}

export async function listQueuedKeeperChatOperations(
  keeperName: string,
  afterSequence?: string,
): Promise<KeeperChatOperation[]> {
  const query = new URLSearchParams({ state: 'queued' })
  if (afterSequence !== undefined) query.set('after_sequence', afterSequence)
  const path = `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/operations?${query.toString()}`
  const response = await fetchWithTimeout(path, { headers: jsonHeaders() }, DEFAULT_GET_TIMEOUT_MS)
  if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
  const value: unknown = await response.json()
  if (
    !isRecord(value)
    || value.schema !== 'masc.keeper_chat_operations.list.v1'
    || value.state !== 'Queued'
    || !Array.isArray(value.operations)
  ) {
    throw new Error('Keeper chat operation list has an invalid contract')
  }
  const operations = value.operations.map(parseKeeperChatOperation)
  if (operations.some(operation => operation.state.kind !== 'queued')) {
    throw new Error('Keeper chat operation list contains a non-queued operation')
  }
  return operations
}

async function mutateQueuedKeeperChatOperation(
  keeperName: string,
  operationId: string,
  action: 'edit' | 'move-to-end',
  body: Record<string, unknown>,
): Promise<KeeperChatOperation> {
  const path = `/api/v1/keepers/${encodeURIComponent(keeperName)}/chat/operations/${encodeURIComponent(operationId)}/${action}`
  const response = await fetchControlPlane(path, {
    method: 'POST',
    headers: jsonHeaders(),
    body: JSON.stringify(body),
  })
  if (!response.ok) throw await apiRequestErrorFromResponse('POST', path, response)
  const operation = parseKeeperChatOperation(await response.json())
  if (operation.operationId !== operationId || operation.state.kind !== 'queued') {
    throw new Error(`Keeper chat operation ${action} response is invalid`)
  }
  return operation
}

export async function editQueuedKeeperChatOperation(
  keeperName: string,
  operation: KeeperChatOperation,
  message: string,
): Promise<KeeperChatOperation> {
  if (operation.state.kind !== 'queued' || !operation.input) {
    throw new Error('Only a queued Keeper chat operation can be edited')
  }
  const trimmed = message.trim()
  if (!trimmed) throw new Error('Keeper chat operation message must not be blank')
  const wire: Record<string, unknown> = { ...operation.input.wire, message: trimmed }
  const rawBlocks = wire.user_blocks
  if (!Array.isArray(rawBlocks)) throw new Error('Keeper chat operation user_blocks are invalid')
  const nonText = rawBlocks.filter(block => !isRecord(block) || block.type !== 'text')
  wire.user_blocks = [...nonText, { type: 'text', text: trimmed }]
  return mutateQueuedKeeperChatOperation(keeperName, operation.operationId, 'edit', { input: wire })
}

export async function moveQueuedKeeperChatOperationToEnd(
  keeperName: string,
  operationId: string,
): Promise<KeeperChatOperation> {
  return mutateQueuedKeeperChatOperation(keeperName, operationId, 'move-to-end', {})
}

// --- Chat history ---

function parseEventQueueRevision(value: unknown): string | undefined {
  if (typeof value === 'string' && /^\d+$/.test(value)) return value
  if (
    typeof value === 'number'
    && Number.isSafeInteger(value)
    && value >= 0
  ) return String(value)
  return undefined
}

/** The exact-entry address a waiting-inventory `event_queue_pending` row
    carries in its `detail` (`server_keeper_waiting_inventory.ml`), in the
    wire form the operator route resolves: a 64-char lowercase hex source
    snapshot digest plus the entry's admitted revision as a decimal string. */
export interface KeeperEventQueueSourceAddress {
  readonly sourceRef: string
  readonly sourceIncarnation: string
}

export function parseKeeperEventQueueSourceAddress(
  detail: unknown,
): KeeperEventQueueSourceAddress | null {
  if (!isRecord(detail)) return null
  const sourceRef = asString(detail.source_ref, '').trim()
  const sourceIncarnation = parseEventQueueRevision(detail.source_incarnation)
  if (!/^[0-9a-f]{64}$/.test(sourceRef) || sourceIncarnation === undefined) return null
  return { sourceRef, sourceIncarnation }
}

export type KeeperEventQueueOperatorAction =
  | { action: 'cancel'; sourceRef: string; sourceIncarnation: string; reason: string; operationId?: string }
  | { action: 'transfer'; sourceRef: string; sourceIncarnation: string; targetKeeper: string; operationId?: string }
  | { action: 'reprioritize'; sourceRef: string; sourceIncarnation: string; urgency: 'immediate' | 'normal' | 'low' }

export type KeeperEventQueueReplayableAction =
  | { action: 'cancel'; sourceRef: string; sourceIncarnation: string; reason: string; operationId: string }
  | { action: 'transfer'; sourceRef: string; sourceIncarnation: string; targetKeeper: string; operationId: string }

type PreparedKeeperEventQueueOperatorAction =
  | KeeperEventQueueReplayableAction
  | Extract<KeeperEventQueueOperatorAction, { action: 'reprioritize' }>

export class KeeperEventQueueOperationError extends Error {
  readonly operation: KeeperEventQueueReplayableAction
  readonly commitState: 'committed' | 'unknown'

  constructor(
    message: string,
    operation: KeeperEventQueueReplayableAction,
    commitState: 'committed' | 'unknown',
  ) {
    super(message)
    this.name = 'KeeperEventQueueOperationError'
    this.operation = operation
    this.commitState = commitState
  }
}

function prepareKeeperEventQueueOperatorAction(
  operation: KeeperEventQueueOperatorAction,
): PreparedKeeperEventQueueOperatorAction {
  switch (operation.action) {
    case 'cancel':
    case 'transfer':
      return {
        ...operation,
        operationId: operation.operationId ?? crypto.randomUUID(),
      }
    case 'reprioritize':
      return operation
  }
}

function keeperEventQueueOperationError(
  message: string,
  operation: PreparedKeeperEventQueueOperatorAction,
  commitState: 'committed' | 'unknown',
): Error {
  return operation.action === 'reprioritize'
    ? new Error(message)
    : new KeeperEventQueueOperationError(message, operation, commitState)
}

export async function operateKeeperEventQueue(
  keeperName: string,
  operation: KeeperEventQueueOperatorAction,
): Promise<void> {
  const prepared = prepareKeeperEventQueueOperatorAction(operation)
  const common = {
    schema: 'keeper_event_queue.operator.request.v2',
    action: prepared.action,
    source_incarnation: prepared.sourceIncarnation,
    source_ref: prepared.sourceRef,
  }
  const request = prepared.action === 'cancel'
    ? {
        ...common,
        operator_operation_id: prepared.operationId,
        reason: prepared.reason,
      }
    : prepared.action === 'transfer'
      ? {
          ...common,
          operator_operation_id: prepared.operationId,
          target_keeper: prepared.targetKeeper,
        }
      : { ...common, urgency: prepared.urgency }
  let raw: unknown
  try {
    raw = await post<unknown>(
      `/api/v1/keepers/${encodeURIComponent(keeperName)}/events/operator`,
      request,
    )
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw keeperEventQueueOperationError(message, prepared, 'unknown')
  }
  if (
    !isRecord(raw)
    || raw.schema !== 'keeper_event_queue.operator.result.v1'
    || raw.ok !== true
    || asString(raw.keeper_name, '').trim() !== keeperName
    || !isRecord(raw.result)
  ) {
    throw keeperEventQueueOperationError(
      'operateKeeperEventQueue: invalid response envelope',
      prepared,
      'unknown',
    )
  }
  const status = asString(raw.result.status, '').trim()
  if (status === 'committed_followup_failed') {
    const transitionId = asString(raw.result.transition_id, '').trim()
    const stage = asString(raw.result.stage, '').trim()
    const detail = asString(raw.result.detail, '').trim()
    if (
      !transitionId
      || !['checkpoint', 'wal_compaction', 'projection', 'target_projection'].includes(stage)
      || !detail
    ) {
      throw keeperEventQueueOperationError(
        'operateKeeperEventQueue: invalid committed failure evidence',
        prepared,
        'unknown',
      )
    }
    throw keeperEventQueueOperationError(
      `Event queue mutation committed, but ${stage} follow-up failed (${transitionId}): ${detail}`,
      prepared,
      'committed',
    )
  }
  if (status === 'applied' || status === 'already_applied') {
    const transitionId = asString(raw.result.transition_id, '').trim()
    const revision = parseEventQueueRevision(raw.result.revision)
    if (!transitionId && revision === undefined) {
      throw keeperEventQueueOperationError(
        'operateKeeperEventQueue: applied result lacks durable identity',
        prepared,
        'unknown',
      )
    }
    return
  }
  throw keeperEventQueueOperationError(
    'operateKeeperEventQueue: unknown result status',
    prepared,
    'unknown',
  )
}

export async function fetchKeeperChatHistory(
  name: string,
): Promise<KeeperChatHistoryMessage[]> {
  // P1 silent-failure fix: previously HTTP non-2xx and network/parse
  // errors both mapped to `return []`, leaving the caller unable to
  // distinguish "no chat history yet" from "fetch failed."  Now both
  // throw, and the caller (hydrateKeeperChatHistory in
  // keeper-actions.ts) is responsible for surfacing the failure to
  // the operator.  Per-item safeParse drift remains
  // tolerant — only network / HTTP / shape errors throw.
  const { response: resp, data } = await fetchJsonWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/chat/history`,
    { headers: jsonHeaders() },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) {
    throw new Error(`fetchKeeperChatHistory: HTTP ${resp.status} ${resp.statusText}`)
  }
  if (!Array.isArray(data)) {
    throw new Error('fetchKeeperChatHistory: response is not an array')
  }
  const { safeParseKeeperChatHistoryMessage } = await import('./schemas/keeper-chat-history')
  return data
    .map(safeParseKeeperChatHistoryMessage)
    .filter((m): m is KeeperChatHistoryMessage => m !== null)
}

// --- Keeper observability API ---

export interface KeeperStateDiagramResponse {
  keeper: string
  current_phase: string
  mermaid: string
  runtime_fsm_mermaid?: string
  // Structured data for Cytoscape FSM rendering
  tool_count?: number
  runtime_models?: string[]
  last_provider_result?: string | null
  runtime_models_source?: string
  last_provider_result_source?: string
}

export async function fetchKeeperTransitions(
  name: string,
  limit = 20,
  opts?: { signal?: AbortSignal },
): Promise<KeeperTransitionsResponse> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/transitions?limit=${limit}`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`transitions fetch failed: ${resp.status}`)
  const { parseKeeperTransitionsResponse } = await import('./schemas/keeper-transitions')
  return parseKeeperTransitionsResponse(await resp.json())
}

// --- Keeper lifecycle timeline (#12798) ---

// Detail views need enough recent lifecycle entries to avoid silently truncating
// active keepers, while compact surfaces can still pass an explicit lower limit.
export const KEEPER_LIFECYCLE_DEFAULT_LIMIT = 200

export interface KeeperLifecycleEvent {
  ts: number
  event: string
  phase: string | null
  detail: string
}

export interface KeeperLifecycleTimelineResponse {
  keeper: string
  count: number
  events: KeeperLifecycleEvent[]
}

function parseKeeperLifecycleEvent(raw: unknown): KeeperLifecycleEvent {
  if (!isRecord(raw)) throw new Error('lifecycle event is not a record')
  return {
    ts: typeof raw.ts === 'number' ? raw.ts : 0,
    event: typeof raw.event === 'string' ? raw.event : '',
    phase: typeof raw.phase === 'string' ? raw.phase : null,
    detail: typeof raw.detail === 'string' ? raw.detail : '',
  }
}

export function parseKeeperLifecycleResponse(raw: unknown): KeeperLifecycleTimelineResponse {
  if (!isRecord(raw)) throw new Error('lifecycle response is not a record')
  const events = Array.isArray(raw.events) ? raw.events.map(parseKeeperLifecycleEvent) : []
  return {
    keeper: typeof raw.keeper === 'string' ? raw.keeper : '',
    count: typeof raw.count === 'number' ? raw.count : events.length,
    events,
  }
}

export async function fetchKeeperLifecycle(
  name: string,
  limit = KEEPER_LIFECYCLE_DEFAULT_LIMIT,
  opts?: { signal?: AbortSignal },
): Promise<KeeperLifecycleTimelineResponse> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/lifecycle?limit=${limit}`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`lifecycle fetch failed: ${resp.status}`)
  return parseKeeperLifecycleResponse(await resp.json())
}

export async function fetchKeeperStateDiagram(
  name: string,
  opts?: { signal?: AbortSignal },
): Promise<KeeperStateDiagramResponse> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/state-diagram`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`state-diagram fetch failed: ${resp.status}`)
  return resp.json() as Promise<KeeperStateDiagramResponse>
}

export async function fetchKeeperComposite(
  name: string,
  opts?: { signal?: AbortSignal },
): Promise<KeeperCompositeSnapshot> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/composite`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`composite fetch failed: ${resp.status}`)
  const { parseKeeperCompositeSnapshot } = await import('./schemas/keeper-composite')
  return parseKeeperCompositeSnapshot(await resp.json())
}


/**
 * LT-16a: fetch the fleet-wide composite snapshot in one envelope.
 * Backend reuses the same per-snapshot shape as fetchKeeperComposite,
 * wrapped in { generated_at, count, snapshots: [...] }.
 */
export async function fetchKeepersComposite(
  opts?: { signal?: AbortSignal },
): Promise<FleetCompositeSnapshot> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/composite`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`fleet composite fetch failed: ${resp.status}`)
  const { parseFleetCompositeSnapshot } = await import('./schemas/keeper-composite')
  return parseFleetCompositeSnapshot(await resp.json())
}

// --- Eval Quality (RFC-MASC-005 Phase 3) ---

export interface EvalLayerResult {
  layer_name: string
  passed: boolean
  score: number | null
  evidence: string[]
  detail: string | null
}

export interface EvalVerdict {
  schema_version: number
  all_passed: boolean
  coverage: number
  layer_results: EvalLayerResult[]
}

export interface EvalSnapshot {
  agent_name: string
  session_id: string | null
  worker_run_id: string
  timestamp: number
  verdict: EvalVerdict
  baseline_status: string | null
}

export interface KeeperEvalResponse {
  keeper: string
  count: number
  latest_coverage: number | null
  latest_all_passed: boolean | null
  snapshots: EvalSnapshot[]
}

export async function fetchKeeperEval(name: string, limit = 10): Promise<KeeperEvalResponse> {
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/eval?limit=${limit}`,
    { headers: jsonHeaders() },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`eval fetch failed: ${resp.status}`)
  return resp.json() as Promise<KeeperEvalResponse>
}

/** Result of starting an operator-initiated deliberation. */
export interface KeeperFusionRunResponse {
  ok: true
  status: 'fusion_started'
  runId: string
  ownerKeeper: string
  fusionRoute: string
}

/** Start a deliberation owned by [keeperName]. This is the surface that makes
    the judge-of-judges topologies reachable from the dashboard; without it the
    only way to run them was a keeper deciding to call masc_fusion on its own.

    `preset` / `topology` are omitted from the body when empty so the tool's own
    defaults apply — the client does not get a second opinion about what the
    default is. Rejections (unknown preset, preset without enough judges) come
    back as the tool's message, surfaced verbatim. */
export async function runKeeperFusion(
  keeperName: string,
  input: { prompt: string; preset?: string; topology?: string; webTools?: boolean },
): Promise<KeeperFusionRunResponse> {
  const body: Record<string, unknown> = { prompt: input.prompt }
  if (input.preset) body.preset = input.preset
  if (input.topology) body.topology = input.topology
  if (input.webTools !== undefined) body.web_tools = input.webTools
  const raw = await post<unknown>(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/fusion`,
    body,
  )
  if (!isRecord(raw) || raw.ok !== true) {
    const message = isRecord(raw) ? asString(raw.error) : null
    throw new Error(message ?? 'runKeeperFusion: invalid response envelope')
  }
  const runId = asString(raw.run_id)
  const ownerKeeper = asString(raw.owner_keeper)
  const fusionRoute = asString(raw.fusion_route)
  if (!runId || !ownerKeeper || !fusionRoute) {
    throw new Error('runKeeperFusion: missing run metadata')
  }
  return { ok: true, status: 'fusion_started', runId, ownerKeeper, fusionRoute }
}
