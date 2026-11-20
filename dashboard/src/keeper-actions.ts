import { observeKeeperChatOperation, waitForKeeperChatOperationTerminal } from './keeper-chat-operation-observer'
import { setupObservationRefresh } from './lib/observation-refresh'
import { captureDashboardObservationOwner, dashboardObservationOwnerIsCurrent } from './lib/observation-read-owner'
import { toolObservationContinues } from './keeper-tool-observations'
import { initialKeeperResponseState, reduceKeeperResponse } from './lib/keeper-response-state'
import { keeperStreamContract, normalizeStreamContract } from './keeper-stream-contract'
import { normalizeKeeperStatusPayloadDeliveryProvenance } from './api/schemas/keeper-chat-delivery-provenance'
import { keeperResponseIsFailed, keeperResponseIsTerminal } from './lib/keeper-response-state'
import {
  newKeeperChatOperationId,
  sameDeliveryKey,
  toolDeliveryBelongsToProducer,
  operationDeliveryProvenance,
  sameDeliveryProvenance,
} from './keeper-delivery-provenance'
import { callMcpTool } from './api/mcp'
import { ApiRequestError, currentStoredTokenRevision, runOperatorAction } from './api/core'
import {
  cancelKeeperChatOperation,
  fetchKeeperChatHistory,
  fetchKeeperChatHistoryPage,
  fetchKeeperToolApprovals,
  interruptKeeperChatOperation,
  interruptKeeperTurn as apiInterruptKeeperTurn,
  streamKeeperMessage,
} from './api/keeper'
import { keeperChatOperationRefusalCode } from './api/keeper-chat-operation-refusal'
import type {
  KeeperChatOperation,
  KeeperChatOperationInterrupt,
  KeeperStreamSurfaceContext,
  KeeperToolApprovalRow,
} from './api/keeper'
import { answerKeeperToolApproval } from './api/keeper'
import { fetchKeeperToolCalls } from './api/dashboard'
import {
  markToolCallOutputsHydrated,
  markToolCallOutputsHydrating,
  markToolCallOutputsHydrationFailed,
  recordToolCallOutputs,
} from './tool-call-output-store'
import { asString, isRecord } from './components/common/normalize'
import { executionWorkspaceAuthority, executionWorkspaceRevision, invalidateDashboardCache, refreshDashboard } from './store'
import { isAbortError } from './lib/async-state'
import type {
  ChatBlock,
  KeeperConversationAttachment,
  KeeperConversationDelivery,
  KeeperConversationEntry,
  KeeperDiagnostic,
  KeeperStatusDetail,
  KeeperToolApprovalPending,
  KeeperUserInputBlock,
} from './types'
import {
  activeKeeperName,
  keeperActionErrors,
  keeperChatHistoryErrors,
  keeperChatHistoryHydration,
  keeperChatHistoryPages,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamStartedAt,
  keeperStreamLastEventAt,
  keeperThreads,
  keeperToolApprovals,
  activeStreamEntryId,
  activeStreamRequestId,
  holdStopUntilAccepted,
  endAcceptanceWait,
  closeSendWithHeldStop,
  KeeperSendClosedBeforeAcceptance,
  appendThreadEntry,
  attachKeeperAudioClip,
  chatHistoryEntriesFromRest,
  clearActiveStream,
  dropKeeperToolApproval,
  finalizeAssistantEntry,
  mergeServerHistoryEntries,
  retireKeeperChatHistory,
  normalizeKeeperProbeResult,
  normalizeKeeperRecoverResult,
  normalizeStatusDetail,
  removeThreadEntries,
  liveSendOwnsRequest,
  markLiveSendRequestAccepted,
  releaseLiveSendRequest,
  setActiveStream,
  setRecordValue,
  setStatusDetail,
  settleKeeperToolApproval,
  updateKeeperToolApproval,
  updateThreadEntry,
  upsertKeeperToolApproval,
} from './keeper-state'
import {
  abortKeeperThreadMessage,
  applyKeeperLiveSendEvent,
  failKeeperStreamOperation,
  flushPendingKeeperStreamDeltas,
  keeperLiveSendReplyRow,
} from './keeper-stream'
import {
  KEEPER_HISTORY_TAIL_MESSAGES,
} from './config/constants'
import {
  trackedKeeperChatOperationsForKeeper,
  trackedKeeperChatAssistantDraftFromEntry,
  removeTrackedKeeperChatOperation,
  type TrackedKeeperChatOperation,
  updateTrackedKeeperChatAssistantDraft,
  upsertTrackedKeeperChatOperation,
} from './keeper-chat-operations-local'

type KeeperInterjectActionKind = 'send' | 'approve' | 'pause' | 'drain'

const TOOL_ONLY_EMPTY_REPLY_TEXT = 'Tool-only turn ended without a final reply.'
const EMPTY_VISIBLE_REPLY_TEXT =
  'Keeper가 thinking만 반환하고 표시할 답변을 만들지 못했습니다. 다시 보내주세요.'
/** What stopping one chat operation came to.
 *  - `cancelled`: it was still queued, and the server cancelled it.
 *  - `interrupting`: a turn of it was running, and the server signalled that
 *    turn. The operation ends when the signal reaches the turn; its own state
 *    says when.
 *  - `nothing_to_stop`: it had left the queue and no turn of it was running.
 *  - `not_stopped`: the stop did not take, and `message` says why. The
 *    operation is where it was. */
type KeeperThreadCancelOutcome =
  | { readonly kind: 'cancelled' }
  | { readonly kind: 'interrupting' }
  | { readonly kind: 'nothing_to_stop' }
  | { readonly kind: 'not_stopped'; readonly message: string }

const pendingKeeperThreadCancels = new Map<string, Promise<KeeperThreadCancelOutcome>>()
const KEEPER_STREAM_SIGNAL_THROTTLE_MS = 1_000
const keeperStreamSignalWrites = new Map<string, number>()

interface KeeperInterjectCommand {
  readonly kind: KeeperInterjectActionKind
  readonly keeperName: string
  readonly message?: string
  /** Wire shape of `surface_context` on /api/v1/keepers/chat/stream; rendered
   *  into the keeper prompt by keeper_turn.surface_context_fields. */
  readonly surfaceContext?: KeeperStreamSurfaceContext
}

async function refreshDashboardState(): Promise<void> {
  invalidateDashboardCache()
  try {
    await refreshDashboard({ force: true })
  } catch (err) {
    console.warn(
      '[keeper-runtime] dashboard refresh failed',
      err instanceof Error ? err.message : err,
    )
  }
}

function keeperThreadCancelFailureMessage(keeperName: string, requestId: string, err: unknown): string {
  const cause = err instanceof Error ? err.message : String(err)
  return `Keeper request cancel failed for ${keeperName} (${requestId}): ${cause}`
}

export function _resetCancelledKeeperThreadRequestsForTests(): void {
  pendingKeeperThreadCancels.clear()
  keeperStreamSignalWrites.clear()
}

function releaseKeeperThreadCancelTracking(requestId: string): void {
  pendingKeeperThreadCancels.delete(requestId)
}

function markKeeperStreamSignal(keeperName: string, opts: { force?: boolean } = {}): void {
  const name = keeperName.trim()
  if (!name) return
  const now = Date.now()
  const previous = keeperStreamSignalWrites.get(name)
  if (
    !opts.force
    && previous !== undefined
    && now >= previous
    && now - previous < KEEPER_STREAM_SIGNAL_THROTTLE_MS
  ) {
    return
  }
  keeperStreamSignalWrites.set(name, now)
  setRecordValue(keeperStreamLastEventAt, name, now)
}

function clearKeeperStreamSignal(keeperName: string): void {
  const name = keeperName.trim()
  if (!name) return
  keeperStreamSignalWrites.delete(name)
  setRecordValue(keeperStreamLastEventAt, name, null)
}

/** Stop one chat operation the way its state allows. Cancelling applies to a
 *  queued operation. When the server does not cancel, a turn of the operation
 *  may be running, and the stop goes to that turn, named by the same id. That
 *  holds whatever the refusal says: a message bound to a shared execution is
 *  refused as input the cancel does not take, and the server finds the
 *  execution that carries it from the message's id. The cancel is asked first
 *  because an operation moves from the queue into a turn, so the second
 *  request meets the state the first one missed. */
async function stopKeeperChatOperation(
  name: string,
  id: string,
  signal: AbortSignal | undefined,
): Promise<KeeperThreadCancelOutcome> {
  let refused: unknown
  let cancelTaken = false
  try {
    await (signal ? cancelKeeperChatOperation(name, id, { signal }) : cancelKeeperChatOperation(name, id))
    cancelTaken = true
  } catch (err) {
    refused = err
  }
  if (cancelTaken) {
    // The server took the cancel. Forgetting the operation here is local
    // bookkeeping: it is kept out of the try so that nothing it does can read
    // as a refusal and send an interrupt after a cancel that succeeded.
    removeTrackedKeeperChatOperation(id)
    releaseLiveSendRequest(id)
    return { kind: 'cancelled' }
  }
  // Only this refusal says the operation is out of the queue. After any other
  // one it may still be queued, so a turn that is not running leaves the
  // operation as it was and the refusal is the answer.
  const leftQueue = keeperChatOperationRefusalCode(refused) === 'not_queued'
  let interrupt: KeeperChatOperationInterrupt
  try {
    interrupt = await (signal
      ? interruptKeeperChatOperation(name, id, { signal })
      : interruptKeeperChatOperation(name, id))
  } catch (err) {
    throw leftQueue ? err : refused
  }
  if (interrupt.kind === 'signalled') return { kind: 'interrupting' }
  if (!leftQueue) throw refused
  switch (interrupt.kind) {
    case 'not_current':
    case 'settling':
    case 'paused_pending_admission':
      return { kind: 'nothing_to_stop' }
    case 'maintenance_running':
      throw new Error(keeperTurnEndedUnsettledMessage('a maintenance run', interrupt.kind))
    case 'slot_held_by_autonomous_turn':
      throw new Error(keeperTurnEndedUnsettledMessage('an autonomous turn', interrupt.kind))
    case 'cancel_failed':
    case 'owner_unavailable':
      throw new Error(`the running turn was not stopped (${interrupt.kind}${interrupt.detail ? `: ${interrupt.detail}` : ''})`)
  }
}

/** The operation still reads as running, but its own turn has ended and only
 *  its record is unwritten. What holds the Keeper now is not this operation's,
 *  and a stop that names the operation does not reach it. */
function keeperTurnEndedUnsettledMessage(holder: string, code: string): string {
  return `the turn of this operation has ended and its record is not written yet; ${holder} holds the Keeper and was not stopped (${code})`
}

/** Ask the server to stop one chat operation and say what came of it. A stop
 *  already on the wire for the same operation is the one that answers. */
