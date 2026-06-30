import { signal } from '@preact/signals'
import { formatKeeperVisibleReply } from './keeper-message'
import { parseTextToChatBlocks } from './lib/chat-blocks'
import { isRecord, asString, asNumber, asBoolean, toIsoTimestamp } from './components/common/normalize'
import { toolEntryIdFromCallId } from './tool-call-output-store'
import type {
  KeeperConversationAttachment,
  KeeperConversationAudioClip,
  KeeperConversationEntry,
  KeeperConversationRole,
  KeeperConversationSource,
  KeeperConversationStreamState,
  KeeperConversationDelivery,
  KeeperDiagnostic,
  KeeperProbeResult,
  KeeperRecoverResult,
  KeeperStatusDetail,
  SurfaceRef,
  ChatBlock,
  ChatBroadcastRecipient,
  ChatShellLine,
  ChatTableCellValue,
  ChatTraceStep,
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

// Thread entries kept per keeper. History beyond this window stays
// available server-side (keeper_chat/<name>.jsonl, GET /chat/history).
export const THREAD_ENTRY_CAP = 200

// --- Private stream tracking ---

const keeperStreamControllers = new Map<string, AbortController>()
const keeperStreamEntryIds = new Map<string, string>()
// requestId -> keeperName: which queued requests a live in-session send
// stream currently owns. Resume defers to this so an SPA remount does not
// spin up a second handler/entry for a request the live send already drives.
// Active stream request lookup is derived from this map to avoid maintaining
// a second inverse keeperName -> requestId structure in lockstep.
// Module state, so it survives unmount/remount exactly like the controller
// maps above; a full page reload resets it, leaving cold-start resume intact.
const liveSendRequestOwners = new Map<string, string>()

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
    && entry.source !== 'tool_result'
    && entry.source !== 'system'
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
  return isVisibleDirectConversationEntry(entry) || isToolConversationEntry(entry)
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

function normalizeStringArray(raw: unknown): string[] | null {
  if (!Array.isArray(raw)) return null
  const values = raw.map((value) => asString(value))
  if (values.some((value) => value === undefined)) return null
  return values as string[]
}

function withoutUndefined<const T extends Record<string, unknown>>(record: T): T {
  const next: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(record)) {
    if (value !== undefined) next[key] = value
  }
  return next as T
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
    const text = asString(raw.text)
    return text !== undefined
      ? withoutUndefined({
          kind,
          text,
          ts: asString(raw.ts),
          oasBlockIndex: asNumber(raw.oasBlockIndex) ?? asNumber(raw.oas_block_index) ?? undefined,
        })
      : null
  }
  if (kind === 'reason') {
    const text = asString(raw.text)
    return text !== undefined
      ? withoutUndefined({ kind: 'reason', text, detail: asString(raw.detail) ?? undefined, ts: asString(raw.ts) })
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
      status: toolStatus,
      dur: asString(raw.dur) ?? undefined,
      args: normalizeTracePayload(raw.args),
      result: normalizeTracePayload(raw.result),
      ts: asString(raw.ts) ?? undefined,
      oasBlockIndex: asNumber(raw.oasBlockIndex) ?? asNumber(raw.oas_block_index) ?? undefined,
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
      if (t === 'ul') {
        const items = normalizeStringArray(item.items)
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
 *  was found and updated. This handles the live SSE path: the assistant
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
    'quiet_hours', 'min_gap', 'no_recent_activity', 'disabled',
    'startup', 'model_error', 'graphql_error', 'never_started', 'unknown',
  ])

