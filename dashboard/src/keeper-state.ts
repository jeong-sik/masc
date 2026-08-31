import { signal } from '@preact/signals'
import { formatKeeperVisibleReply } from './keeper-message'
import { parseTextToChatBlocks } from './lib/chat-blocks'
import { isInFlightDelivery } from './lib/keeper-delivery'
import { isRecord, asString, asNumber, asBoolean, toIsoTimestamp } from './components/common/normalize'
import { asStrictStringArray, withoutUndefined } from './lib/json-coerce'
import { keeperStreamContract, normalizeStreamContract } from './keeper-stream-contract'
import {
  sameDeliveryProvenance,
  type KeeperChatDeliveryProvenance,
  type KeeperChatDeliveryProvenanceDecode,
} from './keeper-delivery-provenance'
import {
  nonBlankToolCallId,
} from './tool-call-output-store'
import type {
  KeeperConversationAttachment,
  KeeperConversationAudioClip,
  KeeperConversationEntry,
  KeeperConversationRole,
  KeeperApprovalLifecycle,
  KeeperApprovalLifecyclePhase,
  KeeperConversationSource,
  KeeperConversationStreamContract,
  KeeperConversationStreamState,
  KeeperConversationDelivery,
  KeeperDiagnostic,
  KeeperProbeResult,
  KeeperRecoverResult,
  KeeperStatusDetail,
  SurfaceRef,
  SurfaceRefKind,
  ChatBlock,
  ChatBroadcastRecipient,
  ChatShellLine,
  ChatTableCellValue,
  ChatTraceStep,
  KeeperToolApprovalPending,
} from './types'

// --- Signals ---

export const activeKeeperName = signal('')
export const keeperStatusDetails = signal<Record<string, KeeperStatusDetail>>({})
export const keeperThreads = signal<Record<string, KeeperConversationEntry[]>>({})
export const keeperHydrating = signal<Record<string, boolean>>({})
export const keeperSending = signal<Record<string, boolean>>({})
export const keeperProbing = signal<Record<string, boolean>>({})
export const keeperRecovering = signal<Record<string, boolean>>({})
export const keeperActionErrors = signal<Record<string, string | null>>({})
export const keeperStreamStartedAt = signal<Record<string, number | null>>({})
// Wall-clock ms of the most recent SSE event observed for an in-flight
// stream. Drives the stall indicator (streaming but no events for N s).
export const keeperStreamLastEventAt = signal<Record<string, number | null>>({})

// Tool calls each keeper is holding for an operator decision, keyed by keeper
// then tool_call_id. Minted by KEEPER_TOOL_APPROVAL_REQUESTED, retired by
// KEEPER_TOOL_APPROVAL_SETTLED or a server-side timeout settle; the pending
// GET listing re-hydrates waits whose owning stream watcher is gone
// (masc#30034). This is UI state only — the server registry is the SSOT.
export const keeperToolApprovals = signal<Record<string, Record<string, KeeperToolApprovalPending>>>({})

// Thread entries kept per keeper. History beyond this window stays
// available server-side (keeper_chat/<name>.jsonl, GET /chat/history).
export const THREAD_ENTRY_CAP = 200

// --- Private stream tracking ---

interface KeeperActiveStream {
  entryId: string
  controller: AbortController
}

// keeperName -> operationId -> stream. Map insertion order is the owner FIFO
// order, so the first entry is the currently runnable operation and later
// entries remain independently cancellable while queued.
const keeperActiveStreams = new Map<string, Map<string, KeeperActiveStream>>()
// requestId -> keeperName: which queued requests a live in-session send
// stream currently owns. Resume defers to this so an SPA remount does not
// spin up a second handler/entry for a request the live send already drives.
// Active stream request lookup is derived from this map to avoid maintaining
// a second inverse keeperName -> requestId structure in lockstep.
// Module state, so it survives unmount/remount exactly like the controller
// maps above; a full page reload resets it, leaving cold-start resume intact.
const liveSendRequestOwners = new Map<string, string>()
// A locally minted id is owned before the POST starts so observer broadcasts
// cannot race the direct stream. Server-side mutation is safe only after the
// direct stream has observed KEEPER_CHAT_OPERATION_ACCEPTED, so keep that
// stronger fact independently.
const acceptedLiveSendRequestIds = new Set<string>()

export function _resetActiveKeeperStreamsForTests(): void {
  keeperActiveStreams.clear()
}

// --- Helpers ---

export function setRecordValue<T>(state: typeof keeperThreads | typeof keeperHydrating | typeof keeperSending | typeof keeperProbing | typeof keeperRecovering | typeof keeperActionErrors | typeof keeperStreamStartedAt, key: string, value: T): void {
  state.value = {
    ...state.value,
    [key]: value,
  } as typeof state.value
}

function normalizeRole(value: unknown): KeeperConversationRole {
  const role = asString(value)?.toLowerCase()
  if (role === 'user' || role === 'assistant' || role === 'system' || role === 'tool') return role
  return 'other'
}

function roleLabel(role: KeeperConversationRole): string {
  switch (role) {
    case 'user':
      return '사용자'
    case 'assistant':
      return 'Keeper'
    case 'system':
      return 'System'
    case 'tool':
      return 'Tool'
    default:
      return 'Event'
  }
}

function looksLikeWorldStatePrompt(text: string): boolean {
  const trimmed = text.trim()
  return trimmed.startsWith('## Current World State')
    || (trimmed.includes('### Workspace State') && trimmed.includes('### Context'))
}

function normalizeConversationSource(
  value: unknown,
  role: KeeperConversationRole,
  rawText: string,
  previousSource: KeeperConversationSource | null,
): KeeperConversationSource {
  const source = asString(value)?.trim()
  if (
    source === 'direct_user'
    || source === 'direct_assistant'
    || source === 'world_state_prompt'
    || source === 'internal_assistant'
    || source === 'tool_result'
    || source === 'system'
    || source === 'unknown'
  ) {
    return source
  }

  if (role === 'tool') return 'tool_result'
  if (role === 'system') return 'system'
  if (role === 'user') {
    return looksLikeWorldStatePrompt(rawText) ? 'world_state_prompt' : 'direct_user'
  }
  if (role === 'assistant') {
    return previousSource === 'world_state_prompt' ? 'internal_assistant' : 'direct_assistant'
  }
  return 'unknown'
}

export function isVisibleDirectConversationEntry(entry: KeeperConversationEntry): boolean {
  if (entry.role !== 'user' && entry.role !== 'assistant') return false
  return entry.source !== 'world_state_prompt'
    && entry.source !== 'internal_assistant'
    // An autonomous turn is visible by default but is not direct conversation:
    // nobody addressed the keeper. It stays out of this predicate so callers
    // asking "is this part of the dialogue" keep getting the same answer.
    && entry.source !== 'autonomous_turn'
    && entry.source !== 'tool_result'
    && entry.source !== 'system'
}

/** Turns the keeper ran on its own. Their semantic conversation is persisted
 *  in the Agent Core checkpoint; typed turn records provide a stable dashboard
 *  projection without duplicating it into the chat store. Shown without the
 *  internal toggle and folded into one collapsed group. */
export function isAutonomousTurnEntry(entry: KeeperConversationEntry): boolean {
  return entry.source === 'autonomous_turn'
}

function capThreadEntries(entries: KeeperConversationEntry[]): KeeperConversationEntry[] {
  let conversationSlots = THREAD_ENTRY_CAP
  const kept: KeeperConversationEntry[] = []
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index]
    if (!entry) continue
    const doesNotConsumeConversationSlot =
      isAutonomousTurnEntry(entry) || entry.approvalLifecycle != null
    if (doesNotConsumeConversationSlot || conversationSlots > 0) {
      kept.push(entry)
      if (!doesNotConsumeConversationSlot) conversationSlots -= 1
    }
  }
  return kept.reverse()
}

/** Tool-call rows (role 'tool', minted live by keeper-stream and persisted to
 *  history). They are part of the keeper's visible work product, not internal
 *  prompt plumbing, so the transcript surfaces them (folded into a "작업 과정"
 *  card by groupToolCalls). */
export function isToolConversationEntry(entry: KeeperConversationEntry): boolean {
  return entry.role === 'tool'
}

/** Entries shown when the internal-message toggle is off: direct user/assistant
 *  turns plus tool-call rows. Only the truly-internal sources
 *  (world_state_prompt, internal_assistant, system) stay behind the toggle. */