export function cancelKeeperThreadRequest(
  keeperName: string,
  requestId: string,
  opts: { signal?: AbortSignal } = {},
): Promise<KeeperThreadCancelOutcome> {
  const name = keeperName.trim()
  const id = requestId.trim()
  if (!name || !id) {
    return Promise.resolve({ kind: 'not_stopped', message: 'A stop needs the Keeper and the operation it names.' })
  }
  const existing = pendingKeeperThreadCancels.get(id)
  if (existing) return existing
  const promise = stopKeeperChatOperation(name, id, opts.signal)
    .catch((err): KeeperThreadCancelOutcome => {
      const message = keeperThreadCancelFailureMessage(name, id, err)
      console.warn('[keeper] server stop failed', message)
      return { kind: 'not_stopped', message }
    })
    .then(outcome => {
      setRecordValue(keeperActionErrors, name, outcome.kind === 'not_stopped' ? outcome.message : null)
      return outcome
    })
    .finally(() => {
      pendingKeeperThreadCancels.delete(id)
    })
  pendingKeeperThreadCancels.set(id, promise)
  return promise
}

export async function cancelActiveKeeperThreadMessage(name: string): Promise<boolean> {
  const keeperName = name.trim()
  if (!keeperName) return false
  // Until the send reads the acceptance frame, the Dashboard cannot tell
  // whether the server holds the operation. A stop that names it could reach
  // the server before the submit and find nothing, and closing the stream does
  // not take back an operation the server accepts: its turn would run under
  // rows marked cancelled. The stop is held instead, and the send passes it on
  // when the acceptance arrives. The hold lasts only while an acceptance can
  // still come: a send that ends without one drops the stop and its rows say
  // how the send ended, and the operator can close the send instead of waiting
  // (closeKeeperSendWithHeldStop).
  const heldReplyRow = holdStopUntilAccepted(keeperName)
  if (heldReplyRow !== null) {
    finalizeAssistantEntry(keeperName, heldReplyRow, { streamState: 'stop_pending' })
    return true
  }
  const requestIdBeforeAbort = activeStreamRequestId(keeperName)
  const abortResult = abortKeeperThreadMessage(keeperName)
  const requestId = requestIdBeforeAbort ?? abortResult?.requestId ?? null
  const locallyAborted = Boolean(abortResult?.controllerAborted || abortResult?.entryId)
  if (requestId) {
    void cancelKeeperThreadRequest(keeperName, requestId)
  }
  if (!requestIdBeforeAbort && !requestId && !locallyAborted) {
    // Nothing was in flight; treat as a successful no-op.
    return true
  }
  return locallyAborted
}

/** The way out of a held stop. The operator does not wait for the acceptance
 *  any longer: the send is closed and the stop is sent nowhere. The reply row
 *  says so while the send still has one. A row that stored history put in its
 *  place is the server's and is left as it is. It is its own action, not a
 *  second press of stop, so that pressing stop twice does not give the wait
 *  up. */
export function closeKeeperSendWithHeldStop(name: string): void {
  const keeperName = name.trim()
  if (keeperName) closeSendWithHeldStop(keeperName)
}

export async function interruptKeeperTurn(keeperName: string): Promise<boolean> {
  const name = keeperName.trim()
  if (!name) return false
  // A stop for an operation whose acceptance the send has not read is held
  // here and goes out at that acceptance. The Keeper interrupt below does not
  // wait for it: it stops the turn that runs now and answers false when none
  // does.
  await cancelActiveKeeperThreadMessage(name)
  try {
    const result = await apiInterruptKeeperTurn(name)
    setRecordValue(keeperActionErrors, name, null)
    return result.signalled
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.warn('[keeper] interrupt turn failed', { keeperName: name, message })
    setRecordValue(keeperActionErrors, name, message)
    throw err
  }
}

// --- Held tool approvals (task-343) ---

function pendingToolApproval(row: KeeperToolApprovalRow): KeeperToolApprovalPending {
  return {
    approvalId: row.approval_id,
    toolCallId: row.tool_call_id,
    toolName: row.tool,
    args: row.args,
    question: row.question,
    because: row.because,
    askedAtMs: row.asked_at !== null ? row.asked_at * 1000 : null,
    timeoutSec: row.timeout_sec,
    answering: false,
    answeredDecision: null,
    answeredOutcome: null,
    settled: false,
  }
}

/** One held call across the fleet: an approval id is unique within its Keeper. */
function toolApprovalKey(keeper: string, approvalId: string): string {
  return JSON.stringify([keeper, approvalId])
}

function sameToolApprovalCallRows(
  before: Record<string, KeeperToolApprovalPending> | undefined,
  after: Record<string, KeeperToolApprovalPending> | undefined,
  toolCallId: string,
): boolean {
  const beforeRows = Object.values(before ?? {}).filter(row => row.toolCallId === toolCallId)
  const afterRows = Object.values(after ?? {}).filter(row => row.toolCallId === toolCallId)
  return beforeRows.length === afterRows.length
    && beforeRows.every(row => after?.[row.approvalId] === row)
}

// Brings the cards in line with the waits the server holds. It draws a wait
// whose REQUESTED event this view never saw: the listing is public-read, so a
// dashboard opened after the gate fired still draws the card instead of
// discovering the wait only as a 180s timeout. And it retires a card whose
// wait is gone, when no settlement told this view.
export async function hydrateKeeperToolApprovals(): Promise<void> {
  const beforeRead = keeperToolApprovals.value
  const workspace = executionWorkspaceAuthority.peek()
  const workspaceRevision = executionWorkspaceRevision.peek()
  const authRevision = currentStoredTokenRevision()
  let rows
  try {
    rows = await fetchKeeperToolApprovals()
  } catch {
    // Listing is best-effort hydration; the REQUESTED stream event remains
    // the primary source. A failed listing must not surface as an error row.
    return
  }
  if (executionWorkspaceAuthority.peek() !== workspace
    || executionWorkspaceRevision.peek() !== workspaceRevision
    || currentStoredTokenRevision() !== authRevision) return
  const afterRead = keeperToolApprovals.value
  for (const row of rows) {
    const currentKeeper = afterRead[row.keeper]
    const beforeKeeper = beforeRead[row.keeper]
    const current = Object.values(currentKeeper ?? {}).filter(held => held.toolCallId === row.tool_call_id)
    // A concurrent stream/answer owns its newer observation. Otherwise the
    // listing can replace an unchanged older ask with the current exact ask.
    if (!sameToolApprovalCallRows(beforeKeeper, currentKeeper, row.tool_call_id)) continue
    // An ask may have appeared and settled while this read was in flight.
    // Two absent rows do not prove that its observation is still current.
    if (current.length === 0 && currentKeeper !== beforeKeeper) continue
    for (const held of current) {
      if (held.approvalId !== row.approval_id) {
        dropKeeperToolApproval(row.keeper, held.toolCallId, held.approvalId)
      }
    }
    upsertKeeperToolApproval(row.keeper, pendingToolApproval(row))
  }
  // The listing is every wait the server holds. A card that was on screen
  // before the read and is not in it has no wait behind it any more: the call
  // was answered elsewhere, timed out, or its turn ended. The stream's
  // settlement never reached this view, or there was none: a wait that ends
  // with its turn sends no settlement. A card the stream drew or changed while
  // the read was on the wire is newer than the listing and stays. The cards of
  // a call whose answer is in flight stay too. That answer compares the call's
  // cards with the ones it started from, and a card retired under it would
  // read to it as someone else's change. A card that was answered here stays as
  // the record that it was: a request that is delivered again finds it and
  // draws nothing.
  const listed = new Set(rows.map(row => toolApprovalKey(row.keeper, row.approval_id)))
  for (const [keeper, beforeKeeper] of Object.entries(beforeRead)) {
    const currentKeeper = afterRead[keeper]
    const answeringCalls = new Set(Object.values(currentKeeper ?? {})
      .filter(row => row.answering)
      .map(row => row.toolCallId))
    for (const held of Object.values(beforeKeeper)) {
      if (held.settled || answeringCalls.has(held.toolCallId)) continue
      if (currentKeeper?.[held.approvalId] !== held) continue
      if (listed.has(toolApprovalKey(keeper, held.approvalId))) continue
      dropKeeperToolApproval(keeper, held.toolCallId, held.approvalId)
    }
  }
}

export async function answerHeldKeeperToolApproval(
  keeperName: string,
  toolCallId: string,
  approvalId: string,
  decision: 'approve' | 'deny',
): Promise<boolean> {
  const existing = keeperToolApprovals.value[keeperName]?.[approvalId]
  if (typeof approvalId !== 'string' || approvalId.trim() === ''
    || !existing || existing.approvalId !== approvalId || existing.toolCallId !== toolCallId || existing.settled) return false
  if (existing.answering) return false
  const workspace = executionWorkspaceAuthority.peek()
  const workspaceRevision = executionWorkspaceRevision.peek()
  const authRevision = currentStoredTokenRevision()
  updateKeeperToolApproval(keeperName, toolCallId, approvalId, approval => ({
    ...approval,
    answering: true,
    answeredDecision: decision,
  }))
  const submittedKeeper = keeperToolApprovals.value[keeperName]
  const submitted = submittedKeeper?.[approvalId]
  if (!submitted || submitted.approvalId !== approvalId) return false
  const ownsSubmittedRow = () => executionWorkspaceAuthority.peek() === workspace
    && executionWorkspaceRevision.peek() === workspaceRevision
    && currentStoredTokenRevision() === authRevision
    && keeperToolApprovals.value[keeperName]?.[approvalId] === submitted
  const ownsCallContext = () => ownsSubmittedRow()
    && sameToolApprovalCallRows(submittedKeeper, keeperToolApprovals.value[keeperName], toolCallId)
  try {
    let result
    try {
      result = await answerKeeperToolApproval(keeperName, toolCallId, approvalId, decision)
    } catch (err) {
      if (!ownsCallContext()) return false
      const message = err instanceof Error ? err.message : String(err)
      console.warn('[keeper] tool approval answer failed', { keeperName, toolCallId, message })
      setRecordValue(keeperActionErrors, keeperName, message)
      return false
    }
    if (!ownsSubmittedRow()) return false
    if (result.settled || result.remembered) {
      const ownsContext = ownsCallContext()
      settleKeeperToolApproval(keeperName, toolCallId, approvalId, result.decision)
      if (ownsContext) setRecordValue(keeperActionErrors, keeperName, null)
      return true
    }
    if (!ownsCallContext()) return false
    setRecordValue(keeperActionErrors, keeperName, '승인 응답이 적용되지 않았습니다. 현재 승인 요청을 확인해 주세요.')
    try {
      const rows = await fetchKeeperToolApprovals()
      if (!ownsCallContext()) return false
      const current = rows.find(row => row.keeper === keeperName && row.tool_call_id === toolCallId)
      if (!current) dropKeeperToolApproval(keeperName, toolCallId, approvalId)
      else if (current.approval_id !== approvalId) {
        dropKeeperToolApproval(keeperName, toolCallId, approvalId)
        upsertKeeperToolApproval(keeperName, pendingToolApproval(current))
      }
    } catch (err) {
      if (!ownsCallContext()) return false
      const message = err instanceof Error ? err.message : String(err)
      setRecordValue(keeperActionErrors, keeperName, `승인 응답이 적용되지 않았고 현재 요청 조회도 실패했습니다: ${message}`)
    }
    return false
  } finally {
    // Release only this operation's local busy flag, including after scope
    // withdrawal. A superseding observation or answer owns a different row.
    if (keeperToolApprovals.value[keeperName]?.[approvalId] === submitted) {
      updateKeeperToolApproval(keeperName, toolCallId, approvalId, approval => ({
        ...approval, answering: false, answeredDecision: null,
      }))
    }
  }
}