const KEEPER_NEXT_ACTION_PATHS: ReadonlySet<NonNullable<KeeperDiagnostic['next_action_path']>> =
  new Set<NonNullable<KeeperDiagnostic['next_action_path']>>([
    'direct_message', 'manual_social_sweep', 'probe', 'recover',
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
    next_eligible_at_s: asNumber(raw.next_eligible_at_s) ?? null,
    recoverable: typeof raw.recoverable === 'boolean' ? raw.recoverable : undefined,
    summary: asString(raw.summary),
    keepalive_running: typeof raw.keepalive_running === 'boolean' ? raw.keepalive_running : undefined,
    continuity_state: membershipParse(KEEPER_CONTINUITY_STATES, asString(raw.continuity_state)),
    continuity_summary: asString(raw.continuity_summary) ?? null,
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

// Stable fallback id for a message whose backend predates R3 and so
// carries no producer-assigned id. Derived from the content (not the merge
// index) so it does not shift when history pages are merged.
function fallbackHistoryEntryId(
  role: string,
  timestamp: string | null | undefined,
  text: string,
): string {
  let hash = 5381
  for (let i = 0; i < text.length; i += 1) {
    hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0
  }
  return `${role}-${timestamp ?? 'entry'}-${(hash >>> 0).toString(36)}`
}

function normalizeHistoryEntry(
  raw: unknown,
  keeperName?: string,
  previousSource: KeeperConversationSource | null = null,
): KeeperConversationEntry | null {
  if (!isRecord(raw)) return null
  const role = normalizeRole(raw.role)
  const rawText = asString(raw.content) ?? asString(raw.preview) ?? ''
  const attachments = normalizeAttachments(raw.attachments)
  const audio = normalizeAudioClip(raw.audio) ?? null
  // Accept attachment-only or audio-only rows: a user may send a file/image
  // with no text, or the assistant may emit a synthesized voice clip with no
  // generated text. Without this guard those persisted rows are dropped on
  // reload even though they are renderable server-side.
  if (!rawText && !attachments?.length && !audio) return null
  const source = normalizeConversationSource(raw.source, role, rawText, previousSource)
  const text = formatKeeperVisibleReply(rawText)
  if (!text && !attachments?.length && !audio) return null
  const timestamp = toIsoTimestamp(raw.ts_unix) ?? toIsoTimestamp(raw.timestamp)
  const label = role === 'assistant' && keeperName ? keeperName : roleLabel(role)
  const surface = isRecord(raw.surface) ? (raw.surface as unknown as SurfaceRef) : null
  // RFC-0233 §7: asString rejects malformed join keys instead of repairing them.
  const turnRef = asString(raw.turn_ref) ?? null
  // keeper_chat_store mints kind=transport_failure (row content is the
  // "Keeper request failed: ..." text) so a reload can tell a failed request
  // apart from a real reply. Map it to the existing error delivery state so
  // the bubble renders the error label/styling instead of a saved reply.
  const delivery: KeeperConversationDelivery =
    asString(raw.kind) === 'transport_failure' ? 'error' : 'history'
  const serverBlocks = normalizeBlocks(raw.blocks, role)
  const blocks = serverBlocks
    ?? ((role === 'assistant' || role === 'system') && text
      ? parseTextToChatBlocks(text)
      : undefined)
  return {
    // R3: key off the producer-assigned server id when present so the
    // render key is stable across history-page merges (the former
    // `${role}-${ts}-${index}` shifted with the merge index and remounted
    // bubbles). Pre-R3 rows fall back to a stable content-derived id.
    id: asString(raw.id) ?? fallbackHistoryEntryId(role, timestamp, rawText),
    role,
    source,
    label,
    text,
    rawText,
    timestamp,
    turnRef,
    delivery,
    streamState: null,
    details: null,
    surface,
    audio,
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
    [name]: [...existing, entry].slice(-THREAD_ENTRY_CAP),
  }
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
    [name]: next.slice(-THREAD_ENTRY_CAP),
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
): void {
  updateThreadEntry(name, entryId, entry => ({
    ...entry,
    streamState,
    delivery,
  }))
}

export function appendAssistantDelta(name: string, entryId: string, delta: string): void {
  updateThreadEntry(name, entryId, entry => ({
    ...entry,
    rawText: `${entry.rawText ?? entry.text}${delta}`,
    text: formatKeeperVisibleReply(`${entry.rawText ?? entry.text}${delta}`),
    streamState: 'streaming',
    delivery: 'streaming',
  }))
}

export function appendAssistantThinkingDelta(
  name: string,
  entryId: string,
  delta: string,
  meta: { oasBlockIndex?: number } = {},
): void {
  if (!delta.trim()) return
  const oasBlockIndex = meta.oasBlockIndex
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const last = existing[existing.length - 1]
    const sameThinkingBlock =
      last?.kind === 'think'
      && (oasBlockIndex === undefined
        ? last.oasBlockIndex === undefined
        : last.oasBlockIndex === oasBlockIndex)
    // Stamp the occurrence time on a NEW think step so the work-trace card can
    // interleave it with tool entries by occurrence order. When consecutive
    // deltas merge into the same step, the first stamp is preserved: the step
    // began at that time, not when the latest fragment arrived.
    const traceSteps: ChatTraceStep[] =
      sameThinkingBlock
        ? [
            ...existing.slice(0, -1),
            withoutUndefined({
              kind: 'think',
              text: `${last.text}${delta}`,
              ts: last.ts,
              oasBlockIndex: last.oasBlockIndex,
            }),
          ]
        : [
            ...existing,
            withoutUndefined({
              kind: 'think',
              text: delta.trimStart(),
              ts: new Date().toISOString(),
              oasBlockIndex,
            }),
          ]
    return {
      ...entry,
      traceSteps,
      streamState: 'thinking',
      delivery: 'streaming',
    }
  })
}

function warnMissingToolTrace(
  op: string,
  keeperName: string,
  entryId: string,
  toolCallId: string,
): void {
  console.warn('[keeper-trace] missing tool trace step', { op, keeperName, entryId, toolCallId })
}