export function isDefaultVisibleConversationEntry(entry: KeeperConversationEntry): boolean {
  return isVisibleDirectConversationEntry(entry)
    || isToolConversationEntry(entry)
    || isAutonomousTurnEntry(entry)
    || entry.approvalLifecycle != null
}

const APPROVAL_LIFECYCLE_PHASES = new Set<KeeperApprovalLifecyclePhase>([
  'resolved_approved',
  'resolved_rejected',
  'replay_applied',
  'replay_applied_with_warning',
  'replay_failed',
  'replay_indeterminate',
  'continuation_recorded',
])

function normalizeApprovalLifecycle(raw: unknown): KeeperApprovalLifecycle | null {
  if (!isRecord(raw)) return null
  const approvalId = asString(raw.approval_id)?.trim() ?? ''
  const phase = asString(raw.phase) as KeeperApprovalLifecyclePhase | undefined
  if (!approvalId || !phase || !APPROVAL_LIFECYCLE_PHASES.has(phase)) return null
  const artifact = isRecord(raw.artifact_ref) && isRecord(raw.artifact_ref._blob)
    ? raw.artifact_ref._blob
    : null
  return {
    approvalId,
    toolName: asString(raw.tool_name) ?? null,
    phase,
    artifactSha256: artifact ? asString(artifact.sha256) ?? null : null,
  }
}

// --- Audio helpers (RFC-0235 P1/P3) ---

/** Canonicalize an audio clip from the wire into the dashboard type.
 *  Accepts both snake_case (history rows) and camelCase (SSE payloads).
 *  Falls back to `/api/v1/voice/audio/<token>` when the backend did not
 *  emit a full URL, so every persisted clip is playable. */
export function normalizeAudioClip(raw: unknown): KeeperConversationAudioClip | null {
  if (!isRecord(raw)) return null
  const token = asString(raw.token)
  const mime = asString(raw.mime)
  if (!token || !mime) return null
  const explicitUrl = asString(raw.audio_url) ?? asString(raw.audioUrl)
  const audioUrl = explicitUrl && explicitUrl.trim() !== ''
    ? explicitUrl
    : `/api/v1/voice/audio/${encodeURIComponent(token)}`
  const duration = asNumber(raw.duration_sec) ?? asNumber(raw.durationSec)
  const messageText = asString(raw.message_text) ?? asString(raw.messageText) ?? ''
  const deviceId = asString(raw.device_id) ?? asString(raw.deviceId)
  const expired = asBoolean(raw.expired) ?? null
  return {
    token,
    audioUrl,
    mime,
    durationSec: duration ?? null,
    messageText,
    deviceId: deviceId ?? null,
    expired,
  }
}

/** Normalize one persisted attachment row (keeper_chat_store snake_case
 *  mime_type, open `type` string) into the camelCase KeeperConversationAttachment
 *  the chat UI renders. Drops rows missing id/data — a card with no payload is
 *  not renderable. `type` is narrowed to image/file (the renderer's union). */
function normalizeAttachment(raw: unknown): KeeperConversationAttachment | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const data = asString(raw.data)
  if (!id || !data) return null
  return {
    id,
    type: asString(raw.type) === 'image' ? 'image' : 'file',
    name: asString(raw.name) ?? '',
    size: asNumber(raw.size) ?? 0,
    mimeType: asString(raw.mime_type) ?? asString(raw.mimeType) ?? '',
    data,
  }
}

function normalizeAttachments(raw: unknown): KeeperConversationAttachment[] | undefined {
  if (!Array.isArray(raw)) return undefined
  const atts = raw
    .map(normalizeAttachment)
    .filter((a): a is KeeperConversationAttachment => a !== null)
  return atts.length > 0 ? atts : undefined
}

function normalizeTableCell(raw: unknown): ChatTableCellValue | null {
  const text = asString(raw)
  if (text !== undefined) return text
  if (!isRecord(raw)) return null
  const v = asString(raw.v)
  if (v === undefined) return null
  return withoutUndefined({
    v,
    num: asBoolean(raw.num) ?? undefined,
    muted: asBoolean(raw.muted) ?? undefined,
  })
}

function normalizeTableCells(raw: unknown): ChatTableCellValue[] | null {
  if (!Array.isArray(raw)) return null
  const cells = raw.map(normalizeTableCell)
  if (cells.some((cell) => cell === null)) return null
  return cells as ChatTableCellValue[]
}

function normalizeTableRows(raw: unknown): ChatTableCellValue[][] | null {
  if (!Array.isArray(raw)) return null
  const rows = raw.map(normalizeTableCells)
  if (rows.some((row) => row === null)) return null
  return rows as ChatTableCellValue[][]
}

function normalizeShellLine(raw: unknown): ChatShellLine | null {
  if (!isRecord(raw)) return null
  const v = asString(raw.v)
  if (v === undefined) return null
  const t = asString(raw.t)
  const lineType: ChatShellLine['t'] = t === 'cmd' || t === 'out' || t === 'err' ? t : undefined
  return withoutUndefined({
    v,
    t: lineType,
  })
}

function normalizeShellLines(raw: unknown): ChatShellLine[] | null {
  if (!Array.isArray(raw)) return null
  const lines = raw.map(normalizeShellLine)
  if (lines.some((line) => line === null)) return null
  return lines as ChatShellLine[]
}

function normalizeNumberArray(raw: unknown): number[] | null {
  if (!Array.isArray(raw)) return null
  const values = raw.map(asNumber)
  if (values.some((value) => value === undefined)) return null
  return values as number[]
}

function normalizeTracePayload(raw: unknown): string | undefined {
  if (raw === undefined || raw === null) return undefined
  if (typeof raw === 'string') return raw
  try {
    const encoded = JSON.stringify(raw, null, 2)
    return encoded === undefined ? String(raw) : encoded
  } catch {
    return String(raw)
  }
}

function normalizeTraceStep(raw: unknown): ChatTraceStep | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  if (kind === 'think') {
    // The withheld flag is the discriminator, and it has to be read before
    // `text`: a withheld step carries "" by contract, and `asString` reports an
    // empty string as absent, which would drop the step — and with it the whole
    // trace, since `normalizeTraceSteps` nulls the array if any step is null.
    const contentWithheld = raw.content_withheld === true || raw.contentWithheld === true
    if (contentWithheld) {
      return withoutUndefined({
        kind,
        text: '',
        contentWithheld: true,
        ts: asString(raw.ts),
        agentCoreBlockIndex: asNumber(raw.agentCoreBlockIndex) ?? asNumber(raw.agent_core_block_index) ?? undefined,
      })
    }
    const text = asString(raw.text)
    return text !== undefined
      ? withoutUndefined({
          kind,
          text,
          ts: asString(raw.ts),
          agentCoreBlockIndex: asNumber(raw.agentCoreBlockIndex) ?? asNumber(raw.agent_core_block_index) ?? undefined,
        })
      : null
  }
  if (kind === 'reason') {
    const text = asString(raw.text)
    return text !== undefined
      ? withoutUndefined({ kind: 'reason', text, detail: asString(raw.detail) ?? undefined, ts: asString(raw.ts) })
      : null
  }
  if (kind === 'progress') {
    const text = asString(raw.text)
    return text !== undefined
      ? withoutUndefined({
          kind: 'progress',
          text,
          ts: asString(raw.ts),
          agentCoreBlockIndex: asNumber(raw.agentCoreBlockIndex) ?? asNumber(raw.agent_core_block_index) ?? undefined,
        })
      : null
  }
  if (kind === 'tool') {
    const name = asString(raw.name)
    if (name === undefined) return null
    const status = asString(raw.status)
    const toolStatus: 'pending' | 'ok' | 'err' | undefined =
      status === 'pending' || status === 'ok' || status === 'err' ? status : undefined
    return withoutUndefined({
      kind: 'tool',
      name,
      toolCallId: asString(raw.toolCallId) ?? asString(raw.tool_call_id) ?? undefined,
      executionId: asString(raw.executionId) ?? asString(raw.execution_id) ?? undefined,
      status: toolStatus,
      dur: asString(raw.dur) ?? undefined,
      args: normalizeTracePayload(raw.args),
      result: normalizeTracePayload(raw.result),
      ts: asString(raw.ts) ?? undefined,
      agentCoreBlockIndex: asNumber(raw.agentCoreBlockIndex) ?? asNumber(raw.agent_core_block_index) ?? undefined,
    })
  }
  return null
}