export function selectKeeper(name: string): void {
  activeKeeperName.value = name.trim()
}

export async function dispatchKeeperInterjectAction(command: KeeperInterjectCommand): Promise<void> {
  const keeperName = command.keeperName.trim()
  if (!keeperName) throw new Error('INTERJECT requires an active keeper.')

  if (command.kind === 'send') {
    const message = command.message ?? ''
    if (!message.trim()) throw new Error('INTERJECT send requires a message.')
    await sendKeeperThreadMessage(keeperName, message, {
      surfaceContext: command.surfaceContext,
    })
    return
  }

  throw new Error(
    `INTERJECT ${command.kind} requires a keeper-scoped backend operator action before dispatch.`,
  )
}

export async function hydrateKeeperStatus(name: string, force = false): Promise<KeeperStatusDetail | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  if (!force && keeperStatusDetails.value[keeperName]) return keeperStatusDetails.value[keeperName]
  setRecordValue(keeperHydrating, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const text = await callMcpTool('masc_keeper_status', {
      name: keeperName,
      fast: true,
      include_context: false,
      include_metrics_overview: false,
      include_history_tail: false,
      include_repository_checkouts: true,
      tail_turns: 0,
      tail_messages: 0,
    })
    let parsed: unknown = null
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }
    parsed = normalizeKeeperStatusPayloadDeliveryProvenance(parsed)
    const detail = normalizeStatusDetail(keeperName, text, parsed)
    setStatusDetail(keeperName, detail)
    return detail
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to inspect ${keeperName}`
    console.warn(`[keeper] hydration failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    return null
  } finally {
    setRecordValue(keeperHydrating, keeperName, false)
  }
}

// Keepers whose persisted chat history was already merged this page
// lifetime. Hydration is once-per-keeper: live entries appended after
// the merge are the fresher copy, and re-merging mid-session would
// race the in-flight stream entries.
const hydratedChatKeepers = new Set<string>()
// Forced refreshes may overlap. Only the latest request may merge history
// or settle this keeper's hydration state.
type ChatHistoryHydrationRequest = {
  previewEntries: readonly KeeperConversationEntry[]
  toolOutputsStarted: boolean
}
const chatHistoryHydrationRequests = new Map<string, ChatHistoryHydrationRequest>()
/** Test-only: reset the once-per-keeper hydration guard. */
export function _resetChatHydrationForTests(): void {
  operationObservationEpoch += 1
  for (const dispose of pendingOperationWaiters.values()) dispose()
  pendingOperationWaiters.clear()
  hydratingKeeperChatOperations.clear()
  for (const dispose of failedOperationRecoveries.values()) dispose()
  failedOperationRecoveries.clear()
  hydratedChatKeepers.clear()
  chatHistoryHydrationRequests.clear()
  keeperChatHistoryErrors.value = {}
  keeperChatHistoryHydration.value = {}
  keeperChatHistoryPages.value = {}
  chatHistoryPageRequests.clear()
}

function startHistoryToolOutputHydration(keeperName: string, request: ChatHistoryHydrationRequest): void {
  if (request.toolOutputsStarted) return
  request.toolOutputsStarted = true
  void hydrateKeeperToolOutputs(keeperName)
}

/** Show canonical direct conversation while the aggregate also reads autonomous
 *  turns and trace enrichment. This preview does not own the older-page cursor
 *  or establish that an empty direct transcript means no conversation. */
async function hydrateKeeperChatHistoryPreview(keeperName: string, request: ChatHistoryHydrationRequest): Promise<void> {
  try {
    const page = await fetchKeeperChatHistoryPage(keeperName)
    if (chatHistoryHydrationRequests.get(keeperName) !== request
      || keeperChatHistoryHydration.value[keeperName] === 'hydrated') return
    const existing = keeperThreads.value[keeperName] ?? []
    const existingById = new Map(existing.map(entry => [entry.id, entry]))
    const entries = chatHistoryEntriesFromRest(keeperName, page.messages).map(entry => {
      const observed = existingById.get(entry.id)
      return observed?.streamContract ? { ...entry, streamContract: observed.streamContract } : entry
    })
    if (entries.length === 0) return
    request.previewEntries = entries
    startHistoryToolOutputHydration(keeperName, request)
    const ids = new Set(entries.map(entry => entry.id))
    mergeServerHistoryEntries(keeperName, [
      ...entries,
      ...existing.filter(entry => !ids.has(entry.id)
        && (entry.delivery === 'history' || entry.delivery === 'request_failure')),
    ])
    setRecordValue(keeperChatHistoryHydration, keeperName, 'partial')
  } catch {
    // The aggregate remains authoritative and reports its own failure. A failed
    // optional preview must neither settle hydration nor hide that result.
  }
}

async function fetchAndMergeKeeperChatHistory(keeperName: string, request: ChatHistoryHydrationRequest): Promise<void> {
  const history = await fetchKeeperChatHistory(keeperName)
  if (chatHistoryHydrationRequests.get(keeperName) !== request) return
  if (history.length > 0) {
    const observedById = new Map((keeperThreads.value[keeperName] ?? []).map(entry => [entry.id, entry]))
    const explicitContracts = new Set(history.filter(message => normalizeStreamContract(message.stream_contract) !== null)
      .map(message => message.id))
    const enriched = chatHistoryEntriesFromRest(keeperName, history).map(entry => {
      const observed = observedById.get(entry.id)
      return !explicitContracts.has(entry.id) && observed?.streamContract
        ? { ...entry, streamContract: observed.streamContract }
        : entry
    })
    const ids = new Set(enriched.map(entry => entry.id))
    // These are independent canonical observations with different windows:
    // physical page rows versus the aggregate's role-selected tail. Absence
    // from the latter is not deletion evidence. Keep page observations within
    // the ordinary thread cap, without pinning them in older-page state. The
    // next successful forced refresh replaces this request-local union.
    mergeServerHistoryEntries(keeperName, [
      ...enriched,
      ...request.previewEntries.filter(entry => !ids.has(entry.id)),
    ])
  }
}

function recordKeeperChatHistoryFailure(keeperName: string, err: unknown): void {
  // Keep prior successful membership so inactive Keepers still receive appends.
  // A failed first read must release membership so an ordinary mount can retry.
  if (keeperChatHistoryHydration.value[keeperName] !== 'hydrated') {
    hydratedChatKeepers.delete(keeperName)
    setRecordValue(keeperChatHistoryHydration, keeperName, 'failed')
  }
  const message = err instanceof Error ? err.message : `Failed to load chat history for ${keeperName}`
  console.warn(`[keeper] chat history hydration failed for ${keeperName}:`, message)
  setRecordValue(keeperChatHistoryErrors, keeperName, `이전 대화 불러오기 실패: ${message}`)
}

/** Merge the server-persisted chat transcript
 *  (`GET /api/v1/keepers/:name/chat/history`, backed by
 *  `.masc/keeper_chat/<name>.jsonl`) into the in-memory thread.
 *  Called on conversation-panel mount so the transcript survives full
 *  page reloads — the server file is the cross-connector SSOT
 *  (dashboard / Discord / Slack all append to it). */
export async function hydrateKeeperChatHistory(
  name: string,
  options: { force?: boolean } = {},
): Promise<void> {
  const keeperName = name.trim()
  if (!keeperName) return
  if (!options.force && hydratedChatKeepers.has(keeperName)) return
  const request: ChatHistoryHydrationRequest = { previewEntries: [], toolOutputsStarted: false }
  chatHistoryHydrationRequests.set(keeperName, request)
  hydratedChatKeepers.add(keeperName)
  setRecordValue(keeperHydrating, keeperName, true)
  if (keeperChatHistoryHydration.value[keeperName] !== 'hydrated') {
    void hydrateKeeperChatHistoryPreview(keeperName, request)
  }
  try {
    await fetchAndMergeKeeperChatHistory(keeperName, request)
    if (chatHistoryHydrationRequests.get(keeperName) !== request) return
    // Tool outputs are stored on a separate durable endpoint. Hydrate even
    // when chat history is empty so a keeper panel can still join recently
    // fetched tool rows from the rail/inspector.
    startHistoryToolOutputHydration(keeperName, request)
    setRecordValue(keeperChatHistoryHydration, keeperName, 'hydrated')
    setRecordValue(keeperChatHistoryErrors, keeperName, null)
  } catch (err) {
    if (chatHistoryHydrationRequests.get(keeperName) !== request) return
    recordKeeperChatHistoryFailure(keeperName, err)
  } finally {
    if (chatHistoryHydrationRequests.get(keeperName) === request) {
      chatHistoryHydrationRequests.delete(keeperName)
      setRecordValue(keeperHydrating, keeperName, false)
    }
  }
}

// Match the visible chat history window. A keeper that calls many tools can
// easily have >100 tool rows inside the 200-row transcript; using the same
// horizon keeps every visible recent row eligible for output join.
const TOOL_OUTPUT_FETCH_LIMIT = KEEPER_HISTORY_TAIL_MESSAGES

function toolOutputCoveredSinceMs(entries: readonly { ts: number }[]): number {
  const oldestMs = entries.reduce((oldest, entry) => {
    const ms = entry.ts * 1000
    return Number.isFinite(ms) ? Math.min(oldest, ms) : oldest
  }, Number.POSITIVE_INFINITY)
  // The backend filters a global recent tool-call tail by keeper, so a short
  // response is not proof that no older matching keeper rows exist. Only the
  // timestamp span actually returned by this fetch is safe to mark covered.
  return Number.isFinite(oldestMs) ? oldestMs : Number.POSITIVE_INFINITY
}

/** Best-effort hydration of tool-call outputs into the shared store so the
 *  chat ToolCallBubble can join results onto transcript rows by tool_use_id.
 *  Failures are swallowed (logged): the transcript must render with or without
 *  tool outputs. */
export async function hydrateKeeperToolOutputs(keeperName: string): Promise<void> {
  const authRevision = currentStoredTokenRevision()
  const coveredThroughMs = markToolCallOutputsHydrating(keeperName)
  try {
    const response = await fetchKeeperToolCalls(keeperName, TOOL_OUTPUT_FETCH_LIMIT)
    if (authRevision !== currentStoredTokenRevision()) return
    recordToolCallOutputs(response.entries)
    markToolCallOutputsHydrated(
      keeperName,
      coveredThroughMs,
      toolOutputCoveredSinceMs(response.entries),
    )
  } catch (err) {
    if (authRevision !== currentStoredTokenRevision()) return
    const message = err instanceof Error ? err.message : String(err)
    markToolCallOutputsHydrationFailed(keeperName, message)
    console.warn(`[keeper] tool-call output hydration failed for ${keeperName}:`, message)
  }
}