export function appendAssistantToolTraceStep(
  name: string,
  entryId: string,
  step: { toolCallId: string; name: string; ts?: string; oasBlockIndex?: number },
): void {
  const toolCallId = step.toolCallId.trim()
  const toolName = step.name.trim()
  if (!toolCallId || !toolName) {
    console.warn('[keeper-trace] invalid tool trace step', { op: 'start', keeperName: name, entryId })
    return
  }
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const index = existing.findIndex(
      trace => trace.kind === 'tool' && trace.toolCallId === toolCallId,
    )
    const nextStep = withoutUndefined({
      kind: 'tool',
      toolCallId,
      name: toolName,
      status: 'pending',
      ts: step.ts ?? new Date().toISOString(),
      oasBlockIndex: step.oasBlockIndex,
    })
    const traceSteps =
      index === -1
        ? [...existing, nextStep]
        : existing.map((trace, i) =>
            i === index && trace.kind === 'tool'
              ? withoutUndefined({
                  ...trace,
                  name: trace.name || toolName,
                  toolCallId,
                  status: trace.status ?? 'pending',
                  ts: trace.ts ?? nextStep.ts,
                  oasBlockIndex: trace.oasBlockIndex ?? nextStep.oasBlockIndex,
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
  toolCallId: string,
  delta: string,
): void {
  const id = toolCallId.trim()
  if (!id || !delta) return
  let found = false
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const traceSteps = existing.map((trace) => {
      if (trace.kind !== 'tool' || trace.toolCallId !== id) return trace
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
  toolCallId: string,
  snapshot: string,
): void {
  const id = toolCallId.trim()
  if (!id) return
  let found = false
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const traceSteps = existing.map((trace) => {
      if (trace.kind !== 'tool' || trace.toolCallId !== id) return trace
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
  toolCallId: string,
): void {
  const id = toolCallId.trim()
  if (!id) return
  let found = false
  updateThreadEntry(name, entryId, entry => {
    const existing = entry.traceSteps ?? []
    const traceSteps = existing.map((trace) => {
      if (trace.kind !== 'tool' || trace.toolCallId !== id) return trace
      found = true
      return {
        ...trace,
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

// Dedup key for merging server history with locally-appended entries.
// Server ids win when both sides have already converged. User/assistant
// optimistic rows still fall back to role + text because the POST can create
// the local row before the server-minted id is known. Tool rows are execution
// facts and can share argument/output text across separate calls, so they only
// dedup by the explicit `tool-<tool_call_id>` id shape.
function sameConversationEntry(
  left: KeeperConversationEntry,
  right: KeeperConversationEntry,
): boolean {
  if (left.id === right.id) return true
  if (left.role === 'tool' || right.role === 'tool') return false
  return left.role === right.role && left.text === right.text
}

function isInFlightDelivery(delivery: KeeperConversationDelivery): boolean {
  return delivery === 'sending' || delivery === 'streaming' || delivery === 'queued'
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
  // When OAS/MASC provides turn_ref on both the live reply details and the
  // persisted history row, that value is the exact join key. The role+text
  // fallback remains only for legacy rows without turn_ref; `consumed` keeps
  // those fallback matches 1:1 instead of letting duplicate assistant text reuse
  // the first local trace source (#21748).
  consumed: Set<string>,
): KeeperConversationEntry {
  if (historyEntry.role !== 'assistant') return historyEntry
  const historyTurnRef = historyEntry.turnRef?.trim()
  const localTraceSourceByTurnRef = historyTurnRef
    ? localEntries.find(
        entry =>
          entry.role === 'assistant'
          && (entry.traceSteps?.length ?? 0) > 0
          && !consumed.has(entry.id)
          && entry.turnRef?.trim() === historyTurnRef,
      )
    : undefined
  if (localTraceSourceByTurnRef?.traceSteps?.length) {
    consumed.add(localTraceSourceByTurnRef.id)
    return {
      ...historyEntry,
      traceSteps: localTraceSourceByTurnRef.traceSteps,
    }
  }
  const localTraceSource = localEntries.find(
    entry =>
      entry.role === 'assistant'
      && (entry.traceSteps?.length ?? 0) > 0
      && !(entry.turnRef?.trim())
      && !consumed.has(entry.id)
      && sameConversationEntry(entry, historyEntry),
  )
  if (!localTraceSource?.traceSteps?.length) return historyEntry
  consumed.add(localTraceSource.id)
  return {
    ...historyEntry,
    traceSteps: localTraceSource.traceSteps,
  }
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
      // must survive history merges until they finalize. Otherwise a queued
      // assistant with empty text can be mistaken for an older empty-text
      // history row and dropped, making the queued reply look like an error.
      const shouldKeepLocalEntry = isInFlightDelivery(entry.delivery) || !coveredByHistory
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
  // Keep the newest THREAD_ENTRY_CAP entries. After the sort the in-flight tail
  // is last, so the cap trims the oldest history rather than a live row.
  const kept = merged.length > THREAD_ENTRY_CAP ? merged.slice(-THREAD_ENTRY_CAP) : merged
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
  id?: string
  role: string
  content: string
  ts: number
  tool_call_id?: string
  tool_call_name?: string
  source?: string
  surface?: SurfaceRef
  // RFC-0233 §7: MASC-minted "<trace_id>#<absolute_turn>" turn join key.
  turn_ref?: string | null
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
  // RFC-0235 P3: backend-parsed rich chat blocks. When present the dashboard
  // prefers them over its local parser.
  blocks?: ChatBlock[]
}

/** Convert a persisted tool-call row into the same entry shape the live
 *  TOOL_CALL_* stream path produces (keeper-stream.ts): id `tool-<id>`,
 *  role 'tool', label = tool name, text = accumulated argument JSON.
 *  Matching the live convention means a reload re-renders the tool card
 *  and replaceThread dedups it against a still-mounted live entry. The
 *  raw content is used as-is — formatKeeperVisibleReply is for keeper
 *  reply text and would mangle argument JSON. */
function toolHistoryEntry(message: RestChatHistoryMessage): KeeperConversationEntry | null {
  if (!message.tool_call_id || !message.tool_call_name) return null
  return {
    id: toolEntryIdFromCallId(message.tool_call_id),
    role: 'tool',
    source: 'tool_result',
    label: message.tool_call_name,
    text: message.content,
    rawText: message.content,
    timestamp: toIsoTimestamp(message.ts),
    delivery: 'history',
    streamState: null,
    details: null,
    surface: message.surface ?? null,
    // Tool rows share the same untrusted REST boundary; reject malformed
    // turn_ref values here too so this path matches normalizeHistoryEntry.
    turnRef: asString(message.turn_ref) ?? null,
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
    if (message.role === 'tool') {
      // Tool rows do not participate in user/assistant source chaining.
      const toolEntry = toolHistoryEntry(message)
      if (toolEntry) entries.push(toolEntry)
      return
    }
    const normalized = normalizeHistoryEntry(
      {
        id: message.id,
        role: message.role,
        content: message.content,
        ts_unix: message.ts,
        audio: message.audio,
        attachments: message.attachments,
        kind: message.kind,
        blocks: message.blocks,
        turn_ref: message.turn_ref,
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

export function setActiveStream(name: string, entryId: string, controller: AbortController): void {
  keeperStreamEntryIds.set(name, entryId)
  keeperStreamControllers.set(name, controller)
}

export function clearActiveStream(name: string): void {
  keeperStreamEntryIds.delete(name)
  keeperStreamControllers.delete(name)
  clearActiveStreamRequestId(name)
}

export function activeStreamEntryId(name: string): string | null {
  return keeperStreamEntryIds.get(name) ?? null
}

export function getStreamController(name: string): AbortController | undefined {
  return keeperStreamControllers.get(name)
}

export function setActiveStreamRequestId(name: string, requestId: string): void {
  claimLiveSendRequest(requestId, name)
}

export function activeStreamRequestId(name: string): string | null {
  const keeperName = name.trim()
  if (!keeperName) return null
  for (const [requestId, owner] of liveSendRequestOwners) {
    if (owner === keeperName) return requestId
  }
  return null
}

export function clearActiveStreamRequestId(name: string): void {
  const keeperName = name.trim()
  if (!keeperName) return
  for (const [requestId, owner] of liveSendRequestOwners) {
    if (owner === keeperName) liveSendRequestOwners.delete(requestId)
  }
}

/** Release a specific request id from live-send ownership. Returns true if
 *  the id was owned. Use this for race-free cleanup after a confirmed server
 *  cancel so a stale cleanup cannot wipe a newer request id claimed for the
 *  same keeper. */
export function releaseActiveStreamRequestId(requestId: string): boolean {
  const id = requestId.trim()
  if (!id) return false
  return liveSendRequestOwners.delete(id)
}

// --- Live send ownership (in-session, requestId-keyed) ---

export function claimLiveSendRequest(requestId: string, name: string): void {
  const id = requestId.trim()
  const keeperName = name.trim()
  if (!id || !keeperName) return
  clearActiveStreamRequestId(keeperName)
  liveSendRequestOwners.set(id, keeperName)
}

export function releaseLiveSendRequest(requestId: string): void {
  liveSendRequestOwners.delete(requestId.trim())
}

export function liveSendOwnsRequest(requestId: string): boolean {
  return liveSendRequestOwners.has(requestId.trim())
}

export function _resetLiveSendRequestOwnersForTests(): void {
  liveSendRequestOwners.clear()
}