function normalizeTraceSteps(raw: unknown): ChatTraceStep[] | null {
  if (!Array.isArray(raw)) return null
  const steps = raw.map(normalizeTraceStep)
  if (steps.some((step) => step === null)) return null
  return steps as ChatTraceStep[]
}

function normalizeBroadcastRecipient(raw: unknown): ChatBroadcastRecipient | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const ack = asString(raw.ack)
  if (id === undefined || ack === undefined) return null
  return withoutUndefined({ id, ack, at: asString(raw.at) ?? undefined })
}

function normalizeBroadcastRecipients(raw: unknown): ChatBroadcastRecipient[] | null {
  if (!Array.isArray(raw)) return null
  const recipients = raw.map(normalizeBroadcastRecipient)
  if (recipients.some((recipient) => recipient === null)) return null
  return recipients as ChatBroadcastRecipient[]
}

function normalizeUserChatBlock(block: ChatBlock): ChatBlock | null {
  if (block.t === 'image' || block.t === 'voice') return block
  if (block.t === 'attach') {
    return withoutUndefined({
      t: 'attach',
      name: block.name,
      dims: block.dims,
      src: block.src,
      ph: block.ph,
      via: block.via,
      size: block.size,
      sizeBytes: block.sizeBytes,
      id: block.id,
      kind: block.kind,
    })
  }
  return null
}

function isUserChatBlockType(t: string): boolean {
  return t === 'attach' || t === 'image' || t === 'voice'
}

/** Normalize server-provided rich chat blocks. Keep the accepted wire shape
 *  aligned with the renderer's ChatBlock union; unknown or malformed shapes
 *  are dropped so the caller can fall back to local text parsing. User rows are
 *  constrained to attachment/media blocks because history is untrusted input at
 *  the dashboard boundary. */
function normalizeBlocks(raw: unknown, role: KeeperConversationRole): ChatBlock[] | undefined {
  if (!Array.isArray(raw)) return undefined
  const blocks = raw
    .map((item): ChatBlock | null => {
      if (!isRecord(item)) return null
      const t = asString(item.t)
      if (t === undefined) return null
      if (role === 'user' && !isUserChatBlockType(t)) return null
      if (role !== 'user' && role !== 'assistant' && role !== 'system') return null
      if (t === 'p') {
        const html = asString(item.html)
        return html ? { t: 'p', html } : null
      }
      if (t === 'h4') {
        const html = asString(item.html)
        return html ? { t: 'h4', html } : null
      }
      if (t === 'status') {
        const kind = asString(item.kind)
        return kind === 'continuation_checkpoint' || kind === 'external_effect_pending'
          ? { t: 'status', kind }
          : null
      }
      if (t === 'ul') {
        const items = asStrictStringArray(item.items)
        return items && items.length > 0 ? { t: 'ul', items } : null
      }
      if (t === 'callout') {
        const html = asString(item.html)
        const severity = asString(item.severity)
        return html
          ? withoutUndefined({
              t: 'callout',
              severity: severity === 'info' || severity === 'warn' || severity === 'bad'
                ? severity
                : undefined,
              html,
            })
          : null
      }
      if (t === 'table') {
        const head = normalizeTableCells(item.head)
        const rows = normalizeTableRows(item.rows)
        return head && rows ? { t: 'table', head, rows } : null
      }
      if (t === 'code') {
        const html = asString(item.html)
        return html !== undefined
          ? withoutUndefined({
              t: 'code',
              cap: asString(item.cap) ?? undefined,
              html,
              source: asString(item.source) ?? undefined,
            })
          : null
      }
      if (t === 'shell') {
        const lines = normalizeShellLines(item.lines)
        return lines && lines.length > 0
          ? withoutUndefined({
              t: 'shell',
              title: asString(item.title) ?? undefined,
              lines,
              exit: asNumber(item.exit) ?? undefined,
              dur: asString(item.dur) ?? undefined,
            })
          : null
      }
      if (t === 'artifact') {
        const name = asString(item.name)
        return name
          ? withoutUndefined({
              t: 'artifact',
              kind: asString(item.kind) ?? undefined,
              name,
              size: asString(item.size) ?? undefined,
              note: asString(item.note) ?? undefined,
              data: asString(item.data) ?? undefined,
              mimeType: asString(item.mimeType) ?? undefined,
            })
          : null
      }
      if (t === 'attach') {
        const name = asString(item.name)
        return name
          ? withoutUndefined({
              t: 'attach',
              name,
              dims: asString(item.dims) ?? undefined,
              src: asString(item.src) ?? undefined,
              svg: asString(item.svg) ?? undefined,
              ph: asString(item.ph) ?? undefined,
              via: asString(item.via) ?? undefined,
              size: asString(item.size) ?? undefined,
              data: asString(item.data) ?? undefined,
              mimeType: asString(item.mimeType) ?? undefined,
              sizeBytes: asNumber(item.sizeBytes) ?? undefined,
              id: asString(item.id) ?? undefined,
              kind: asString(item.kind) ?? undefined,
            })
          : null
      }
      if (t === 'voice') {
        return withoutUndefined({
          t: 'voice',
          secs: asNumber(item.secs) ?? undefined,
          wave: normalizeNumberArray(item.wave) ?? undefined,
          via: asString(item.via) ?? undefined,
          size: asString(item.size) ?? undefined,
          transcript: asString(item.transcript) ?? undefined,
          src: asString(item.src) ?? undefined,
        })
      }
      if (t === 'image') {
        const src = asString(item.src)
        const ph = asString(item.ph)
        return src || ph
          ? withoutUndefined({
              t: 'image',
              src: src ?? undefined,
              ph: ph ?? undefined,
              cap: asString(item.cap) ?? undefined,
            })
          : null
      }
      if (t === 'svg') {
        const svg = asString(item.svg)
        return svg ? withoutUndefined({ t: 'svg', svg, cap: asString(item.cap) ?? undefined }) : null
      }
      if (t === 'mermaid') {
        const source = asString(item.source)
        return source
          ? withoutUndefined({ t: 'mermaid', source, caption: asString(item.caption) ?? undefined })
          : null
      }
      if (t === 'trace') {
        const trace = normalizeTraceSteps(item.trace)
        return trace && trace.length > 0 ? { t: 'trace', trace } : null
      }
      if (t === 'thinking') {
        const content = typeof item.content === 'string' ? item.content : undefined
        const redacted = item.redacted === true
        if (content === undefined) return null
        return { t: 'thinking', content: redacted ? '' : content, redacted }
      }
      if (t === 'link') {
        const url = asString(item.url)
        const title = asString(item.title)
        return url && title
          ? withoutUndefined({
              t: 'link',
              url,
              title,
              desc: asString(item.desc) ?? undefined,
              meta: asString(item.meta) ?? undefined,
              fav: asString(item.fav) ?? undefined,
              kind: asString(item.kind) ?? undefined,
            })
          : null
      }
      if (t === 'broadcast') {
        const scope = asString(item.scope)
        const note = asString(item.note)
        const recipients = normalizeBroadcastRecipients(item.recipients)
        return scope && note && recipients
          ? withoutUndefined({
              t: 'broadcast',
              scope,
              via: asString(item.via) ?? undefined,
              note,
              recipients,
            })
          : null
      }
      // RFC-0252: fusion deliberation card. board_post_id is the lazy-fetch key
      // and is required; dropping it here would silently strip the card and let
      // the text fallback overwrite blocks.
      if (t === 'fusion') {
        const boardPostId = asString(item.board_post_id)
        return boardPostId
          ? { t: 'fusion', board_post_id: boardPostId, run_id: asString(item.run_id) ?? undefined }
          : null
      }
      return null
    })
    .filter((b): b is ChatBlock => b !== null)
  if (role === 'user') {
    const userBlocks = blocks
      .map(normalizeUserChatBlock)
      .filter((b): b is ChatBlock => b !== null)
    return userBlocks.length > 0 ? userBlocks : undefined
  }
  if (role !== 'assistant' && role !== 'system') return undefined
  return blocks.length > 0 ? blocks : undefined
}

/** Try to attach an audio clip to the most recent assistant entry whose
 *  rendered text matches the clip's message text. Returns true if a match
 *  was found and updated. This handles the live push path: the assistant
 *  bubble is already streaming when the synthesized audio event arrives. */