// Trailing per-keeper debounce for keeper_chat_appended pushes so a
// burst of turns (queue drain, multi-connector traffic) coalesces into
// one history refetch instead of one round-trip per message.
const chatRefreshTimers = new Map<string, ReturnType<typeof setTimeout>>()
const CHAT_APPENDED_REFRESH_DELAY_MS = 400
const QUEUED_KEEPER_REQUEST_LOST_MESSAGE =
  '서버 재시작으로 대기 중이던 요청을 찾을 수 없습니다. 메시지를 다시 보내주세요.'
const PENDING_KEEPER_CHAT_RESUME_FAILED_MESSAGE =
  '응답을 확인할 수 없어 메시지 복구를 중단했습니다. 다시 보내주세요.'
let operationObservationEpoch = 0
const pendingOperationWaiters = new Map<string, () => void>()
const failedOperationRecoveries = new Map<string, () => void>()

function notePendingOperation(
  keeperName: string,
  assistantId: string,
  operation: KeeperChatOperation,
): void {
  markKeeperStreamSignal(keeperName)
  updateThreadEntry(keeperName, assistantId, entry => {
    if (entry.delivery !== 'sending' && entry.delivery !== 'queued') return entry
    const queued = operation.state.kind === 'queued'
    return { ...entry, delivery: queued ? 'queued' : 'sending', streamState: queued ? null : 'opening' }
  })
}

function retainFailedOperationObservation(
  request: TrackedKeeperChatOperation,
  error: unknown,
  current: () => boolean,
): void {
  const key = `${request.keeperName}:${request.operationId}`
  if (!current()) return
  if (failedOperationRecoveries.has(key)) return
  let first = true
  let readError: unknown | null = error
  const dispose = () => {
    stop()
    failedOperationRecoveries.delete(key)
  }
  const stop = setupObservationRefresh(async () => {
    if (!current() || liveSendOwnsRequest(request.operationId)
      || !trackedKeeperChatOperationsForKeeper(request.keeperName).some(candidate => candidate.operationId === request.operationId)) {
      readError = null
      dispose()
      return
    }
    // The failed lookup already happened. Retain its debt without issuing
    // another immediate read before the helper's recovery deadline.
    if (first) { first = false; throw error }
    readError = await hydrateTrackedKeeperChatOperation(request, true) ?? null
    if (readError === null) dispose()
  }, {
    topics: ['chat_operation'], keeperName: request.keeperName, operationId: request.operationId,
    readError: () => readError, onError: () => {},
    resetRead: () => { if (!current()) { readError = null; dispose() } },
  })
  failedOperationRecoveries.set(key, dispose)
}

function hasCanonicalOperationTurn(
  entries: readonly KeeperConversationEntry[],
  operationId: string,
): boolean {
  const expectedUser = operationDeliveryProvenance(operationId, 'accepted_user')
  const expectedAssistant = operationDeliveryProvenance(operationId, 'terminal_result')
  const expectedFailure = operationDeliveryProvenance(operationId, 'settled_failure')
  const hasUser = entries.some(entry => (
    entry.deliveryProvenance != null
    && sameDeliveryProvenance(entry.deliveryProvenance, expectedUser)
  ))
  const hasTerminal = entries.some(entry => (
    entry.deliveryProvenance != null
    && (sameDeliveryProvenance(entry.deliveryProvenance, expectedAssistant)
      || (entry.delivery === 'request_failure'
        && sameDeliveryProvenance(entry.deliveryProvenance, expectedFailure)))
  ))
  return hasUser && hasTerminal
}

async function reconcileOperationFromServerHistory(
  keeperName: string,
  operationId: string,
  localUserId: string,
  localAssistantId: string,
): Promise<boolean> {
  // Serialize with mount hydration through the same request registry: an
  // older in-flight history fetch must not merge after this newer canonical
  // response and evict the operation turns it just restored.
  const request: ChatHistoryHydrationRequest = { previewEntries: [], toolOutputsStarted: false }
  const displacedHydration = chatHistoryHydrationRequests.has(keeperName)
  chatHistoryHydrationRequests.set(keeperName, request)
  try {
    const history = await fetchKeeperChatHistory(keeperName)
    if (chatHistoryHydrationRequests.get(keeperName) !== request) return false
    const historyEntries = chatHistoryEntriesFromRest(keeperName, history)
    const canonical = hasCanonicalOperationTurn(historyEntries, operationId)
    // Displacing an in-flight mount hydration means that fetch will bail on
    // its stale check; honor it by merging its window even without the
    // canonical turn so the transcript is not left unmerged this session.
    if (!canonical && !displacedHydration) return false
    mergeServerHistoryEntries(keeperName, historyEntries)
    if (displacedHydration) {
      // This owner observed and merged a successful replacement read, even
      // when the operation's canonical turn has not reached history yet.
      void hydrateKeeperToolOutputs(keeperName)
      setRecordValue(keeperChatHistoryHydration, keeperName, 'hydrated')
      setRecordValue(keeperChatHistoryErrors, keeperName, null)
    }
    if (!canonical) return false
    removeThreadEntries(keeperName, [localUserId, localAssistantId])
    return true
  } catch (err) {
    if (chatHistoryHydrationRequests.get(keeperName) !== request) return false
    if (displacedHydration) recordKeeperChatHistoryFailure(keeperName, err)
    throw err
  } finally {
    if (chatHistoryHydrationRequests.get(keeperName) === request) {
      chatHistoryHydrationRequests.delete(keeperName)
      setRecordValue(keeperHydrating, keeperName, false)
    }
  }
}

function operationUserEntryId(operationId: string): string {
  return `pending-user-${operationId}`
}

function operationAssistantEntryId(operationId: string): string {
  return `pending-assistant-${operationId}`
}

function isUnknownKeeperChatOperationError(err: unknown): boolean {
  const record = isRecord(err) ? err : null
  const method = asString(record?.method, '').trim().toUpperCase()
  const status = typeof record?.status === 'number' ? record.status : null
  const path = asString(record?.path, '').trim()
  const message = err instanceof Error ? err.message : ''
  if (method === 'GET' && status === 404 && path.includes('/chat/operations/')) return true
  return message.includes('/chat/operations/') && message.includes('unknown_operation')
}

function ensureTrackedOperationThreadEntries(request: TrackedKeeperChatOperation): string {
  const existing = keeperThreads.value[request.keeperName] ?? []
  const userId = operationUserEntryId(request.operationId)
  const assistantId = operationAssistantEntryId(request.operationId)
  const assistantDraft = request.assistantDraft
  if (!existing.some(entry => entry.id === userId)) {
    appendThreadEntry(request.keeperName, {
      id: userId,
      role: 'user',
      source: 'direct_user',
      label: 'You',
      text: request.message,
      timestamp: new Date(request.submittedAt).toISOString(),
      delivery: 'delivered',
      streamState: null,
      deliveryProvenance: operationDeliveryProvenance(request.operationId, 'accepted_user'),
      streamContract: keeperStreamContract('client_operation_store', 'client_placeholder', {
        requestId: request.operationId,
        reason: 'restored accepted operation from browser storage',
      }),
      attachments: request.attachments,
      details: null,
    })
  }
  if (!existing.some(entry => entry.id === assistantId)) {
    appendThreadEntry(request.keeperName, {
      id: assistantId,
      role: 'assistant',
      source: 'direct_assistant',
      label: request.keeperName,
      text: assistantDraft?.text ?? '',
      rawText: assistantDraft?.rawText ?? '',
      timestamp: assistantDraft?.timestamp ?? null,
      delivery: assistantDraft?.delivery ?? 'queued',
      streamState: assistantDraft ? assistantDraft.streamState : 'opening',
      deliveryProvenance: operationDeliveryProvenance(request.operationId, 'terminal_result'),
      streamContract: keeperStreamContract('client_operation_store', 'client_placeholder', {
        requestId: request.operationId,
        reason: 'awaiting durable operation terminal state',
      }),
      runtimeAttempt: assistantDraft?.runtimeAttempt,
      responseState: assistantDraft?.responseState,
      toolTranscriptBindings: assistantDraft?.toolTranscriptBindings,
      ...(assistantDraft?.toolObservations?.kind === 'unavailable' ? { toolObservationAuthority: 'unavailable' as const } : {}),
      traceSteps: assistantDraft?.traceSteps,
      error: assistantDraft?.error ?? null,
      details: assistantDraft?.details ?? null,
    })
  }
  const tools = assistantDraft?.toolObservations
  if (tools?.kind === 'known') {
    const parentKey = operationDeliveryProvenance(request.operationId, 'terminal_result').delivery_key
    for (const tool of tools.entries) {
      const ownerKey = tool.toolOwnerKey ?? tool.deliveryProvenance?.delivery_key
      if (!ownerKey || !sameDeliveryKey(parentKey, ownerKey)) continue
      const peers = (keeperThreads.value[request.keeperName] ?? []).filter(entry => {
        if (entry.id === tool.id) return true
        const otherKey = entry.toolOwnerKey ?? entry.deliveryProvenance?.delivery_key
        if (entry.role !== 'tool' || !otherKey || !(entry.toolOwnerKey ? sameDeliveryKey(otherKey, ownerKey) : toolDeliveryBelongsToProducer(ownerKey, otherKey))) return false
        if (tool.executionId && entry.executionId === tool.executionId) return true
        const left = tool.toolOccurrence
        const right = entry.toolOccurrence
        if (!left || !right) return false
        const leftCoordinates = left.kind === 'identified' ? [left] : left.coordinates
        const rightCoordinates = right.kind === 'identified' ? [right] : right.coordinates
        return leftCoordinates.some(a => rightCoordinates.some(b => a.streamScope === b.streamScope && a.blockIndex === b.blockIndex))
      })
      if (peers.length > 1) {
        updateThreadEntry(request.keeperName, assistantId, entry => ({ ...entry, toolObservationAuthority: 'unavailable' }))
        continue
      }
      const existingTool = peers[0]
      if (existingTool) {
        const quarantined = existingTool.toolOccurrenceQuarantined || tool.toolOccurrenceQuarantined
        const durable = { ...tool, toolCallEnded: tool.toolCallEnded || existingTool.toolCallEnded, ...(quarantined ? { toolOccurrenceQuarantined: true as const } : {}) }
        const canonicalSlot = existingTool.deliveryProvenance?.transcript_slot
        const exactBound = canonicalSlot?.kind === 'tool_call' && tool.executionId != null
          && canonicalSlot.execution_id === tool.executionId && existingTool.executionId === tool.executionId
          && toolDeliveryBelongsToProducer(ownerKey, existingTool.deliveryProvenance!.delivery_key)
          && (!tool.deliveryProvenance || sameDeliveryProvenance(existingTool.deliveryProvenance!, tool.deliveryProvenance))
        const live = { ...existingTool,
          ...(exactBound ? { toolOwnerKey: ownerKey } : {}),
          ...(existingTool.toolOccurrence === undefined && exactBound ? { toolOccurrence: tool.toolOccurrence } : {}),
          toolCallId: existingTool.toolCallId ?? tool.toolCallId, toolCallEnded: tool.toolCallEnded || existingTool.toolCallEnded, ...(quarantined ? { toolOccurrenceQuarantined: true as const } : {}) }
        if (existingTool.role !== 'tool' || !toolObservationContinues(live, durable) && !toolObservationContinues(durable, live)) {
          updateThreadEntry(request.keeperName, assistantId, entry => ({ ...entry, toolObservationAuthority: 'unavailable' }))
        } else {
          let retained: Partial<KeeperConversationEntry> = live
          if (!(existingTool.toolOccurrence === undefined && exactBound) && toolObservationContinues(live, durable)) {
            retained = { ...durable, toolCallId: durable.toolCallId ?? live.toolCallId }
          }
          updateThreadEntry(request.keeperName, existingTool.id, entry => ({ ...entry, ...retained, id: existingTool.id,
            toolCallEnded: tool.toolCallEnded || existingTool.toolCallEnded,
          }))
          updateThreadEntry(request.keeperName, assistantId, entry => ({ ...entry,
            traceSteps: entry.traceSteps?.map(step => step.kind === 'tool' && step.toolOccurrenceId === tool.id
              ? { ...step, toolOccurrenceId: existingTool.id } : step),
          }))
        }
        continue
      }
      appendThreadEntry(request.keeperName, { ...tool, role: 'tool', source: 'tool_result', streamState: null })
    }
  }
  return assistantId
}

function persistTrackedOperationAssistantDraft(
  keeperName: string,
  requestId: string | null,
  assistantEntryId: string,
): void {
  if (!requestId) return
  const entry = (keeperThreads.value[keeperName] ?? [])
    .find(candidate => candidate.id === assistantEntryId) ?? null
  if (!entry) return
  updateTrackedKeeperChatAssistantDraft(requestId, entry, keeperThreads.value[keeperName] ?? [])
}

function withCurrentTrackedOperationAssistantDraft(
  request: TrackedKeeperChatOperation,
  assistantEntryId: string,
): TrackedKeeperChatOperation {
  const entry = (keeperThreads.value[request.keeperName] ?? [])
    .find(candidate => candidate.id === assistantEntryId) ?? null
  if (!entry) return request
  const assistantDraft = trackedKeeperChatAssistantDraftFromEntry(entry, keeperThreads.value[request.keeperName] ?? [])
  return assistantDraft ? { ...request, assistantDraft } : request
}

let localIdCounter = 0

const hydratingKeeperChatOperations = new Set<string>()
const sendingKeeperThreadMessages = new Set<string>()
const INCOMPLETE_KEEPER_REPLY_MESSAGE = '응답 일부를 받지 못했고 저장된 대화도 읽지 못했습니다.'
const KEEPER_MESSAGE_CANCELLED_TEXT = '요청이 취소되었습니다.'
const KEEPER_SEND_CLOSED_BEFORE_ACCEPTANCE_TEXT =
  '서버의 접수를 확인하기 전에 연결을 끊었습니다. 중지는 서버에 보내지 않았습니다. 서버가 이 요청을 접수했다면 턴이 실행됩니다.'

function keeperThreadMessageSendKey(
  keeperName: string,
  clientActionId: string | undefined,
): string | null {
  const actionId = clientActionId?.trim() ?? ''
  return actionId ? `${keeperName}\u0000${actionId}` : null
}

function keeperThreadMessageSendKeys(
  keeperName: string,
  clientActionIds: readonly (string | undefined)[],
): string[] {
  const keys = new Set<string>()
  for (const clientActionId of clientActionIds) {
    const key = keeperThreadMessageSendKey(keeperName, clientActionId)
    if (key) keys.add(key)
  }
  return Array.from(keys)
}

export function _resetKeeperThreadMessageSendGuardsForTests(): void {
  sendingKeeperThreadMessages.clear()
}

export function isKeeperThreadMessageSendInFlight(
  keeperName: string,
  clientActionId: string | undefined,
): boolean {
  const sendKey = keeperThreadMessageSendKey(keeperName, clientActionId)
  return sendKey ? sendingKeeperThreadMessages.has(sendKey) : false
}

async function hydrateTrackedKeeperChatOperation(
  request: TrackedKeeperChatOperation,
  recoveryOwned = false,
): Promise<unknown | null | void> {
  const owner = captureDashboardObservationOwner()
  const epoch = operationObservationEpoch
  const current = () => epoch === operationObservationEpoch
    && dashboardObservationOwnerIsCurrent(owner)
  let lookupError: unknown | null = null
  // A live in-session send stream still owns this request (e.g. the panel
  // remounted on an SPA route change while the reply was pending). Defer to
  // it rather than minting a duplicate pending entry + a second operation observer.
  // After a full page reload this map is empty, so cold-start resume runs.
  if (liveSendOwnsRequest(request.operationId)) return
  const key = `${request.keeperName}:${request.operationId}`
  if (hydratingKeeperChatOperations.has(key)) return
  hydratingKeeperChatOperations.add(key)
  const assistantId = ensureTrackedOperationThreadEntries(request)
  setRecordValue(keeperSending, request.keeperName, true)
  setRecordValue(keeperActionErrors, request.keeperName, null)
  setRecordValue(keeperStreamStartedAt, request.keeperName, request.submittedAt)
  markKeeperStreamSignal(request.keeperName, { force: true })
  try {
    const waiter = waitForKeeperChatOperationTerminal(request.keeperName, request.operationId, {
      current,
      onPending: operation => notePendingOperation(request.keeperName, assistantId, operation),
    })
    pendingOperationWaiters.set(key, waiter.dispose)
    const operation = await waiter.result
    if (!current()) return
    markKeeperStreamSignal(request.keeperName)
    const isCancelled = operation.state.kind === 'cancelled'
    const failure = operation.state.kind === 'failed' ? operation.state : null
    const interrupted =
      failure?.failureKind === 'Interrupted_by_restart'
    let errorMessage: string | null = null
    if (failure) {
      errorMessage = interrupted
        ? 'Interrupted'
        : `${failure.failureKind}: ${failure.detail}`
    }
    let userDelivery: KeeperConversationDelivery = 'delivered'
    if (isCancelled) userDelivery = 'cancelled'
    else if (failure) userDelivery = 'error'
    const assistantStillLocal = (keeperThreads.value[request.keeperName] ?? [])
      .find(entry => entry.id === assistantId)
    // The operation receipt reports termination, not the observed turn
    // outcome: a legitimately recorded `no_reply` must survive a mere
    // successful-termination confirmation, or the hidden empty entry
    // resurfaces as an "(empty reply)" bubble after reload.
    const assistantDelivery: KeeperConversationDelivery =
      userDelivery === 'delivered'
        && (assistantStillLocal?.delivery ?? request.assistantDraft?.delivery) === 'no_reply'
        ? 'no_reply'
        : userDelivery
    finalizeAssistantEntry(request.keeperName, operationUserEntryId(request.operationId), {
      delivery: userDelivery,
      error: errorMessage,
      streamContract: keeperStreamContract('client_operation_lookup', 'client_operation_terminal', {
        requestId: request.operationId,
        reason: errorMessage,
      }),
    })
    if (assistantStillLocal) {
      // The server finished the operation, but a response whose stream
      // dropped a frame is incomplete and the stored transcript could not
      // replace it: keep the recorded failure instead of a delivered reply.
      const incomplete = !isCancelled && !failure && keeperResponseIsFailed(assistantStillLocal.responseState)
      const incompleteReason = assistantStillLocal.error ?? INCOMPLETE_KEEPER_REPLY_MESSAGE
      const priorResponseState = assistantStillLocal.responseState
      finalizeAssistantEntry(request.keeperName, assistantId, {
        // An unavailable stored state carries no ownership facts to protect;
        // the authoritative terminal receipt still promotes it to a known
        // terminal state instead of letting the normalizer downgrade it.
        responseState: reduceKeeperResponse(
          priorResponseState && priorResponseState.kind === 'known' ? priorResponseState : initialKeeperResponseState,
          { kind: 'terminal' },
        ).state,
        delivery: incomplete ? 'error' : assistantDelivery,
        streamState: null,
        error: incomplete ? incompleteReason : errorMessage,
        // Keep an observed occurrence time; only a placeholder saved before
        // any assistant event falls back to the receipt's completion time so
        // the settled row stops sorting with the no-timestamp in-flight tail.
        timestamp: assistantStillLocal.timestamp
          ?? new Date(operation.state.completedAt * 1000).toISOString(),
        streamContract: keeperStreamContract('client_operation_lookup', 'client_operation_terminal', {
          requestId: request.operationId,
          reason: incomplete ? incompleteReason : errorMessage,
        }),
      })
      if (incomplete) setRecordValue(keeperActionErrors, request.keeperName, incompleteReason)
    }
    if (errorMessage) setRecordValue(keeperActionErrors, request.keeperName, errorMessage)
    persistTrackedOperationAssistantDraft(request.keeperName, request.operationId, assistantId)
    try {
      const canonical = await reconcileOperationFromServerHistory(
        request.keeperName, request.operationId, operationUserEntryId(request.operationId), assistantId,
      )
      if (canonical) {
        removeTrackedKeeperChatOperation(request.operationId)
        // A prior failed hydration left a history banner behind; the
        // canonical turn is merged now, so the failure signal is stale.
        setRecordValue(keeperChatHistoryErrors, request.keeperName, null)
      }
    } catch (historyError) {
      // A missing observation cannot revoke the authoritative terminal receipt.
      const detail = historyError instanceof Error ? historyError.message : 'Chat history unavailable'
      setRecordValue(keeperChatHistoryErrors, request.keeperName, `이전 대화 불러오기 실패: ${detail}`)
    }
  } catch (err) {
    if (!current()) return
    const currentEntry = (keeperThreads.value[request.keeperName] ?? []).find(entry => entry.id === assistantId)
    if (keeperResponseIsTerminal(currentEntry?.responseState)) {
      // A lookup observation cannot revoke a receipt already restored/applied.
      // History may now hold the canonical turn even though the lookup
      // itself fails: reconcile before retaining the receipt so the record
      // is released instead of re-reading the placeholder on every mount.
      const detail = err instanceof Error ? err.message : 'Operation lookup unavailable'
      persistTrackedOperationAssistantDraft(request.keeperName, request.operationId, assistantId)
      try {
        const canonical = await reconcileOperationFromServerHistory(
          request.keeperName, request.operationId, operationUserEntryId(request.operationId), assistantId,
        )
        if (canonical) {
          removeTrackedKeeperChatOperation(request.operationId)
          setRecordValue(keeperChatHistoryErrors, request.keeperName, null)
          setRecordValue(keeperActionErrors, request.keeperName, null)
          return
        }
      } catch {
        // History still unavailable: retain the receipt and report below.
      }
      setRecordValue(keeperActionErrors, request.keeperName, detail)
      return
    }
    if (isUnknownKeeperChatOperationError(err)) {
      finalizeAssistantEntry(request.keeperName, operationUserEntryId(request.operationId), {
        delivery: 'error',
        error: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        streamContract: keeperStreamContract('client_operation_lookup', 'contract_gap', {
          requestId: request.operationId,
          reason: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        }),
      })
      finalizeAssistantEntry(request.keeperName, assistantId, {
        delivery: 'error',
        streamState: null,
        error: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        streamContract: keeperStreamContract('client_operation_lookup', 'contract_gap', {
          requestId: request.operationId,
          reason: QUEUED_KEEPER_REQUEST_LOST_MESSAGE,
        }),
      })
      persistTrackedOperationAssistantDraft(request.keeperName, request.operationId, assistantId)
      setRecordValue(keeperActionErrors, request.keeperName, QUEUED_KEEPER_REQUEST_LOST_MESSAGE)
      await hydrateKeeperChatHistory(request.keeperName, { force: true })
      return
    }
    lookupError = err
    const detail = err instanceof Error ? err.message : `Failed to resume ${request.keeperName} chat request`
    const message = `${PENDING_KEEPER_CHAT_RESUME_FAILED_MESSAGE} (${detail})`
    // A lookup failure is not a terminal operation receipt. Keep tracking.
    finalizeAssistantEntry(request.keeperName, operationUserEntryId(request.operationId), {
      delivery: 'error',
      error: message,
      streamContract: keeperStreamContract('client_operation_lookup', 'contract_gap', {
        requestId: request.operationId,
        reason: message,
      }),
    })
    finalizeAssistantEntry(request.keeperName, assistantId, {
      delivery: 'error',
      streamState: null,
      error: message,
      streamContract: keeperStreamContract('client_operation_lookup', 'contract_gap', {
        requestId: request.operationId,
        reason: message,
      }),
    })
    persistTrackedOperationAssistantDraft(request.keeperName, request.operationId, assistantId)
    setRecordValue(keeperActionErrors, request.keeperName, message)
    await hydrateKeeperChatHistory(request.keeperName, { force: true })
  } finally {
    pendingOperationWaiters.get(key)?.()
    pendingOperationWaiters.delete(key)
    hydratingKeeperChatOperations.delete(key)
    // This observation turned the sending state on, so it turns it off even after its
    // owner (workspace, credential, actor) was replaced. Nothing else resets the state
    // on an owner change, and the chat would keep showing an answer in progress.
    const observingAnother = trackedKeeperChatOperationsForKeeper(request.keeperName)
      .some(candidate => hydratingKeeperChatOperations.has(`${candidate.keeperName}:${candidate.operationId}`))
    if (!observingAnother && activeStreamEntryId(request.keeperName) === null) {
      setRecordValue(keeperSending, request.keeperName, false)
      setRecordValue(keeperStreamStartedAt, request.keeperName, null)
      clearKeeperStreamSignal(request.keeperName)
    }
    if (current() && lookupError !== null && !recoveryOwned) {
      retainFailedOperationObservation(request, lookupError, current)
    }
  }
  return lookupError
}