export function attachKeeperAudioClip(name: string, rawAudio: unknown): boolean {
  const clip = normalizeAudioClip(rawAudio)
  if (!clip) return false
  const targetText = formatKeeperVisibleReply(clip.messageText).trim()
  const rawTarget = clip.messageText.trim()
  const existing = keeperThreads.value[name] ?? []
  let updated = false
  const next = existing.map((entry) => {
    if (updated) return entry
    if (entry.role !== 'assistant') return entry
    const entryText = entry.text.trim()
    const entryRawText = (entry.rawText ?? entry.text).trim()
    if (
      (targetText && entryText === targetText)
      || (rawTarget && entryRawText === rawTarget)
    ) {
      updated = true
      return { ...entry, audio: clip }
    }
    return entry
  })
  if (updated) {
    keeperThreads.value = { ...keeperThreads.value, [name]: next }
  }
  return updated
}

// --- Normalizers ---

// Closed runtime mirrors of the 5 narrow string unions inside
// KeeperDiagnostic. The previous 5 `as KeeperDiagnostic['<field>']` casts
// trusted whatever backend string arrived; these sets enforce the
// boundary so an unrecognized value returns null (caller decides
// fallback). Same shape as toKeeperPhase / toKeeperLifecycleState /
// toPipelineStage (PRs #16745, #16788, #16791).
//
// Each set is typed as `KeeperDiagnostic['<field>']` (indexed access)
// so drift between the set and the underlying private union in
// types/core.ts surfaces as a tsc error here — no separate type
// export needed.
const KEEPER_HEALTH_STATES: ReadonlySet<NonNullable<KeeperDiagnostic['health_state']>> =
  new Set<NonNullable<KeeperDiagnostic['health_state']>>([
    'healthy', 'idle', 'stale', 'degraded', 'offline',
  ])

const KEEPER_QUIET_REASONS: ReadonlySet<NonNullable<KeeperDiagnostic['quiet_reason']>> =
  new Set<NonNullable<KeeperDiagnostic['quiet_reason']>>([
    'disabled', 'not_running', 'startup', 'never_started',
  ])

const KEEPER_NEXT_ACTION_PATHS: ReadonlySet<NonNullable<KeeperDiagnostic['next_action_path']>> =
  new Set<NonNullable<KeeperDiagnostic['next_action_path']>>([
    'auto_restart', 'recover', 'probe', 'direct_message',
  ])

const KEEPER_REPLY_STATUSES: ReadonlySet<NonNullable<KeeperDiagnostic['last_reply_status']>> =
  new Set<NonNullable<KeeperDiagnostic['last_reply_status']>>([
    'never', 'awaiting_reply', 'delivered', 'fresh', 'stale', 'error', 'unknown',
  ])

const KEEPER_CONTINUITY_STATES: ReadonlySet<NonNullable<KeeperDiagnostic['continuity_state']>> =
  new Set<NonNullable<KeeperDiagnostic['continuity_state']>>([
    'not_running', 'recovering', 'healthy', 'disabled', 'offline',
  ])

// Generic typed-parse helper. Returns the input value typed as `T` if
// `set` accepts it, else `null`. Callers compose with `?? <default>`
// for the fallback. This pattern is repeated 3 times in other dashboard
// modules (toKeeperPhase / toKeeperLifecycleState / toPipelineStage) —
// a future refactor could extract it to a shared module if it appears
// at a 4th boundary.
function membershipParse<T extends string>(
  set: ReadonlySet<T>,
  raw: string | null | undefined,
): T | null {
  if (!raw) return null
  const trimmed = raw.trim()
  if (!trimmed) return null
  return set.has(trimmed as T) ? (trimmed as T) : null
}

export function normalizeKeeperDiagnostic(raw: unknown): KeeperDiagnostic | null {
  if (!isRecord(raw)) return null
  const healthState = membershipParse(KEEPER_HEALTH_STATES, asString(raw.health_state))
  const nextActionPath = membershipParse(KEEPER_NEXT_ACTION_PATHS, asString(raw.next_action_path))
  const lastReplyStatus = membershipParse(KEEPER_REPLY_STATUSES, asString(raw.last_reply_status))
  // Reject the diagnostic entirely if any required field is invalid;
  // the previous behaviour rejected when these were empty strings, so
  // we preserve "reject on bad input" semantics while strengthening
  // from "non-empty string" to "valid union member".
  if (!healthState || !nextActionPath || !lastReplyStatus) return null
  return {
    health_state: healthState,
    quiet_reason: membershipParse(KEEPER_QUIET_REASONS, asString(raw.quiet_reason)),
    next_action_path: nextActionPath,
    last_reply_status: lastReplyStatus,
    last_reply_at: toIsoTimestamp(raw.last_reply_at) ?? null, // undefined->null: field is string|null
    last_reply_preview: asString(raw.last_reply_preview) ?? null,
    last_error: asString(raw.last_error) ?? null,
    recoverable: typeof raw.recoverable === 'boolean' ? raw.recoverable : undefined,
    summary: asString(raw.summary),
    keepalive_running: typeof raw.keepalive_running === 'boolean' ? raw.keepalive_running : undefined,
    continuity_state: membershipParse(KEEPER_CONTINUITY_STATES, asString(raw.continuity_state)),
  }
}

export function normalizeKeeperProbeResult(raw: unknown): KeeperProbeResult | null {
  if (!isRecord(raw)) return null
  return {
    status: raw.status,
    diagnostic: normalizeKeeperDiagnostic(raw.diagnostic),
  }
}

export function normalizeKeeperRecoverResult(raw: unknown): KeeperRecoverResult | null {
  if (!isRecord(raw)) return null
  return {
    recovered: asBoolean(raw.recovered) ?? false,
    skipped_reason: asString(raw.skipped_reason) ?? null,
    before: normalizeKeeperDiagnostic(raw.before),
    after: normalizeKeeperDiagnostic(raw.after),
    down: raw.down,
    up: raw.up,
  }
}

// --- Thread state management ---

function deliveryProvenanceFromRaw(raw: Record<string, unknown>): KeeperChatDeliveryProvenanceDecode {
  if (raw.delivery_provenance_status === 'invalid') {
    return { status: 'invalid', value: null }
  }
  if (raw.delivery_provenance_status === 'valid') {
    return isRecord(raw.delivery_provenance)
      ? {
          status: 'valid',
          value: raw.delivery_provenance as unknown as KeeperChatDeliveryProvenance,
        }
      : { status: 'invalid', value: null }
  }
  if (raw.delivery_key !== undefined || raw.transcript_slot !== undefined) {
    // Raw wire provenance must be decoded at the lazy API schema boundary.
    // Failing closed here prevents an accidental direct caller from making
    // malformed identity reconcilable.
    return { status: 'invalid', value: null }
  }
  return { status: 'absent', value: null }
}

function isSurfaceRefKind(value: string): value is SurfaceRefKind {
  switch (value) {
    case 'dashboard':
    case 'discord':
    case 'slack':
    case 'webhook':
    case 'agent':
    case 'broadcast':
    case 'gate':
      return true
    default:
      return false
  }
}

const SURFACE_REF_STRING_FIELDS = [
  'session_id',
  'guild_id',
  'channel_id',
  'parent_channel_id',
  'thread_id',
  'team_id',
  'thread_ts',
  'source',
  'event_id',
  'label',
] as const

/** Closed parse of the wire surface payload, mirroring
 * lib/keeper/surface_ref.ml `of_json`: an unknown or missing `kind`
 * yields no surface — the row keeps rendering with no origin badge,
 * the same policy keeper_chat_store.load applies to an invalid
 * persisted surface. Never a default kind. */
function normalizeSurfaceRef(raw: unknown): SurfaceRef | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  if (!kind || !isSurfaceRefKind(kind)) return null
  const surface: SurfaceRef = { kind }
  for (const field of SURFACE_REF_STRING_FIELDS) {
    const value = asString(raw[field])
    if (value !== null) surface[field] = value
  }
  if (isRecord(raw.address)) {
    const address: Record<string, string> = {}
    for (const [key, value] of Object.entries(raw.address)) {
      if (typeof value === 'string') address[key] = value
    }
    if (Object.keys(address).length > 0) surface.address = address
  }
  return surface
}