export async function hydrateTrackedKeeperChatOperations(name: string): Promise<void> {
  const keeperName = name.trim()
  if (!keeperName) return
  await Promise.all(trackedKeeperChatOperationsForKeeper(keeperName).map(request => hydrateTrackedKeeperChatOperation(request)))
}

/** Watch an operation whose stream the operator stopped and whose stop did not
 *  end it. `stopFailure` is why the stop did not take, when it did not. */
async function handoffCancelledStreamToOperationHydration(
  request: TrackedKeeperChatOperation,
  localEntryIds: readonly string[],
  stopFailure: string | null,
): Promise<void> {
  removeThreadEntries(request.keeperName, localEntryIds)
  releaseLiveSendRequest(request.operationId)
  const settled = hydrateTrackedKeeperChatOperation(request)
  // Resuming the watch starts the Keeper's action error from nothing, in the
  // same task the stop answered in. Said before that, the reason the turn is
  // still running would never reach the screen. A watch that returns before
  // it clears anything, because another watch of this operation is already
  // running, leaves the error as it was, and the reason is written the same.
  if (stopFailure !== null) setRecordValue(keeperActionErrors, request.keeperName, stopFailure)
  await settled
}

/** React to a server `keeper_chat_appended` push: re-merge the
 *  persisted transcript so messages arriving through other connectors
 *  (Discord, Slack, agent MCP), plus committed autonomous turns, appear
 *  without a page reload.
 *
 *  A keeper that is not in `hydratedChatKeepers` reaches the guard below
 *  for one of two reasons: (a) its panel was never opened — mount
 *  hydration fetches the full window on first open, so skipping is
 *  correct; (b) an earlier hydration FAILED and rolled the keeper back
 *  out of the set (see the catch in `hydrateKeeperChatHistory`). Case (b)
 *  leaves an OPEN panel blank and, before this branch, dropped every
 *  subsequent append until the panel remounted. When the un-hydrated
 *  keeper is the one the operator is viewing (`activeKeeperName`), we
 *  re-trigger hydration so a recovered server transcript converges into
 *  the panel instead of being dropped. `hydrateKeeperChatHistory` adds
 *  the keeper to `hydratedChatKeepers` before its fetch await, so a burst
 *  of appends collapses into the single in-flight fetch rather than
 *  fanning out one fetch per event.
 *
 *  If the event carries an audio clip, we first try to attach
 *  it to the matching assistant bubble that is already streaming. A
 *  failed match still falls back to the history re-merge (the clip is
 *  persisted server-side too).
 *
 *  [blocks] is accepted so the live push path can carry server-parsed
 *  rich blocks; the current implementation refreshes history (which now
 *  persists blocks) so the dashboard's normalizeHistoryEntry path prefers
 *  them automatically. */
export function noteKeeperChatAppended(name: string, audio?: unknown): void {
  const keeperName = name.trim()
  if (!keeperName) return
  if (!hydratedChatKeepers.has(keeperName)) {
    if (keeperName === activeKeeperName.value.trim()) {
      void hydrateKeeperChatHistory(keeperName, { force: true })
    }
    return
  }
  // Try to attach an audio clip to the streaming assistant bubble,
  // but always fall through to the history re-merge so the transcript stays
  // current even if the clip had no matching text or no content text was
  // generated.
  if (audio != null) {
    attachKeeperAudioClip(keeperName, audio)
  }
  const pending = chatRefreshTimers.get(keeperName)
  if (pending) clearTimeout(pending)
  chatRefreshTimers.set(keeperName, setTimeout(() => {
    chatRefreshTimers.delete(keeperName)
    void (async () => {
      await hydrateKeeperChatHistory(keeperName, { force: true })
    })()
  }, CHAT_APPENDED_REFRESH_DELAY_MS))
}

/** Re-hydrate the chat transcript for the keeper whose conversation panel
 *  is currently open (`activeKeeperName`). No-op when no panel is open.
 *
 *  The route refresh plan calls this. A transcript that is already loaded
 *  stays as it is, and only a failed hydration retries, so route visits do
 *  not re-read the history endpoint. */
export function refreshActiveKeeperChatHistory(): void {
  const keeperName = activeKeeperName.value.trim()
  if (!keeperName) return
  void hydrateKeeperChatHistory(keeperName)
}

/** Fetch the history of every Keeper this view knows again, loaded or not.
 *  After a reconnect the server replay buffer may have dropped complete turns,
 *  including turns of conversations that are not open. The known set is the
 *  Keepers with a recorded hydration state, those with a request in flight,
 *  and the open panel. A Keeper whose fetch failed is named in the error. */
export async function refreshKnownKeeperChatHistories(): Promise<void> {
  const names = new Set([
    ...Object.keys(keeperChatHistoryHydration.value),
    ...chatHistoryHydrationRequests.keys(),
  ])
  const active = activeKeeperName.value.trim()
  if (active) names.add(active)
  const known = Array.from(names)
  await Promise.all(known.map(name => hydrateKeeperChatHistory(name, { force: true })))
  const failed = known.filter(name => keeperChatHistoryErrors.value[name] != null)
  if (failed.length > 0) throw new Error(`Known Keeper history refresh incomplete: ${failed.join(', ')}`)
}

const chatHistoryPageRequests = new Set<string>()

export async function loadFullKeeperHistory(name: string): Promise<void> {
  const keeperName = name.trim()
  if (!keeperName || chatHistoryPageRequests.has(keeperName)) return
  const previous = keeperChatHistoryPages.value[keeperName]
  if (previous && !previous.hasMore) return
  chatHistoryPageRequests.add(keeperName)
  setRecordValue(keeperHydrating, keeperName, true)
  try {
    const page = await fetchKeeperChatHistoryPage(keeperName, previous?.nextCursor ?? undefined)
    const existing = keeperThreads.value[keeperName] ?? []
    const existingById = new Map(existing.map(entry => [entry.id, entry]))
    // Pages carry canonical content and identity but omit stream lifecycle
    // fields. Preserve only that richer observation on an exact existing id.
    const pageEntries = chatHistoryEntriesFromRest(keeperName, page.messages)
      .map(entry => {
        const observed = existingById.get(entry.id)
        return observed?.streamContract
          ? { ...entry, streamContract: observed.streamContract }
          : entry
      })
    const retained = new Map((previous?.entries ?? []).map(entry => [entry.id, entry]))
    for (const entry of pageEntries) retained.set(entry.id, entry)
    keeperChatHistoryPages.value = {
      ...keeperChatHistoryPages.value,
      [keeperName]: {
        entries: [...retained.values()],
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
      },
    }
    const pageIds = new Set(pageEntries.map(entry => entry.id))
    mergeServerHistoryEntries(keeperName, [
      ...pageEntries,
      // Retain canonical tail rows alongside the page. Independent live rows
      // stay in the merge's local partition; promoting them into its canonical
      // input would duplicate an in-flight user entry, even on an empty page.
      ...existing.filter(entry => !pageIds.has(entry.id)
        && (entry.delivery === 'history' || entry.delivery === 'request_failure')),
    ])
    setRecordValue(keeperChatHistoryErrors, keeperName, null)
  } catch (err) {
    if (err instanceof ApiRequestError && err.status === 409) {
      // The physical transcript changed. Retire its cursor and reload the tail;
      // the next explicit older read starts a new server-owned page walk.
      retireKeeperChatHistory(keeperName)
      await hydrateKeeperChatHistory(keeperName, { force: true })
    }
    setRecordValue(keeperChatHistoryErrors, keeperName,
      err instanceof Error ? err.message : '이전 대화를 불러오지 못했습니다')
  } finally {
    chatHistoryPageRequests.delete(keeperName)
    setRecordValue(keeperHydrating, keeperName, false)
  }
}