function normalizeHistoryEntry(
  raw: unknown,
  keeperName?: string,
  previousSource: KeeperConversationSource | null = null,
): KeeperConversationEntry | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)?.trim() ?? ''
  if (!id) return null
  const role = normalizeRole(raw.role)
  const rawText = asString(raw.content) ?? asString(raw.preview) ?? ''
  const attachments = normalizeAttachments(raw.attachments)
  const audio = normalizeAudioClip(raw.audio) ?? null
  const serverBlocks = normalizeBlocks(raw.blocks, role)
  const hasRenderableBlocks = (serverBlocks?.length ?? 0) > 0
  // Accept attachment-only, audio-only, and validated block-only rows. In
  // particular, persisted thinking/trace/fusion blocks may intentionally have
  // no visible `content`; rejecting them here erased completed work on reload.
  if (!rawText && !attachments?.length && !audio && !hasRenderableBlocks) return null
  const source = normalizeConversationSource(raw.source, role, rawText, previousSource)
  const text = formatKeeperVisibleReply(rawText)
  if (!text && !attachments?.length && !audio && !hasRenderableBlocks) return null
  const timestamp = toIsoTimestamp(raw.ts_unix) ?? toIsoTimestamp(raw.timestamp)
  const label = role === 'assistant' && keeperName ? keeperName : roleLabel(role)
  const surface = normalizeSurfaceRef(raw.surface)
  const conversationId = asString(raw.conversation_id) ?? null
  const externalMessageId = asString(raw.external_message_id) ?? null
  const speakerId = asString(raw.speaker_id) ?? null
  const speakerName = asString(raw.speaker_name) ?? null
  const speakerAuthority = asString(raw.speaker_authority) ?? null
  // RFC-0233 §7: asString rejects malformed join keys instead of repairing them.
  const turnRef = asString(raw.turn_ref) ?? null
  const executionId = asString(raw.execution_id)
  const deliveryProvenance = deliveryProvenanceFromRaw(raw)
  // keeper_chat_store mints kind=transport_failure (row content is the
  // "Keeper request failed: ..." text) so a reload can tell a failed request
  // apart from a real reply. Preserve that writer-declared provenance as its
  // own delivery variant: generic client/tool errors have different watermark
  // semantics and must not inherit the durable-row reassurance.
  const delivery: KeeperConversationDelivery =
    asString(raw.kind) === 'transport_failure' ? 'transport_failure' : 'history'
  const blocks = serverBlocks
    ?? ((role === 'assistant' || role === 'system') && text
      ? parseTextToChatBlocks(text)
      : undefined)
  const approvalLifecycle = normalizeApprovalLifecycle(raw.approval_lifecycle)
  const streamContract = approvalLifecycle
    ? null
    : deliveryProvenance.status === 'invalid'
      ? keeperStreamContract('rest_history', 'contract_gap', {
          reason: 'history row carries malformed or incomplete delivery provenance',
        })
      : normalizeStreamContract(raw.stream_contract)
        ?? keeperStreamContract('rest_history', 'history_without_stream_events', {
          reason: 'history rows do not carry stream lifecycle events',
        })
  return {
    id,
    role,
    source,
    label,
    text,
    rawText,
    timestamp,
    turnRef,
    deliveryProvenance: deliveryProvenance.value,
    ...(executionId ? { executionId } : {}),
    delivery,
    error: delivery === 'transport_failure' ? rawText : null,
    streamState: null,
    streamContract,
    details: null,
    surface,
    conversationId,
    externalMessageId,
    speakerId,
    speakerName,
    speakerAuthority,
    audio,
    approvalLifecycle,
    attachments,
    blocks,
  }
}

export function normalizeStatusDetail(name: string, text: string, rawStatus: unknown): KeeperStatusDetail {
  const parsed = isRecord(rawStatus) ? rawStatus : null
  const history = Array.isArray(parsed?.history_tail)
    ? (() => {
        let previousSource: KeeperConversationSource | null = null
        return parsed.history_tail
          .map((entry) => {
            const normalized = normalizeHistoryEntry(entry, name, previousSource)
            previousSource = normalized?.source ?? previousSource
            return normalized
          })
          .filter((entry): entry is KeeperConversationEntry => entry !== null)
      })()
    : []
  return {
    name,
    diagnostic: normalizeKeeperDiagnostic(parsed?.diagnostic),
    history,
    rawText: text,
    rawStatus,
    loadedAt: new Date().toISOString(),
  }
}

export function appendThreadEntry(name: string, entry: KeeperConversationEntry): void {
  const existing = keeperThreads.value[name] ?? []
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: capThreadEntries([...existing, entry]),
  }
}

// --- Tool approval rows ---

export function upsertKeeperToolApproval(
  keeperName: string,
  approval: KeeperToolApprovalPending,
): void {
  const byKeeper = keeperToolApprovals.value[keeperName] ?? {}
  keeperToolApprovals.value = {
    ...keeperToolApprovals.value,
    [keeperName]: { ...byKeeper, [approval.toolCallId]: approval },
  }
}

export function updateKeeperToolApproval(
  keeperName: string,
  toolCallId: string,
  updater: (approval: KeeperToolApprovalPending) => KeeperToolApprovalPending,
): void {
  const byKeeper = keeperToolApprovals.value[keeperName]
  const existing = byKeeper?.[toolCallId]
  if (!existing) return
  keeperToolApprovals.value = {
    ...keeperToolApprovals.value,
    [keeperName]: { ...byKeeper, [toolCallId]: updater(existing) },
  }
}

export function settleKeeperToolApproval(
  keeperName: string,
  toolCallId: string,
  outcome: string,
): void {
  updateKeeperToolApproval(keeperName, toolCallId, approval => ({
    ...approval,
    settled: true,
    answering: false,
    answeredOutcome: outcome,
  }))
}

export function dropKeeperToolApproval(keeperName: string, toolCallId: string): void {
  const byKeeper = keeperToolApprovals.value[keeperName]
  if (!byKeeper || !(toolCallId in byKeeper)) return
  const next = { ...byKeeper }
  delete next[toolCallId]
  keeperToolApprovals.value = { ...keeperToolApprovals.value, [keeperName]: next }
}


export function removeThreadEntries(name: string, entryIds: readonly string[]): void {
  if (entryIds.length === 0) return
  const removeIds = new Set(entryIds)
  const existing = keeperThreads.value[name] ?? []
  const next = existing.filter(entry => !removeIds.has(entry.id))
  if (next.length === existing.length) return
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: next,
  }
}

/** Insert [entry] immediately before the entry with id [beforeId].
 *  Falls back to append when [beforeId] is absent. Used to keep live
 *  tool-call entries above the streaming assistant bubble so the final
 *  reply renders last in the transcript. */
export function insertThreadEntryBefore(
  name: string,
  beforeId: string,
  entry: KeeperConversationEntry,
): void {
  const existing = keeperThreads.value[name] ?? []
  if (existing.some(e => e.id === entry.id)) return
  const index = existing.findIndex(e => e.id === beforeId)
  const next =
    index === -1
      ? [...existing, entry]
      : [...existing.slice(0, index), entry, ...existing.slice(index)]
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: capThreadEntries(next),
  }
}

export function updateThreadEntry(
  name: string,
  entryId: string,
  updater: (entry: KeeperConversationEntry) => KeeperConversationEntry,
): void {
  const existing = keeperThreads.value[name] ?? []
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: existing.map(entry => (entry.id === entryId ? updater(entry) : entry)),
  }
}

export function setAssistantStreamState(
  name: string,
  entryId: string,
  streamState: KeeperConversationStreamState,
  delivery: KeeperConversationDelivery,
  streamContract?: KeeperConversationStreamContract,
): void {
  updateThreadEntry(name, entryId, entry => ({
    ...entry,
    streamState,
    delivery,
    streamContract: streamContract ?? entry.streamContract,
  }))
}

export function appendAssistantDelta(name: string, entryId: string, delta: string): void {
  updateThreadEntry(name, entryId, entry => ({
    ...entry,
    rawText: `${entry.rawText ?? entry.text}${delta}`,
    text: formatKeeperVisibleReply(`${entry.rawText ?? entry.text}${delta}`),
    streamState: 'streaming',
    delivery: 'streaming',
    streamContract: entry.streamContract ?? keeperStreamContract('sse_event', 'backend_stream_event', {
      eventName: 'TEXT_MESSAGE_CONTENT',
    }),
  }))
}