function userInputMediaKindForAttachment(
  attachment: KeeperConversationAttachment,
): Exclude<KeeperUserInputBlock['type'], 'text'> {
  if (attachment.kind === 'url' || attachment.kind === 'file_id') return 'image'
  if (attachment.type === 'image') return 'image'
  if (attachment.mimeType.startsWith('audio/')) return 'audio'
  return 'document'
}

function attachmentToUserInputBlock(attachment: KeeperConversationAttachment): KeeperUserInputBlock {
  // A reference crosses as its native carrier (#33728): the server's parse
  // accepts exactly one of attachment_id / url / file_id per image block.
  if (attachment.kind === 'url') {
    return { type: 'image', url: attachment.url, ...(attachment.mimeType ? { mimeType: attachment.mimeType } : {}) }
  }
  if (attachment.kind === 'file_id') {
    return { type: 'image', fileId: attachment.fileId, ...(attachment.mimeType ? { mimeType: attachment.mimeType } : {}) }
  }
  return {
    type: userInputMediaKindForAttachment(attachment),
    attachmentId: attachment.id,
    name: attachment.name,
    mimeType: attachment.mimeType,
    size: attachment.size,
  }
}

function deriveUserBlocks(
  prompt: string,
  attachments: KeeperConversationAttachment[] | undefined,
): KeeperUserInputBlock[] | undefined {
  const blocks = attachments?.map(attachmentToUserInputBlock) ?? []
  if (prompt.trim()) blocks.push({ type: 'text', text: prompt })
  return blocks.length > 0 ? blocks : undefined
}

function fallbackMessageForUserBlocks(blocks: KeeperUserInputBlock[]): string {
  const text = blocks
    .filter((block): block is Extract<KeeperUserInputBlock, { type: 'text' }> => block.type === 'text')
    .map(block => block.text)
    .filter(text => text.trim().length > 0)
    .join('\n\n')
  if (text) return text

  const media = blocks.filter(block => block.type !== 'text')
  if (media.length === 0) return ''
  const describeMedia = (block: KeeperUserInputBlock): string => {
    if (block.type === 'text') return ''
    if ('url' in block) return block.url
    if ('fileId' in block) return `file_id ${block.fileId}`
    return block.name
  }
  const names = media
    .slice(0, 3)
    .map(block => describeMedia(block).trim())
    .filter(Boolean)
    .join(', ')
  const suffix = media.length > 3 ? ` 외 ${media.length - 3}개` : ''
  return names
    ? `[첨부 ${media.length}개: ${names}${suffix}]`
    : `[첨부 ${media.length}개]`
}

export async function sendKeeperThreadMessage(
  name: string,
  prompt: string,
  options: {
    attachments?: KeeperConversationAttachment[]
    clientActionId?: string
    clientActionIds?: readonly string[]
    blocks?: ChatBlock[]
    userBlocks?: KeeperUserInputBlock[]
    surfaceContext?: KeeperStreamSurfaceContext
  } = {},
): Promise<void> {
  const keeperName = name.trim()
  const attachments =
    options.attachments && options.attachments.length > 0 ? options.attachments : undefined
  const userBlocks =
    options.userBlocks && options.userBlocks.length > 0
      ? options.userBlocks
      : deriveUserBlocks(prompt, attachments)
  const blocks = options.blocks && options.blocks.length > 0 ? options.blocks : undefined
  const message = prompt.trim() ? prompt : fallbackMessageForUserBlocks(userBlocks ?? [])
  if (!keeperName || !message) return
  const sendKeys = keeperThreadMessageSendKeys(keeperName, [
    options.clientActionId,
    ...(options.clientActionIds ?? []),
  ])
  if (sendKeys.some(key => sendingKeeperThreadMessages.has(key))) return
  sendKeys.forEach(key => sendingKeeperThreadMessages.add(key))
  const localId = `local-${++localIdCounter}-${Date.now()}`
  const assistantId = `reply-${++localIdCounter}-${Date.now()}`
  const operationId = newKeeperChatOperationId()
  appendThreadEntry(keeperName, {
    id: localId,
    role: 'user',
    deliveryProvenance: operationDeliveryProvenance(operationId, 'accepted_user'),
    source: 'direct_user',
    label: 'You',
    text: message,
    timestamp: new Date().toISOString(),
    delivery: 'sending',
    streamState: null,
    streamContract: keeperStreamContract('client_local_send', 'client_placeholder', {
      reason: 'local optimistic user row before server history confirmation',
    }),
    attachments,
    userBlocks,
    blocks,
    details: null,
  })
  appendThreadEntry(keeperName, {
    id: assistantId,
    role: 'assistant',
    deliveryProvenance: operationDeliveryProvenance(operationId, 'terminal_result'),
    source: 'direct_assistant',
    label: keeperName,
    text: '',
    rawText: '',
    timestamp: null,
    delivery: 'sending',
    streamState: 'opening',
    streamContract: keeperStreamContract('client_local_send', 'client_placeholder', {
      reason: 'local assistant placeholder before stream event',
    }),
    details: null,
  })
  setRecordValue(keeperSending, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  setRecordValue(keeperStreamStartedAt, keeperName, Date.now())
  const controller = new AbortController()
  setActiveStream(keeperName, operationId, assistantId, controller)
  let operationAccepted = false
  let toolCallEnded = false
  let droppedFrame: string | null = null
  let queuedOperationObserver: (() => void) | null = null
  let queuedOperationObservationStarted = false
  const stopQueuedOperationObserver = () => {
    queuedOperationObserver?.()
    queuedOperationObserver = null
  }
  try {
    finalizeAssistantEntry(keeperName, localId, { delivery: 'delivered' })

    const outcome = await streamKeeperMessage(keeperName, message, {
      operationId,
      signal: controller.signal,
      attachments,
      userBlocks,
      surfaceContext: options.surfaceContext,
      onDecodeError: reason => {
        droppedFrame ??= reason
        failKeeperStreamOperation(keeperName, assistantId, reason)
      },
      onEvent: (event, sequence) => {
        markKeeperStreamSignal(keeperName)
        let stopWasHeld = false
        if (
          event.type === 'CUSTOM'
          && event.name === 'KEEPER_CHAT_OPERATION_ACCEPTED'
        ) {
          const acceptedOperationId = event.value.operation_id.trim()
          if (!acceptedOperationId || acceptedOperationId !== operationId) {
            throw new Error('Keeper operation acceptance identity mismatch')
          }
          operationAccepted = true
          markLiveSendRequestAccepted(acceptedOperationId)
          stopWasHeld = endAcceptanceWait(keeperName, operationId)
          upsertTrackedKeeperChatOperation({
            operationId: acceptedOperationId,
            keeperName,
            message,
            submittedAt: Date.now(),
            ...(attachments ? { attachments } : {}),
          })
          if (!queuedOperationObservationStarted) {
            queuedOperationObservationStarted = true
            const authority = executionWorkspaceAuthority.peek()
            const authRevision = currentStoredTokenRevision()
            queuedOperationObserver = observeKeeperChatOperation(keeperName, operationId, {
              signal: controller.signal,
              current: () => authority === executionWorkspaceAuthority.peek()
                && authRevision === currentStoredTokenRevision(),
              onOperation: operation => {
                if (operation.state.kind === 'queued' || operation.state.kind === 'running') {
                  notePendingOperation(keeperName, assistantId, operation)
                } else stopQueuedOperationObserver()
              },
            })
          }
        }
        const error = applyKeeperLiveSendEvent(
          keeperName,
          assistantId,
          { operationId, sequence, event },
        )
        // The server holds the operation, so the stop the operator pressed
        // before this frame goes out the way a stop pressed after it does. That
        // closes this stream: the frames behind the acceptance are not read.
        if (stopWasHeld) {
          void cancelActiveKeeperThreadMessage(keeperName)
          controller.signal.throwIfAborted()
        }
        if (event.type === 'RUN_FINISHED' || event.type === 'RUN_ERROR') {
          // The direct reader cancels itself on the terminal event, while
          // clearActiveStream in the send tail still holds live-send
          // ownership through the remaining bookkeeping. The server
          // broadcasts every operation event before publishing it to the
          // direct sink, so a post-terminal tool frame can land on the
          // observer connection in this interval; with ownership still
          // held the broadcast guard discards it and the canceled direct
          // stream never carries it. Release at the terminal event itself.
          releaseLiveSendRequest(operationId)
        }
        // First reply-bearing event: the stream itself is the liveness
        // signal now — retire the queued operation observer.
        if (
          event.type === 'TEXT_MESSAGE_CONTENT'
          || event.type === 'TOOL_CALL_START'
          || event.type === 'RUN_FINISHED'
          || event.type === 'RUN_ERROR'
        ) {
          stopQueuedOperationObserver()
        }
        if (error) {
          throw new Error(error)
        }
        persistTrackedOperationAssistantDraft(
          keeperName,
          operationAccepted ? operationId : null,
          assistantId,
        )
        if (event.type === 'TOOL_CALL_END') {
          toolCallEnded = true
        }
        if (event.type === 'CUSTOM' && event.name === 'KEEPER_TOOL_RESULT_READY') {
          void hydrateKeeperToolOutputs(keeperName)
        }
      },
    })

    flushPendingKeeperStreamDeltas(keeperName, assistantId)
    // The reply is read from the row that holds it now, resolved once here.
    // Only the placeholder this send created is settled by the tail. A stored
    // row that history put in its place is the server's record of the reply,
    // so its text, time and delivery stay as stored, the same rule its frames
    // follow. With no row left there is nothing to settle and the reply reads
    // as empty, as it did when the tail looked the placeholder up by id.
    const reply = keeperLiveSendReplyRow(keeperName, assistantId, operationId)
    const finalEntry = reply.kind === 'absent' ? null : reply.entry
    const settlePlaceholder = (patch: Partial<KeeperConversationEntry>): void => {
      if (reply.kind === 'placeholder') finalizeAssistantEntry(keeperName, assistantId, patch)
    }
    const finalText = finalEntry?.text ?? ''
    const hasFinalText = finalText.trim().length > 0

    // A stream that dropped a frame is as incomplete as one that was cut: the
    // finished operation, not this partial text, is the reply.
    if (!outcome.terminal || droppedFrame !== null) {
      if (operationAccepted) {
        const handoff: TrackedKeeperChatOperation = {
          operationId,
          keeperName,
          message,
          submittedAt: Date.now(),
          ...(attachments ? { attachments } : {}),
        }
        // A dropped frame keeps its partial reply and failure with the
        // handoff: if the stored transcript cannot replace them, they are
        // all the panel has, and they must not read as a delivered reply.
        const request = droppedFrame !== null
          ? withCurrentTrackedOperationAssistantDraft(handoff, assistantId)
          : handoff
        removeThreadEntries(keeperName, [localId, assistantId])
        // Hand off to resume: release ownership FIRST so our own resume
        // call below is not blocked by the guard we just set.
        releaseLiveSendRequest(operationId)
        await hydrateTrackedKeeperChatOperation(request)
        return
      }
      // The SSE connection closed without RUN_FINISHED / RUN_ERROR —
      // keep the partial text but mark the entry so the operator can
      // tell a cut stream from a completed reply.
      const cutMessage = droppedFrame ?? '스트림이 종료 신호 없이 끊겼습니다. 응답이 불완전할 수 있습니다.'
      settlePlaceholder({
        text: finalText,
        delivery: 'interrupted',
        streamState: null,
        timestamp: new Date().toISOString(),
        error: cutMessage,
        streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
          reason: cutMessage,
        }),
      })
      setRecordValue(keeperActionErrors, keeperName, cutMessage)
      if (toolCallEnded) void hydrateKeeperToolOutputs(keeperName)
      return
    }

    // A finished stream whose frames typed the turn is not judged again by its
    // text. The server sends RUN_FINISHED after KEEPER_REPLY_DETAILS only for a
    // turn it does not fail, and some of those have no text: a reply with
    // blocks to show (media), a reply a surface post delivered, a checkpoint. A
    // turn with nothing to show ends in RUN_ERROR. Those frames settled the
    // placeholder. A media-only reply is stored before the last frame, so its
    // blocks arrive with the next history read. The placeholder gets its finish
    // time here, as every settled row does, and is otherwise left as the frames
    // left it. A stored row already in its place is the server's record of the
    // reply and stays as stored.
    if (
      reply.kind === 'replaced'
      || (reply.kind === 'placeholder' && reply.entry.details?.turnOutcome != null)
    ) {
      settlePlaceholder({ timestamp: new Date().toISOString() })
      if (toolCallEnded) void hydrateKeeperToolOutputs(keeperName)
      if (operationAccepted) {
        removeTrackedKeeperChatOperation(operationId)
      }
      return
    }

    // What is left finished without typing its turn: a cancelled stream, one
    // that asks for reconciliation, or one whose details frame did not apply.
    // Its text is all there is to judge it by.
    const finalDelivery = 'delivered' as KeeperConversationDelivery
    if (!hasFinalText && !toolCallEnded) {
      settlePlaceholder({
        text: EMPTY_VISIBLE_REPLY_TEXT,
        rawText: finalEntry?.rawText || EMPTY_VISIBLE_REPLY_TEXT,
        delivery: 'error',
        streamState: null,
        timestamp: new Date().toISOString(),
        error: EMPTY_VISIBLE_REPLY_TEXT,
        streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
          reason: EMPTY_VISIBLE_REPLY_TEXT,
        }),
      })
      setRecordValue(keeperActionErrors, keeperName, EMPTY_VISIBLE_REPLY_TEXT)
      if (operationAccepted) {
        removeTrackedKeeperChatOperation(operationId)
      }
      return
    }

    settlePlaceholder({
      text: hasFinalText ? finalText : TOOL_ONLY_EMPTY_REPLY_TEXT,
      delivery: finalDelivery,
      streamState: null,
      timestamp: new Date().toISOString(),
      error: null,
      streamContract: keeperStreamContract('sse_event', 'backend_terminal_event', {
        eventName: 'RUN_FINISHED',
      }),
    })
    if (toolCallEnded) void hydrateKeeperToolOutputs(keeperName)
    if (operationAccepted) {
      removeTrackedKeeperChatOperation(operationId)
    }
  } catch (err) {
    // The stream is read no further. A send that failed stays listed while it
    // reads the stored history below, and a stop pressed in that time has no
    // acceptance to wait for. A stop held until now is dropped.
    endAcceptanceWait(keeperName, operationId)
    flushPendingKeeperStreamDeltas(keeperName, assistantId)
    // A stop aborts this stream only after the acceptance, where it also goes
    // to the server. An abort before it asked the server nothing: the operator
    // closed the send instead of waiting, or the abort came from somewhere else
    // and is a failed send like any other. Both are settled below, and neither
    // row says cancelled for an operation the server was never asked to stop.
    if (operationAccepted && isAbortError(err)) {
      const durablePendingRequest = trackedKeeperChatOperationsForKeeper(keeperName)
        .find(candidate => candidate.operationId === operationId) ?? null
      const shouldAttemptServerCancel =
        liveSendOwnsRequest(operationId) || durablePendingRequest !== null
      const serverCancelAlreadyFinalized = !shouldAttemptServerCancel
      if (shouldAttemptServerCancel) {
        const pendingRequest = withCurrentTrackedOperationAssistantDraft(durablePendingRequest ?? {
          operationId,
          keeperName,
          message,
          submittedAt: Date.now(),
          ...(attachments ? { attachments } : {}),
        }, assistantId)
        upsertTrackedKeeperChatOperation(pendingRequest)
        // Aborting the browser stream does not prove the server stopped.
        // Keep the accepted operation until its cancellation is confirmed.
        finalizeAssistantEntry(keeperName, assistantId, {
          streamState: 'cancelling',
          error: null,
        })
        const stop = await cancelKeeperThreadRequest(keeperName, operationId)
        if (stop.kind !== 'cancelled') {
          await handoffCancelledStreamToOperationHydration(
            pendingRequest,
            [localId, assistantId],
            stop.kind === 'not_stopped' ? stop.message : null,
          )
          throw err
        }
      }
      finalizeAssistantEntry(keeperName, localId, {
        delivery: 'cancelled',
        error: null,
        streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
          requestId: operationId,
          reason: KEEPER_MESSAGE_CANCELLED_TEXT,
        }),
      })
      finalizeAssistantEntry(keeperName, assistantId, {
        delivery: 'cancelled',
        streamState: null,
        error: null,
        timestamp: new Date().toISOString(),
        streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
          requestId: operationId,
          reason: KEEPER_MESSAGE_CANCELLED_TEXT,
        }),
      })
      if (serverCancelAlreadyFinalized) setRecordValue(keeperActionErrors, keeperName, null)
      throw err
    }

    // The operator closed this send while its stop waited for the acceptance.
    // The send did not fail and the server was asked nothing, so the reply row
    // says neither error nor cancelled: it says what was closed and what the
    // Dashboard does not know. Who closed the stream is read from this send's
    // own signal. The value the stream threw is the browser's.
    const signalReason: unknown = controller.signal.reason
    const operatorClose =
      signalReason instanceof KeeperSendClosedBeforeAcceptance ? signalReason : null
    const failureMessage =
      err instanceof Error ? err.message : `Failed to send direct message to ${keeperName}`
    const errorMessage = operatorClose
      ? KEEPER_SEND_CLOSED_BEFORE_ACCEPTANCE_TEXT
      : failureMessage
    finalizeAssistantEntry(keeperName, assistantId, {
      delivery: operatorClose ? 'interrupted' : 'error',
      streamState: null,
      error: errorMessage,
      timestamp: new Date().toISOString(),
      streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
        requestId: operationAccepted ? operationId : undefined,
        reason: errorMessage,
      }),
    })
    // The assistant placeholder is the single transcript owner of a stream
    // failure. Keep the optimistic user message as a delivered input row;
    // marking both rows as errors produced two identical red error cards for
    // one failed HTTP request.
    finalizeAssistantEntry(keeperName, localId, {
      delivery: 'delivered',
      error: null,
      streamContract: keeperStreamContract('client_stream_failure', 'contract_gap', {
        requestId: operationAccepted ? operationId : undefined,
        reason: errorMessage,
      }),
    })
    // A send the operator closed leaves here. It raises no action error: the
    // reply row carries what happened. It does not read the stored history
    // first either. That read asks the server the operator stopped waiting
    // for, and the composer stays busy until it answers or times out.
    if (operatorClose) throw operatorClose
    try {
      const reconciled = await reconcileOperationFromServerHistory(
        keeperName,
        operationId,
        localId,
        assistantId,
      )
      if (reconciled) {
        setRecordValue(keeperActionErrors, keeperName, null)
        return
      }
    } catch (reconcileErr) {
      console.warn(
        `[keeper] stream failure history reconciliation failed for ${keeperName}`,
        reconcileErr instanceof Error ? reconcileErr.message : reconcileErr,
      )
    }
    setRecordValue(keeperActionErrors, keeperName, errorMessage)
    throw err
  } finally {
    // The queued-operation observer (Gap B above) must never outlive this send:
    // every exit path stops it here even if no reply event ever arrived.
    stopQueuedOperationObserver()
    // Release cancellation bookkeeping on every accepted exit. The exact
    // operation ownership is released once by clearActiveStream below; the
    // non-terminal handoff released it early so its own resume was not blocked.
    if (operationAccepted) {
      releaseKeeperThreadCancelTracking(operationId)
    }
    sendKeys.forEach(key => sendingKeeperThreadMessages.delete(key))
    clearActiveStream(keeperName, operationId)
    if (activeStreamEntryId(keeperName) === null) {
      setRecordValue(keeperSending, keeperName, false)
      setRecordValue(keeperStreamStartedAt, keeperName, null)
      clearKeeperStreamSignal(keeperName)
    }
    // No refreshDashboardState() here: forcing a full dashboard
    // refetch after every chat message re-rendered every panel and was
    // the main "the screen keeps refreshing" complaint. Keeper status
    // updates arrive through the WS/SSE live path instead.
  }
}

export async function probeKeeperRuntime(name: string, actor: string): Promise<KeeperDiagnostic | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  setRecordValue(keeperProbing, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: keeperName,
      payload: {},
    })
    const result = normalizeKeeperProbeResult(response.result)
    const diagnostic = result?.diagnostic ?? null
    if (diagnostic) {
      const existing = keeperStatusDetails.value[keeperName]
      setStatusDetail(keeperName, {
        name: keeperName,
        diagnostic,
        history: existing?.history ?? keeperThreads.value[keeperName] ?? [],
        rawText: existing?.rawText ?? '',
        rawStatus: response.result,
        loadedAt: new Date().toISOString(),
      })
    }
    await refreshDashboardState()
    return diagnostic
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to probe ${keeperName}`
    console.warn(`[keeper] probe failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperProbing, keeperName, false)
  }
}

export async function recoverKeeperRuntime(name: string, actor: string): Promise<KeeperDiagnostic | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  setRecordValue(keeperRecovering, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'keeper_recover',
      target_type: 'keeper',
      target_id: keeperName,
      payload: {},
    })
    const result = normalizeKeeperRecoverResult(response.result)
    const after = result?.after ?? null
    if (after) {
      const existing = keeperStatusDetails.value[keeperName]
      setStatusDetail(keeperName, {
        name: keeperName,
        diagnostic: after,
        history: existing?.history ?? keeperThreads.value[keeperName] ?? [],
        rawText: existing?.rawText ?? '',
        rawStatus: response.result,
        loadedAt: new Date().toISOString(),
      })
    }
    await refreshDashboardState()
    return after
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to recover ${keeperName}`
    console.warn(`[keeper] recovery failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperRecovering, keeperName, false)
  }
}