/** Move assistant text that is structurally followed by a tool call out of
 *  the final reply and into the turn timeline. The following TOOL_CALL_START
 *  is the protocol proof that this text belonged to an intermediate assistant
 *  round; no text-content or similarity classification participates. */
export function promoteAssistantTextToProgress(
  name: string,
  entryId: string,
  meta: { agentCoreBlockIndex?: number } = {},
): void {
  updateThreadEntry(name, entryId, entry => {
    const text = entry.rawText ?? entry.text
    if (!text.trim()) return entry
    const progress = withoutUndefined({
      kind: 'progress' as const,
      text,
      ts: new Date().toISOString(),
      agentCoreBlockIndex: meta.agentCoreBlockIndex,
    })
    return {
      ...entry,
      text: '',
      rawText: '',
      blocks: [],
      traceSteps: [...(entry.traceSteps ?? []), progress],
    }
  })
}

function writeAssistantThinkingText(
  name: string,
  entryId: string,
  text: string,
  meta: { agentCoreBlockIndex?: number } = {},
  mode: 'append' | 'snapshot',
): void {
  if (!text.trim()) return
  const agentCoreBlockIndex = meta.agentCoreBlockIndex
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const last = existing[existing.length - 1]
    const sameThinkingBlock =
      last?.kind === 'think'
      && (agentCoreBlockIndex === undefined
        ? last.agentCoreBlockIndex === undefined
        : last.agentCoreBlockIndex === agentCoreBlockIndex)
    // Stamp the occurrence time on a NEW think step so the work-trace card can
    // interleave it with tool entries by occurrence order. When consecutive
    // deltas merge into the same step, the first stamp is preserved: the step
    // began at that time, not when the latest fragment arrived.
    const nextText =
      sameThinkingBlock
        ? mode === 'append'
          ? `${last.text}${text}`
          : text
        : text.trimStart()
    const traceSteps: ChatTraceStep[] =
      sameThinkingBlock
        ? [
            ...existing.slice(0, -1),
            withoutUndefined({
              kind: 'think',
              text: nextText,
              ts: last.ts,
              agentCoreBlockIndex: last.agentCoreBlockIndex,
            }),
          ]
        : [
            ...existing,
            withoutUndefined({
              kind: 'think',
              text: nextText,
              ts: new Date().toISOString(),
              agentCoreBlockIndex,
            }),
          ]
    return {
      ...entry,
      traceSteps,
      streamState: 'thinking',
      delivery: 'streaming',
      streamContract: entry.streamContract ?? keeperStreamContract('sse_event', 'backend_stream_event', {
        eventName: 'KEEPER_THINKING_DELTA',
      }),
    }
  })
}

export function appendAssistantThinkingDelta(
  name: string,
  entryId: string,
  delta: string,
  meta: { agentCoreBlockIndex?: number } = {},
): void {
  writeAssistantThinkingText(name, entryId, delta, meta, 'append')
}

export function setAssistantThinkingSnapshot(
  name: string,
  entryId: string,
  text: string,
  meta: { agentCoreBlockIndex?: number } = {},
): void {
  writeAssistantThinkingText(name, entryId, text, meta, 'snapshot')
}

function warnMissingToolTrace(
  op: string,
  keeperName: string,
  entryId: string,
  toolOccurrenceId: string,
): void {
  console.warn('[keeper-trace] missing tool trace step', {
    op,
    keeperName,
    entryId,
    toolOccurrenceId,
  })
}

export function appendAssistantToolTraceStep(
  name: string,
  entryId: string,
  step: {
    toolCallId?: string
    toolOccurrenceId: string
    name: string
    ts?: string
    agentCoreBlockIndex?: number
  },
): void {
  const toolCallId = nonBlankToolCallId(step.toolCallId) ?? undefined
  const toolOccurrenceId = step.toolOccurrenceId.trim()
  const toolName = step.name.trim()
  if (!toolOccurrenceId || !toolName) {
    console.warn('[keeper-trace] invalid tool trace step', { op: 'start', keeperName: name, entryId })
    return
  }
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const index = existing.findIndex(
      trace => trace.kind === 'tool' && trace.toolOccurrenceId === toolOccurrenceId,
    )
    const nextStep = withoutUndefined({
      kind: 'tool',
      toolCallId,
      toolOccurrenceId,
      name: toolName,
      status: 'pending',
      ts: step.ts ?? new Date().toISOString(),
      agentCoreBlockIndex: step.agentCoreBlockIndex,
    })
    const traceSteps =
      index === -1
        ? [...existing, nextStep]
        : existing.map((trace, i) =>
            i === index && trace.kind === 'tool'
              ? withoutUndefined({
                  ...trace,
                  name: trace.name || toolName,
                  toolCallId: trace.toolCallId ?? toolCallId,
                  toolOccurrenceId,
                  status: trace.status ?? 'pending',
                  ts: trace.ts ?? nextStep.ts,
                  agentCoreBlockIndex: trace.agentCoreBlockIndex ?? nextStep.agentCoreBlockIndex,
                })
              : trace,
          )
    return {
      ...entry,
      traceSteps,
      streamState: 'streaming',
      delivery: 'streaming',
    }
  })
}

export function appendAssistantToolTraceArgsDelta(
  name: string,
  entryId: string,
  toolOccurrenceId: string,
  delta: string,
): void {
  const id = toolOccurrenceId.trim()
  if (!id || !delta) return
  let found = false
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const traceSteps = existing.map((trace) => {
      if (trace.kind !== 'tool' || trace.toolOccurrenceId !== id) return trace
      found = true
      return {
        ...trace,
        args: `${trace.args ?? ''}${delta}`,
      }
    })
    return {
      ...entry,
      traceSteps,
    }
  })
  if (!found) warnMissingToolTrace('args patch', name, entryId, id)
}

export function setAssistantToolTraceArgsSnapshot(
  name: string,
  entryId: string,
  toolOccurrenceId: string,
  snapshot: string,
): void {
  const id = toolOccurrenceId.trim()
  if (!id) return
  let found = false
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const traceSteps = existing.map((trace) => {
      if (trace.kind !== 'tool' || trace.toolOccurrenceId !== id) return trace
      found = true
      return {
        ...trace,
        args: snapshot,
      }
    })
    return {
      ...entry,
      traceSteps,
    }
  })
  if (!found) warnMissingToolTrace('args snapshot', name, entryId, id)
}

export function markAssistantToolTraceEnded(
  name: string,
  entryId: string,
  toolOccurrenceId: string,
  executionId?: string,
): void {
  const id = toolOccurrenceId.trim()
  if (!id) return
  let found = false
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const traceSteps = existing.map((trace) => {
      if (trace.kind !== 'tool' || trace.toolOccurrenceId !== id) return trace
      found = true
      return {
        ...trace,
        executionId: executionId ?? trace.executionId,
        status: trace.status === 'err' ? ('err' as const) : ('ok' as const),
      }
    })
    return {
      ...entry,
      traceSteps,
    }
  })
  if (!found) warnMissingToolTrace('end patch', name, entryId, id)
}

export function markAssistantToolTraceErrored(
  name: string,
  entryId: string,
  toolOccurrenceId: string,
): void {
  const id = toolOccurrenceId.trim()
  if (!id) return
  let found = false
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const traceSteps = existing.map((trace) => {
      if (trace.kind !== 'tool' || trace.toolOccurrenceId !== id) return trace
      found = true
      return {
        ...trace,
        status: 'err' as const,
      }
    })
    return {
      ...entry,
      traceSteps,
    }
  })
  if (!found) warnMissingToolTrace('error patch', name, entryId, id)
}


export function finalizeAssistantEntry(
  name: string,
  entryId: string,
  patch: Partial<KeeperConversationEntry>,
): void {
  updateThreadEntry(name, entryId, (entry) => {
    const next: KeeperConversationEntry = { ...entry, ...patch }
    if (next.role === 'assistant' && !next.blocks?.length && next.text) {
      next.blocks = parseTextToChatBlocks(next.text)
    }
    return next
  })
}

// Dedup key for merging server history with locally-appended entries. Server
// ids win when both sides already name the same row. Otherwise the atomic
// append-once provenance pair is the sole convergence authority. Role, text,
// timestamp, and turn_ref are projections/correlation data, never row identity.
function sameConversationEntry(
  left: KeeperConversationEntry,
  right: KeeperConversationEntry,
): boolean {
  if (left.id === right.id) return true
  const leftProvenance = left.deliveryProvenance
  const rightProvenance = right.deliveryProvenance
  return Boolean(
    leftProvenance
    && rightProvenance
    && sameDeliveryProvenance(leftProvenance, rightProvenance),
  )
}

// Entries with no parseable timestamp (live placeholders, still-streaming
// turns) sort to the very bottom so the in-flight tail stays put; everything
// else sorts by wall-clock so history renders oldest→newest.
const TIMESTAMP_SORT_FALLBACK = Number.MAX_SAFE_INTEGER
function entryTimeMs(entry: KeeperConversationEntry): number {
  const ms = entry.timestamp ? Date.parse(entry.timestamp) : NaN
  return Number.isFinite(ms) ? ms : TIMESTAMP_SORT_FALLBACK
}

function mergeLocalAssistantTraceSteps(
  historyEntry: KeeperConversationEntry,
  localEntries: KeeperConversationEntry[],
  // Tracks local trace sources already claimed by an earlier history row.
  // Join order: exact delivery provenance first, then turn_ref only for trace
  // correlation when neither row has provenance. There is no text fallback: a local
  // trace source that shares neither key with the history row stays
  // unmerged (and is dropped by exact provenance in replaceThread once its
  // turn converges). `consumed` keeps every match 1:1 instead of
  // letting duplicate assistant text reuse the first local trace source
  // (#21748).
  consumed: Set<string>,
): KeeperConversationEntry {
  if (historyEntry.role !== 'assistant') return historyEntry
  const historyProvenance = historyEntry.deliveryProvenance
  const localTraceSourceByProvenance = historyProvenance
    ? localEntries.find(
        entry =>
          entry.role === 'assistant'
          && (entry.traceSteps?.length ?? 0) > 0
          && !consumed.has(entry.id)
          && entry.deliveryProvenance != null
          && sameDeliveryProvenance(entry.deliveryProvenance, historyProvenance),
      )
    : undefined
  if (localTraceSourceByProvenance?.traceSteps?.length) {
    consumed.add(localTraceSourceByProvenance.id)
    if ((historyEntry.traceSteps?.length ?? 0) > 0) return historyEntry
    return {
      ...historyEntry,
      traceSteps: localTraceSourceByProvenance.traceSteps,
    }
  }
  if (historyProvenance) return historyEntry
  const historyTurnRef = historyEntry.turnRef?.trim()
  const localTraceSourceByTurnRef = historyTurnRef
    ? localEntries.find(
        entry =>
          entry.role === 'assistant'
          && (entry.traceSteps?.length ?? 0) > 0
          && !consumed.has(entry.id)
          && entry.deliveryProvenance == null
          && entry.turnRef?.trim() === historyTurnRef,
      )
    : undefined
  if (localTraceSourceByTurnRef?.traceSteps?.length) {
    consumed.add(localTraceSourceByTurnRef.id)
    if ((historyEntry.traceSteps?.length ?? 0) > 0) return historyEntry
    return {
      ...historyEntry,
      traceSteps: localTraceSourceByTurnRef.traceSteps,
    }
  }
  return historyEntry
}

function replaceThread(name: string, entries: KeeperConversationEntry[]): void {
  // An empty history payload means the caller did not request history
  // (e.g. hydrateKeeperStatus fast path with tail_messages: 0), not
  // that the conversation is empty. Wiping previously-hydrated history
  // entries here is what made the transcript vanish after a status
  // refresh / probe / recover.
  if (entries.length === 0) return
  const existing = keeperThreads.value[name] ?? []
  // Shared across the map so each local trace source is claimed at most once
  // (see mergeLocalAssistantTraceSteps): identical-text turns no longer steal
  // each other's trace (#21748).
  const consumed = new Set<string>()
  const historyEntries = entries.map(entry => mergeLocalAssistantTraceSteps(entry, existing, consumed))
  const localEntries = existing.filter(
    entry => {
      const coveredByHistory = historyEntries.some(historyEntry => sameConversationEntry(entry, historyEntry))
      // Tool rows are durable execution facts. If the server history already
      // has the same tool_call_id, keep the canonical history row even while a
      // local live row is still marked streaming; otherwise the live row can
      // later flip to delivered and leave a duplicate "작업 과정" card behind.
      const isCoveredToolRow = entry.role === 'tool' && coveredByHistory
      // In-flight (sending/streaming/queued) entries represent live state and
      // must survive history merges until they finalize.
      // A converged assistant row supersedes its own placeholder even while the
      // placeholder still reads in-flight: a stream that died before
      // REPLY_DETAILS leaves `sending` set forever, so treating in-flight as
      // unconditionally live renders the same turn twice (live 2026-07-28,
      // queue lane). Convergence requires a shared producer identity, so this
      // cannot collapse two genuinely distinct turns.
      const supersededByHistory = entry.role === 'assistant' && coveredByHistory
      const shouldKeepLocalEntry = !supersededByHistory
        && (isInFlightDelivery(entry.delivery)
          || !coveredByHistory)
      return entry.delivery !== 'history' && !isCoveredToolRow && shouldKeepLocalEntry
    },
  )
  // Render strictly oldest→newest by timestamp. Server /chat/history is
  // chronological, but locally-appended entries (a live turn's transport error,
  // optimistic rows) were concatenated AFTER it with no re-sort, which floated a
  // days-old dns_failure to the very bottom of the transcript where it read as
  // the newest message. Sorting by timestamp puts every entry in its real
  // position; no-timestamp entries sort last (in-flight tail stays at the
  // bottom) and the original array index breaks ties so same-second tool calls
  // keep their issued order.
  const merged = [...historyEntries, ...localEntries]
    .map((entry, index) => ({ entry, index }))
    .sort((a, b) => entryTimeMs(a.entry) - entryTimeMs(b.entry) || a.index - b.index)
    .map(({ entry }) => entry)
  // Autonomous observations are separately bounded by the backend's exact
  // current-record/raw-trace window. They do not consume dialogue slots: a
  // busy keeper must never evict the direct conversation it is shown beside.
  const kept = capThreadEntries(merged)
  keeperThreads.value = {
    ...keeperThreads.value,
    [name]: kept,
  }
}

/** Merge server-fetched chat history (REST `GET /chat/history`) into the
 *  thread. History entries become the canonical prefix; locally-appended
 *  live entries that are not already covered by the server copy are kept
 *  after it. */
export function mergeServerHistoryEntries(
  name: string,
  entries: KeeperConversationEntry[],
): void {
  replaceThread(name, entries)
}

interface RestChatHistoryMessage {
  id: string
  role: string
  content: string | null
  ts: number
  tool_call_id?: string
  execution_id?: string
  tool_call_name?: string
  source?: string
  // Raw wire payload — decoded once by normalizeSurfaceRef at each
  // consuming entry builder; never asserted into SurfaceRef.
  surface?: unknown
  conversation_id?: string
  external_message_id?: string
  speaker_id?: string
  speaker_name?: string
  speaker_authority?: string
  // RFC-0233 §7: MASC-minted "<trace_id>#<absolute_turn>" turn join key.
  turn_ref?: string | null
  // Canonical append-once identity decoded at the HTTP boundary. Direct
  // normalizeStatusDetail callers may still supply the raw sibling fields;
  // normalizeHistoryEntry runs the same closed decoder for that path.
  delivery_provenance?: KeeperChatDeliveryProvenance | null
  delivery_provenance_status?: KeeperChatDeliveryProvenanceDecode['status']
  audio?: unknown
  // Persisted upload rows (snake_case from keeper_chat_store) — normalized to
  // KeeperConversationAttachment at consume time so reload keeps the cards.
  attachments?: ReadonlyArray<{
    id: string
    type: string
    name: string
    size: number
    mime_type: string
    data: string
  }>
  // Row kind; 'transport_failure' distinguishes a persisted failed request.
  kind?: string
  // Typed durable Gate approval/replay status projected by keeper_chat_store.
  approval_lifecycle?: unknown
  // RFC-0235 P3: backend-parsed rich chat blocks. When present the dashboard
  // prefers them over its local parser.
  blocks?: unknown
  stream_contract?: unknown
  // Present only on rows projected from a typed autonomous turn. Its presence,
  // not `role`, marks the row; [blocks] carries that exact run's work trace.
  autonomous_turn?: unknown
}

/** Convert a current-record autonomous turn into a conversation entry. */
function autonomousTurnEntry(
  keeperName: string,
  message: RestChatHistoryMessage,
): KeeperConversationEntry | null {
  if (!isRecord(message.autonomous_turn)) return null
  const turnId = asString(message.autonomous_turn.turn_id)
  if (!turnId) return null
  const timestamp = toIsoTimestamp(message.ts)
  const text = message.content ?? '텍스트 응답 없음'
  const normalizedBlocks = normalizeBlocks(message.blocks, 'assistant')
  const traceSteps = normalizedBlocks
    ?.flatMap(block => block.t === 'trace' ? block.trace : [])
  const blocks = normalizedBlocks?.filter(block => block.t !== 'trace')
  return {
    // Re-minted from turn_id, NOT the raw row's `autonomous:<turn_id>` id:
    // that backend field exists only to satisfy the history schema's
    // required-id check (keeper-chat-history.ts) and is never read here.
    id: `autonomous-${turnId}`,
    role: 'assistant',
    source: 'autonomous_turn',
    label: keeperName,
    text,
    rawText: message.content,
    blocks: blocks && blocks.length > 0 ? blocks : undefined,
    traceSteps: traceSteps && traceSteps.length > 0 ? traceSteps : undefined,
    timestamp,
    delivery: message.content === null ? 'no_reply' : 'history',
    streamState: null,
    streamContract: keeperStreamContract('rest_history', 'history_without_stream_events', {
      reason: 'autonomous turns are projected from typed records and exact retained traces, never streamed',
    }),
    details: null,
    surface: null,
    turnRef: turnId,
  }
}

/** Convert a persisted tool-call row into the live tool-entry shape.
 *  The server row id remains row identity; provider tool_call_id is optional
 *  correlation data and canonical execution_id is the output/join identity.
 *  Live/history convergence uses delivery provenance, never a reminted
 *  provider-derived row id. */
function toolHistoryEntry(message: RestChatHistoryMessage): KeeperConversationEntry | null {
  const toolCallId = nonBlankToolCallId(message.tool_call_id)
  const toolCallName = message.tool_call_name?.trim()
  if (!toolCallName || typeof message.content !== 'string') return null
  if (message.delivery_provenance_status === 'invalid') return null
  const deliveryProvenance = message.delivery_provenance ?? null
  const rawExecutionId = asString(message.execution_id)
  const executionId = rawExecutionId?.trim() ? rawExecutionId : null
  const slot = deliveryProvenance?.transcript_slot
  if (
    (slot?.kind === 'tool_call'
      && (executionId === null || slot.execution_id !== executionId))
    || (slot?.kind === 'tool_delivery' && executionId !== null)
    || slot?.kind === 'accepted_user'
    || slot?.kind === 'terminal_assistant'
  ) return null
  return {
    id: message.id,
    role: 'tool',
    source: 'tool_result',
    label: toolCallName,
    text: message.content,
    rawText: message.content,
    timestamp: toIsoTimestamp(message.ts),
    toolCallId,
    toolCallEnded: true,
    delivery: 'history',
    streamState: null,
    streamContract: normalizeStreamContract(message.stream_contract) ?? keeperStreamContract('rest_history', 'history_without_stream_events', {
      reason: 'tool history rows carry arguments, not live stream lifecycle',
    }),
    details: null,
    surface: normalizeSurfaceRef(message.surface),
    conversationId: asString(message.conversation_id) ?? null,
    externalMessageId: asString(message.external_message_id) ?? null,
    speakerId: asString(message.speaker_id) ?? null,
    speakerName: asString(message.speaker_name) ?? null,
    speakerAuthority: asString(message.speaker_authority) ?? null,
    // Tool rows share the same untrusted REST boundary; reject malformed
    // turn_ref values here too so this path matches normalizeHistoryEntry.
    turnRef: asString(message.turn_ref) ?? null,
    deliveryProvenance,
    executionId,
  }
}

/** Convert REST chat-history messages ({role, content, ts-seconds}) into
 *  conversation entries, chaining source inference the same way
 *  status-detail history does. */
export function chatHistoryEntriesFromRest(
  keeperName: string,
  messages: RestChatHistoryMessage[],
): KeeperConversationEntry[] {
  let previousSource: KeeperConversationSource | null = null
  const entries: KeeperConversationEntry[] = []
  messages.forEach((message) => {
    if (!message.id.trim()) return
    if (message.autonomous_turn !== undefined) {
      // Nobody addressed the keeper, so this row must not advance the
      // user/assistant source chain that infers direct-conversation roles.
      const autonomousEntry = autonomousTurnEntry(keeperName, message)
      if (autonomousEntry) entries.push(autonomousEntry)
      return
    }
    if (message.role === 'tool') {
      // Tool rows do not participate in user/assistant source chaining.
      const toolEntry = toolHistoryEntry(message)
      if (toolEntry) entries.push(toolEntry)
      return
    }
    if (typeof message.content !== 'string') return
    const normalized = normalizeHistoryEntry(
      {
        id: message.id,
        role: message.role,
        content: message.content,
        ts_unix: message.ts,
        source: message.source,
        surface: message.surface,
        conversation_id: message.conversation_id,
        external_message_id: message.external_message_id,
        speaker_id: message.speaker_id,
        speaker_name: message.speaker_name,
        speaker_authority: message.speaker_authority,
        audio: message.audio,
        attachments: message.attachments,
        kind: message.kind,
        approval_lifecycle: message.approval_lifecycle,
        blocks: message.blocks,
        turn_ref: message.turn_ref,
        delivery_provenance: message.delivery_provenance,
        delivery_provenance_status: message.delivery_provenance_status,
        stream_contract: message.stream_contract,
      },
      keeperName,
      previousSource,
    )
    if (normalized) {
      previousSource = normalized.source
      entries.push(normalized)
    }
  })
  return entries
}

export function setStatusDetail(name: string, detail: KeeperStatusDetail): void {
  keeperStatusDetails.value = {
    ...keeperStatusDetails.value,
    [name]: detail,
  }
  replaceThread(name, detail.history)
}

// --- Stream controller management ---

export function setActiveStream(
  name: string,
  operationId: string,
  entryId: string,
  controller: AbortController,
): void {
  const streams = keeperActiveStreams.get(name) ?? new Map<string, KeeperActiveStream>()
  streams.set(operationId, { entryId, controller })
  keeperActiveStreams.set(name, streams)
  // The client mints the operation id before opening the direct response
  // stream. Claim it at the same lifecycle boundary as the stream controller,
  // before an observer broadcast can race the ACCEPTED event.
  claimLiveSendRequest(operationId, name)
}

export function clearActiveStream(name: string, operationId: string): void {
  const streams = keeperActiveStreams.get(name)
  streams?.delete(operationId)
  if (streams?.size === 0) keeperActiveStreams.delete(name)
  releaseLiveSendRequest(operationId)
}

export function activeStreamEntryId(name: string): string | null {
  return keeperActiveStreams.get(name)?.values().next().value?.entryId ?? null
}

export function activeStreamOperationId(name: string): string | null {
  return keeperActiveStreams.get(name)?.keys().next().value ?? null
}

export function getStreamController(name: string): AbortController | undefined {
  return keeperActiveStreams.get(name)?.values().next().value?.controller
}

export function activeStreamRequestId(name: string): string | null {
  const operationId = activeStreamOperationId(name)
  return operationId && acceptedLiveSendRequestIds.has(operationId)
    ? operationId
    : null
}

// --- Live send ownership (in-session, requestId-keyed) ---

export function claimLiveSendRequest(requestId: string, name: string): void {
  const id = requestId.trim()
  const keeperName = name.trim()
  if (!id || !keeperName) return
  liveSendRequestOwners.set(id, keeperName)
}

export function markLiveSendRequestAccepted(requestId: string): void {
  const id = requestId.trim()
  if (liveSendRequestOwners.has(id)) acceptedLiveSendRequestIds.add(id)
}

export function releaseLiveSendRequest(requestId: string): void {
  const id = requestId.trim()
  liveSendRequestOwners.delete(id)
  acceptedLiveSendRequestIds.delete(id)
}

export function liveSendOwnsRequest(requestId: string): boolean {
  return liveSendRequestOwners.has(requestId.trim())
}

export function _resetLiveSendRequestOwnersForTests(): void {
  liveSendRequestOwners.clear()
  acceptedLiveSendRequestIds.clear()
}
