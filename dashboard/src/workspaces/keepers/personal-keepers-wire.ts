/**
 * Strict fail-closed wire decoders, validators, and epoch-fenced API clients
 * for Multi-Account Personal Keepers (`/api/v1/auth/keepers*` and
 * `/api/v1/auth/provider-accounts`).
 *
 * Server contracts verified against:
 * - `lib/auth_preview_keeper.ml` (`list`, `make`, `assign`)
 * - `lib/server/server_preview_keeper_turn.ml` (`run`)
 * - `lib/server/server_preview_keeper_conversation.ml` (`start`, `read`, `delete`)
 * - `lib/server/server_preview_keeper_error.ml` (`parts`)
 * - `lib/auth_preview.ml` (`provider_accounts`)
 * - `lib/server/server_account_dashboard_bridge.ml` (`observer_event_visible_to`)
 */

import { authSession } from '../../core/auth'
import type { ObserverFrame } from '../../core/observer'
import { apiGet, apiMutate, type ApiError } from '../../core/transport'
import { err, type Result } from '../../lib/result'
import {
  describeWireType,
  expectRecordElements,
  expectRequiredArrayField,
  expectRequiredNumberField,
  expectRequiredStringField,
  expectWireRecord,
  isJsonRecord,
} from '../../lib/wire-decode'

export const PERSONAL_KEEPERS_PATH = '/api/v1/auth/keepers'
export const PERSONAL_KEEPERS_ASSIGN_PATH = '/api/v1/auth/keepers/assign'
export const PERSONAL_KEEPERS_TURN_PATH = '/api/v1/auth/keepers/turn'
export const PERSONAL_KEEPERS_CONVERSATION_PATH = '/api/v1/auth/keepers/conversation'
export const PERSONAL_PROVIDER_ACCOUNTS_PATH = '/api/v1/auth/provider-accounts'

/** Server `Server_preview_keeper_turn.max_message_bytes`. */
export const PERSONAL_KEEPER_MESSAGE_MAX_BYTES = 4096

/** Server `Keeper_id.Keeper_name.max_length`. */
export const PERSONAL_KEEPER_NAME_MAX_LENGTH = 128

/** Maximum ECMAScript Date timestamp in ms. */
const MAX_SAFE_TIMESTAMP_MS = 8_640_000_000_000_000

/** Matches OCaml `Safe_identifier.portable_name_pattern`. */
const PORTABLE_KEEPER_NAME_RE = /^[A-Za-z0-9._-]+$/

/** Matches OCaml `String.trim` whitespace bytes. */
const OCAML_BLANK_RE = /^[ \t\n\f\r]*$/

export interface PersonalKeeper {
  readonly keeper_id: string
  readonly runtime_id: string | null
}

export interface PersonalProviderAccount {
  readonly provider_account_id: string
  readonly kind: 'login' | 'key'
  readonly integration_id: string
  readonly key: string | null
  readonly removal: string | null
  readonly replacement: string | null
}

export interface PersonalRuntimeOption {
  readonly runtime_id: string
  readonly provider_account_id: string
  readonly integration_id: string | null
  readonly account_kind: 'login' | 'key' | null
  readonly model: string | null
  readonly unread: string | null
}

export interface PersonalProviderAccountsData {
  readonly provider_accounts: readonly PersonalProviderAccount[]
  readonly runtimes: readonly PersonalRuntimeOption[]
}

export interface MadePersonalKeeper {
  readonly keeper_id: string
  readonly record: 'made' | 'existing'
}

export interface AssignedPersonalKeeper {
  readonly keeper_id: string
  readonly runtime_id: string
  readonly record: 'assigned' | 'existing'
}

export interface PersonalConversationSummary {
  readonly conversation_id: string
  readonly provider_account_id: string
  readonly started_at_ms: number
  readonly deletion: 'failed' | null
}

export const KNOWN_PERSONAL_TURN_FAILURES = [
  'not_signed_in',
  'key_refused',
  'no_quota',
  'silent',
  'not_started',
  'configuration_refused',
  'no_answer',
] as const

export type PersonalTurnFailure =
  | (typeof KNOWN_PERSONAL_TURN_FAILURES)[number]
  | 'unrecognised'

export type PersonalTurnOutcome =
  | {
      readonly outcome: 'answered'
      readonly text: string
      readonly model: string
      readonly answered_at_ms: number
    }
  | {
      readonly outcome: 'failed'
      readonly failure: PersonalTurnFailure
      readonly raw_failure: string
      readonly failed_at_ms: number
      readonly model_may_have_read: boolean
    }
  | {
      readonly outcome: 'unrecorded'
      readonly model_may_have_read: boolean
    }

export interface PersonalConversationTurn {
  readonly message: string
  readonly asked_at_ms: number
  readonly outcome: PersonalTurnOutcome
}

export interface PersonalConversationData {
  readonly keeper_id: string
  readonly current_conversation_id: string | null
  readonly conversations: readonly PersonalConversationSummary[]
  readonly conversation_id: string | null
  readonly turns: readonly PersonalConversationTurn[]
}

export type PersonalTurnAnswer =
  | {
      readonly keeper_id: string
      readonly runtime_id: string
      readonly model: string
      readonly text: string
      readonly recorded: true
      readonly conversation_id: string
      readonly continued: boolean
    }
  | {
      readonly keeper_id: string
      readonly runtime_id: string
      readonly model: string
      readonly text: string
      readonly recorded: false
      readonly conversation_id: null
      readonly continued: null
    }

export interface StartedPersonalConversation {
  readonly keeper_id: string
  readonly conversation_id: string
}

export type VendorCopyDeletionState = 'removed' | 'none' | 'may_remain'

export interface DeletedPersonalConversation {
  readonly conversation_id: string
  readonly vendor_copy: VendorCopyDeletionState
}

export const MA_KEEPER_OBSERVER_EVENTS = [
  'keeper_chat_operation_event',
  'keeper_chat_appended',
  'keeper_turn_preview_changed',
  'keeper_tool_call',
  'keeper_tool_approval_waits_changed',
  'keeper_lifecycle',
  'keeper_compaction',
  'keeper_handoff',
  'keeper_guardrail',
] as const

export type MaKeeperObserverEventType = (typeof MA_KEEPER_OBSERVER_EVENTS)[number]

const MA_KEEPER_OBSERVER_EVENT_SET: ReadonlySet<string> = new Set(MA_KEEPER_OBSERVER_EVENTS)

export interface PersonalKeeperObserverSignal {
  readonly eventType: MaKeeperObserverEventType
  readonly keeper: string | null
  readonly summary: string
  readonly textTail: string | null
  readonly activity: string | null
  readonly refreshKeepers: boolean
  readonly refreshConversation: boolean
  readonly receivedAtMs: number
}

// ── Validators ────────────────────────────────────────────────────────────

export function utf8ByteLength(text: string): number {
  return new TextEncoder().encode(text).length
}

export function validatePersonalKeeperName(
  raw: string,
): { readonly ok: true; readonly value: string } | { readonly ok: false; readonly error: string } {
  const trimmed = raw.trim()
  if (trimmed.length === 0) {
    return { ok: false, error: 'Keeper 이름을 입력하세요.' }
  }
  if (trimmed === '.' || trimmed === '..') {
    return { ok: false, error: '예약된 경로 이름(. 또는 ..)은 사용할 수 없습니다.' }
  }
  if (trimmed.length > PERSONAL_KEEPER_NAME_MAX_LENGTH) {
    return {
      ok: false,
      error: `Keeper 이름은 최대 ${PERSONAL_KEEPER_NAME_MAX_LENGTH}자까지 입력할 수 있습니다.`,
    }
  }
  if (!PORTABLE_KEEPER_NAME_RE.test(trimmed)) {
    return {
      ok: false,
      error: 'Keeper 이름은 영문, 숫자, 마침표(.), 밑줄(_), 하이픈(-)만 사용할 수 있습니다.',
    }
  }
  return { ok: true, value: trimmed }
}

export function validatePersonalTurnMessage(
  message: string,
):
  | { readonly ok: true; readonly bytes: number }
  | { readonly ok: false; readonly reason: 'blank' | 'too_long'; readonly bytes: number } {
  const bytes = utf8ByteLength(message)
  if (OCAML_BLANK_RE.test(message)) {
    return { ok: false, reason: 'blank', bytes }
  }
  if (bytes > PERSONAL_KEEPER_MESSAGE_MAX_BYTES) {
    return { ok: false, reason: 'too_long', bytes }
  }
  return { ok: true, bytes }
}

// ── Strict Field Decoders ─────────────────────────────────────────────────

function expectNonEmptyStringField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): string {
  const value = expectRequiredStringField(record, field, context)
  if (value.trim().length === 0) {
    throw new Error(`${context}: "${field}" 필드는 비어 있지 않은 문자열이어야 합니다.`)
  }
  return value
}

function expectNullableNonEmptyStringField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): string | null {
  if (!(field in record)) {
    throw new Error(`${context}: "${field}" 필드가 누락되었습니다 (null 또는 문자열 필요).`)
  }
  const value = record[field]
  if (value === null) return null
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(
      `${context}: "${field}" 필드는 null 또는 비어 있지 않은 문자열이어야 합니다 (${describeWireType(value)} 수신).`,
    )
  }
  return value
}

function expectNullableStringField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): string | null {
  if (!(field in record)) {
    throw new Error(`${context}: "${field}" 필드가 누락되었습니다 (null 또는 문자열 필요).`)
  }
  const value = record[field]
  if (value === null) return null
  if (typeof value !== 'string') {
    throw new Error(
      `${context}: "${field}" 필드는 null 또는 문자열이어야 합니다 (${describeWireType(value)} 수신).`,
    )
  }
  return value
}

function expectOptionalStringField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): string | null {
  const value = record[field]
  if (value === undefined) return null
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(
      `${context}: "${field}" 필드는 문자열이어야 합니다 (${describeWireType(value)} 수신).`,
    )
  }
  return value
}

function expectRequiredBooleanField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): boolean {
  const value = record[field]
  if (typeof value !== 'boolean') {
    throw new Error(
      `${context}: "${field}" 필드는 필수 불리언입니다 (${describeWireType(value)} 수신).`,
    )
  }
  return value
}

function expectSafeTimestampMsField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): number {
  const value = expectRequiredNumberField(record, field, context)
  if (!Number.isSafeInteger(value) || value < 0 || value > MAX_SAFE_TIMESTAMP_MS) {
    throw new Error(`${context}: "${field}" 필드는 유효한 epoch 밀리초 정수여야 합니다 (${value} 수신).`)
  }
  return value
}

// ── Strict Endpoint Payload Decoders ──────────────────────────────────────

export function decodePersonalKeepersList(raw: unknown): readonly PersonalKeeper[] {
  const ctx = `GET ${PERSONAL_KEEPERS_PATH}`
  const rec = expectWireRecord(raw, ctx)
  const rawKeepers = expectRequiredArrayField<unknown>(rec, 'keepers', ctx)
  const rows = expectRecordElements<Record<string, unknown>>(rawKeepers, 'keepers', ctx)
  const seen = new Set<string>()
  const out: PersonalKeeper[] = []
  for (let i = 0; i < rows.length; i += 1) {
    const row = rows[i]!
    const rowCtx = `${ctx} keepers[${i}]`
    const keeperId = expectNonEmptyStringField(row, 'keeper_id', rowCtx)
    const runtimeId = expectNullableNonEmptyStringField(row, 'runtime_id', rowCtx)
    if (seen.has(keeperId)) {
      throw new Error(`${ctx}: 중복된 keeper_id "${keeperId}"가 응답에 포함되었습니다.`)
    }
    seen.add(keeperId)
    out.push({ keeper_id: keeperId, runtime_id: runtimeId })
  }
  return out
}

export function decodePersonalProviderAccounts(raw: unknown): PersonalProviderAccountsData {
  const ctx = `GET ${PERSONAL_PROVIDER_ACCOUNTS_PATH}`
  const rec = expectWireRecord(raw, ctx)
  const rawAccounts = expectRequiredArrayField<unknown>(rec, 'provider_accounts', ctx)
  const accountRows = expectRecordElements<Record<string, unknown>>(rawAccounts, 'provider_accounts', ctx)
  const rawRuntimes = expectRequiredArrayField<unknown>(rec, 'runtimes', ctx)
  const runtimeRows = expectRecordElements<Record<string, unknown>>(rawRuntimes, 'runtimes', ctx)

  const accountById = new Map<string, PersonalProviderAccount>()
  const providerAccounts: PersonalProviderAccount[] = []
  for (let i = 0; i < accountRows.length; i += 1) {
    const row = accountRows[i]!
    const rowCtx = `${ctx} provider_accounts[${i}]`
    const providerAccountId = expectNonEmptyStringField(row, 'provider_account_id', rowCtx)
    const integrationId = expectNonEmptyStringField(row, 'integration_id', rowCtx)
    const kindRaw = expectNonEmptyStringField(row, 'kind', rowCtx)
    if (kindRaw !== 'login' && kindRaw !== 'key') {
      throw new Error(`${rowCtx}: "kind" 필드는 "login" 또는 "key"여야 합니다 ("${kindRaw}" 수신).`)
    }
    if (accountById.has(providerAccountId)) {
      throw new Error(`${ctx}: 중복된 provider_account_id "${providerAccountId}"가 응답에 포함되었습니다.`)
    }
    const account: PersonalProviderAccount = {
      provider_account_id: providerAccountId,
      kind: kindRaw,
      integration_id: integrationId,
      key: expectOptionalStringField(row, 'key', rowCtx),
      removal: expectOptionalStringField(row, 'removal', rowCtx),
      replacement: expectOptionalStringField(row, 'replacement', rowCtx),
    }
    accountById.set(providerAccountId, account)
    providerAccounts.push(account)
  }

  const seenRuntimes = new Set<string>()
  const runtimes: PersonalRuntimeOption[] = []
  for (let i = 0; i < runtimeRows.length; i += 1) {
    const row = runtimeRows[i]!
    const rowCtx = `${ctx} runtimes[${i}]`
    const runtimeId = expectNonEmptyStringField(row, 'runtime_id', rowCtx)
    const providerAccountId = expectNonEmptyStringField(row, 'provider_account_id', rowCtx)
    const model = expectNullableStringField(row, 'model', rowCtx)
    const unread = expectOptionalStringField(row, 'unread', rowCtx)
    if (seenRuntimes.has(runtimeId)) {
      throw new Error(`${ctx}: 중복된 runtime_id "${runtimeId}"가 응답에 포함되었습니다.`)
    }
    seenRuntimes.add(runtimeId)
    const linked = accountById.get(providerAccountId)
    runtimes.push({
      runtime_id: runtimeId,
      provider_account_id: providerAccountId,
      integration_id: linked?.integration_id ?? null,
      account_kind: linked?.kind ?? null,
      model,
      unread,
    })
  }

  return { provider_accounts: providerAccounts, runtimes }
}

export function decodeMadePersonalKeeper(raw: unknown, expectedKeeperId: string): MadePersonalKeeper {
  const ctx = `POST ${PERSONAL_KEEPERS_PATH}`
  const rec = expectWireRecord(raw, ctx)
  const keeperId = expectNonEmptyStringField(rec, 'keeper_id', ctx)
  if (keeperId !== expectedKeeperId) {
    throw new Error(`${ctx}: 응답 keeper_id("${keeperId}")가 요청한 "${expectedKeeperId}"와 다릅니다.`)
  }
  const record = expectNonEmptyStringField(rec, 'record', ctx)
  if (record !== 'made' && record !== 'existing') {
    throw new Error(`${ctx}: "record" 필드는 "made" 또는 "existing"이어야 합니다 ("${record}" 수신).`)
  }
  return { keeper_id: keeperId, record }
}

export function decodeAssignedPersonalKeeper(
  raw: unknown,
  expectedKeeperId: string,
  expectedRuntimeId: string,
): AssignedPersonalKeeper {
  const ctx = `POST ${PERSONAL_KEEPERS_ASSIGN_PATH}`
  const rec = expectWireRecord(raw, ctx)
  const keeperId = expectNonEmptyStringField(rec, 'keeper_id', ctx)
  const runtimeId = expectNonEmptyStringField(rec, 'runtime_id', ctx)
  if (keeperId !== expectedKeeperId) {
    throw new Error(`${ctx}: 응답 keeper_id("${keeperId}")가 요청한 "${expectedKeeperId}"와 다릅니다.`)
  }
  if (runtimeId !== expectedRuntimeId) {
    throw new Error(`${ctx}: 응답 runtime_id("${runtimeId}")가 요청한 "${expectedRuntimeId}"와 다릅니다.`)
  }
  const record = expectNonEmptyStringField(rec, 'record', ctx)
  if (record !== 'assigned' && record !== 'existing') {
    throw new Error(`${ctx}: "record" 필드는 "assigned" 또는 "existing"이어야 합니다 ("${record}" 수신).`)
  }
  return { keeper_id: keeperId, runtime_id: runtimeId, record }
}

function decodeTurnOutcome(row: Record<string, unknown>, context: string): PersonalTurnOutcome {
  const outcome = expectNonEmptyStringField(row, 'outcome', context)
  if (outcome === 'answered') {
    const text = expectRequiredStringField(row, 'text', context)
    const model = expectRequiredStringField(row, 'model', context)
    const answeredAtMs = expectSafeTimestampMsField(row, 'answered_at_ms', context)
    return { outcome: 'answered', text, model, answered_at_ms: answeredAtMs }
  }
  if (outcome === 'failed') {
    const rawFailure = expectNonEmptyStringField(row, 'failure', context)
    const known = KNOWN_PERSONAL_TURN_FAILURES.find((item) => item === rawFailure)
    const failedAtMs = expectSafeTimestampMsField(row, 'failed_at_ms', context)
    const modelMayHaveRead = expectRequiredBooleanField(row, 'model_may_have_read', context)
    return {
      outcome: 'failed',
      failure: known ?? 'unrecognised',
      raw_failure: rawFailure,
      failed_at_ms: failedAtMs,
      model_may_have_read: modelMayHaveRead,
    }
  }
  if (outcome === 'unrecorded') {
    const modelMayHaveRead = expectRequiredBooleanField(row, 'model_may_have_read', context)
    return { outcome: 'unrecorded', model_may_have_read: modelMayHaveRead }
  }
  throw new Error(`${context}: 알 수 없는 outcome 값 "${outcome}"입니다.`)
}

export function decodePersonalConversation(
  raw: unknown,
  expectedKeeperId: string,
  requestedConversationId?: string | null,
): PersonalConversationData {
  const ctx = `GET ${PERSONAL_KEEPERS_CONVERSATION_PATH}`
  const rec = expectWireRecord(raw, ctx)
  const keeperId = expectNonEmptyStringField(rec, 'keeper_id', ctx)
  if (keeperId !== expectedKeeperId) {
    throw new Error(`${ctx}: 응답 keeper_id("${keeperId}")가 요청한 "${expectedKeeperId}"와 다릅니다.`)
  }
  const currentConversationId = expectNullableNonEmptyStringField(rec, 'current_conversation_id', ctx)
  const shownConversationId = expectNullableNonEmptyStringField(rec, 'conversation_id', ctx)

  if (requestedConversationId) {
    if (shownConversationId !== requestedConversationId) {
      throw new Error(
        `${ctx}: 응답 conversation_id("${String(shownConversationId)}")가 요청한 "${requestedConversationId}"와 다릅니다.`,
      )
    }
  } else if (shownConversationId !== currentConversationId) {
    throw new Error(
      `${ctx}: 현재 대화 조회 응답의 conversation_id("${String(shownConversationId)}")와 current_conversation_id("${String(currentConversationId)}")가 일치하지 않습니다.`,
    )
  }

  const rawConversations = expectRequiredArrayField<unknown>(rec, 'conversations', ctx)
  const convRows = expectRecordElements<Record<string, unknown>>(rawConversations, 'conversations', ctx)
  const seenIds = new Set<string>()
  const conversations: PersonalConversationSummary[] = []
  for (let i = 0; i < convRows.length; i += 1) {
    const row = convRows[i]!
    const rowCtx = `${ctx} conversations[${i}]`
    const convId = expectNonEmptyStringField(row, 'conversation_id', rowCtx)
    const providerAccountId = expectNonEmptyStringField(row, 'provider_account_id', rowCtx)
    const startedAtMs = expectSafeTimestampMsField(row, 'started_at_ms', rowCtx)
    let deletion: 'failed' | null = null
    if ('deletion' in row && row.deletion !== undefined) {
      if (row.deletion !== 'failed') {
        throw new Error(
          `${rowCtx}: "deletion" 필드는 생략되거나 "failed"여야 합니다 (${describeWireType(row.deletion)} 수신).`,
        )
      }
      deletion = 'failed'
    }
    if (seenIds.has(convId)) {
      throw new Error(`${ctx}: 중복된 conversation_id "${convId}"가 응답에 포함되었습니다.`)
    }
    seenIds.add(convId)
    conversations.push({
      conversation_id: convId,
      provider_account_id: providerAccountId,
      started_at_ms: startedAtMs,
      deletion,
    })
  }

  if (currentConversationId !== null && !seenIds.has(currentConversationId)) {
    throw new Error(`${ctx}: current_conversation_id("${currentConversationId}")가 conversations 목록에 없습니다.`)
  }
  if (shownConversationId !== null && !seenIds.has(shownConversationId)) {
    throw new Error(`${ctx}: conversation_id("${shownConversationId}")가 conversations 목록에 없습니다.`)
  }

  const rawTurns = expectRequiredArrayField<unknown>(rec, 'turns', ctx)
  const turnRows = expectRecordElements<Record<string, unknown>>(rawTurns, 'turns', ctx)
  if (shownConversationId === null && turnRows.length > 0) {
    throw new Error(`${ctx}: conversation_id가 null인데 turns가 ${turnRows.length}건 존재합니다.`)
  }

  const turns: PersonalConversationTurn[] = []
  for (let i = 0; i < turnRows.length; i += 1) {
    const row = turnRows[i]!
    const rowCtx = `${ctx} turns[${i}]`
    const message = expectRequiredStringField(row, 'message', rowCtx)
    const askedAtMs = expectSafeTimestampMsField(row, 'asked_at_ms', rowCtx)
    const outcome = decodeTurnOutcome(row, rowCtx)
    turns.push({ message, asked_at_ms: askedAtMs, outcome })
  }

  return {
    keeper_id: keeperId,
    current_conversation_id: currentConversationId,
    conversations,
    conversation_id: shownConversationId,
    turns,
  }
}

export function decodePersonalTurnAnswer(raw: unknown, expectedKeeperId: string): PersonalTurnAnswer {
  const ctx = `POST ${PERSONAL_KEEPERS_TURN_PATH}`
  const rec = expectWireRecord(raw, ctx)
  const keeperId = expectNonEmptyStringField(rec, 'keeper_id', ctx)
  if (keeperId !== expectedKeeperId) {
    throw new Error(`${ctx}: 응답 keeper_id("${keeperId}")가 요청한 "${expectedKeeperId}"와 다릅니다.`)
  }
  const runtimeId = expectNonEmptyStringField(rec, 'runtime_id', ctx)
  const model = expectNonEmptyStringField(rec, 'model', ctx)
  const text = expectRequiredStringField(rec, 'text', ctx)

  const hasConversationId = rec.conversation_id !== undefined
  const hasContinued = rec.continued !== undefined
  if (hasConversationId !== hasContinued) {
    throw new Error(`${ctx}: conversation_id와 continued 필드는 함께 있거나 함께 생략되어야 합니다.`)
  }
  if (hasConversationId) {
    const conversationId = expectNonEmptyStringField(rec, 'conversation_id', ctx)
    const continued = expectRequiredBooleanField(rec, 'continued', ctx)
    return {
      keeper_id: keeperId,
      runtime_id: runtimeId,
      model,
      text,
      recorded: true,
      conversation_id: conversationId,
      continued,
    }
  }
  return {
    keeper_id: keeperId,
    runtime_id: runtimeId,
    model,
    text,
    recorded: false,
    conversation_id: null,
    continued: null,
  }
}

export function decodeStartedPersonalConversation(
  raw: unknown,
  expectedKeeperId: string,
): StartedPersonalConversation {
  const ctx = `POST ${PERSONAL_KEEPERS_CONVERSATION_PATH}`
  const rec = expectWireRecord(raw, ctx)
  const keeperId = expectNonEmptyStringField(rec, 'keeper_id', ctx)
  if (keeperId !== expectedKeeperId) {
    throw new Error(`${ctx}: 응답 keeper_id("${keeperId}")가 요청한 "${expectedKeeperId}"와 다릅니다.`)
  }
  const conversationId = expectNonEmptyStringField(rec, 'conversation_id', ctx)
  return { keeper_id: keeperId, conversation_id: conversationId }
}

export function decodeDeletedPersonalConversation(
  raw: unknown,
  expectedConversationId: string,
): DeletedPersonalConversation {
  const ctx = `DELETE ${PERSONAL_KEEPERS_CONVERSATION_PATH}/${expectedConversationId}`
  const rec = expectWireRecord(raw, ctx)
  const conversationId = expectNonEmptyStringField(rec, 'conversation_id', ctx)
  if (conversationId !== expectedConversationId) {
    throw new Error(
      `${ctx}: 응답 conversation_id("${conversationId}")가 요청한 "${expectedConversationId}"와 다릅니다.`,
    )
  }
  const vendorCopy = expectNonEmptyStringField(rec, 'vendor_copy', ctx)
  if (vendorCopy !== 'removed' && vendorCopy !== 'none' && vendorCopy !== 'may_remain') {
    throw new Error(
      `${ctx}: "vendor_copy" 필드는 "removed", "none", "may_remain" 중 하나여야 합니다 ("${vendorCopy}" 수신).`,
    )
  }
  return { conversation_id: conversationId, vendor_copy: vendorCopy }
}

// ── Multi-Account Observer SSE Frame Decoder (`GET /api/v1/auth/events`) ──

function trimOrNull(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null
}

/**
 * Decodes an owned-keeper event delivered on `GET /api/v1/auth/events`
 * (`server_account_dashboard_bridge.ml:194-206`). Returns `null` for non-keeper
 * or malformed frames so unrelated workspace frames are ignored cleanly.
 */
export function decodePersonalKeeperObserverFrame(
  frame: ObserverFrame,
): PersonalKeeperObserverSignal | null {
  if (!isJsonRecord(frame.data)) return null
  const data = frame.data
  const payload = isJsonRecord(data.payload)
    ? data.payload
    : isJsonRecord(data.params)
      ? data.params
      : data

  const rawType = trimOrNull(payload.type) ?? trimOrNull(data.type) ?? trimOrNull(frame.event)
  if (!rawType || !MA_KEEPER_OBSERVER_EVENT_SET.has(rawType)) return null
  const eventType = rawType as MaKeeperObserverEventType

  const keeper =
    trimOrNull(payload.name)
    ?? trimOrNull(payload.keeper)
    ?? trimOrNull(payload.keeper_name)
    ?? trimOrNull(data.name)
    ?? trimOrNull(data.keeper)
    ?? trimOrNull(data.keeper_name)

  const observation = isJsonRecord(payload.observation) ? payload.observation : null
  const preview = observation && isJsonRecord(observation.preview)
    ? observation.preview
    : isJsonRecord(payload.preview)
      ? payload.preview
      : null

  const statusText = (preview && trimOrNull(preview.status_text)) ?? trimOrNull(payload.status_text)
  const activity = (preview && trimOrNull(preview.activity)) ?? trimOrNull(payload.activity)
  const textTail = (preview && trimOrNull(preview.text_tail)) ?? trimOrNull(payload.text_tail)
  const toolName = trimOrNull(payload.tool) ?? trimOrNull(payload.tool_name)
  const stateLabel = trimOrNull(payload.state) ?? trimOrNull(payload.phase)

  const summaryParts = [
    statusText,
    activity && statusText !== activity ? activity : null,
    toolName ? `tool:${toolName}` : null,
    stateLabel,
  ].filter((part): part is string => part !== null)

  const summary = summaryParts.length > 0 ? summaryParts.join(' · ') : eventType

  return {
    eventType,
    keeper,
    summary,
    textTail,
    activity,
    refreshKeepers:
      eventType === 'keeper_lifecycle'
      || eventType === 'keeper_handoff'
      || eventType === 'keeper_compaction',
    refreshConversation:
      eventType === 'keeper_chat_appended'
      || eventType === 'keeper_chat_operation_event',
    receivedAtMs: Date.now(),
  }
}

// ── Multi-Account Guard & API Clients ─────────────────────────────────────

function requireMultiAccountSession(): Result<true, ApiError> {
  if (authSession.peek().kind !== 'multi_account_signed_in') {
    return err({
      kind: 'forbidden',
      status: null,
      code: 'multi_account_required',
      message: '개인 Keeper API(/api/v1/auth/keepers)는 멀티 계정 로그인 세션 전용입니다.',
      retryable: false,
    })
  }
  return { ok: true, value: true }
}

export function fetchPersonalKeepersApi(
  signal?: AbortSignal,
): Promise<Result<readonly PersonalKeeper[], ApiError>> {
  const guard = requireMultiAccountSession()
  if (!guard.ok) return Promise.resolve(guard)
  return apiGet<readonly PersonalKeeper[]>(PERSONAL_KEEPERS_PATH, {
    signal,
    decode: decodePersonalKeepersList,
  })
}

export function fetchPersonalProviderAccountsApi(
  signal?: AbortSignal,
): Promise<Result<PersonalProviderAccountsData, ApiError>> {
  const guard = requireMultiAccountSession()
  if (!guard.ok) return Promise.resolve(guard)
  return apiGet<PersonalProviderAccountsData>(PERSONAL_PROVIDER_ACCOUNTS_PATH, {
    signal,
    decode: decodePersonalProviderAccounts,
  })
}

export function createPersonalKeeperApi(
  keeperId: string,
  signal?: AbortSignal,
): Promise<Result<MadePersonalKeeper, ApiError>> {
  const guard = requireMultiAccountSession()
  if (!guard.ok) return Promise.resolve(guard)
  // Exact 1-key wire contract (`auth_preview_keeper.ml:125`).
  return apiMutate<MadePersonalKeeper>(
    'POST',
    PERSONAL_KEEPERS_PATH,
    { keeper_id: keeperId },
    { signal, decode: (raw) => decodeMadePersonalKeeper(raw, keeperId) },
  )
}

export function assignPersonalKeeperRuntimeApi(
  keeperId: string,
  runtimeId: string,
  signal?: AbortSignal,
): Promise<Result<AssignedPersonalKeeper, ApiError>> {
  const guard = requireMultiAccountSession()
  if (!guard.ok) return Promise.resolve(guard)
  // Strict key order required by `auth_preview_keeper.ml:167`: keeper_id first, runtime_id second.
  return apiMutate<AssignedPersonalKeeper>(
    'POST',
    PERSONAL_KEEPERS_ASSIGN_PATH,
    { keeper_id: keeperId, runtime_id: runtimeId },
    { signal, decode: (raw) => decodeAssignedPersonalKeeper(raw, keeperId, runtimeId) },
  )
}

export function fetchPersonalConversationApi(
  keeperId: string,
  conversationId?: string | null,
  signal?: AbortSignal,
): Promise<Result<PersonalConversationData, ApiError>> {
  const guard = requireMultiAccountSession()
  if (!guard.ok) return Promise.resolve(guard)
  // Strict query params (`server_preview_keeper_conversation.ml:56-65`): no extra or duplicate params.
  const params = new URLSearchParams()
  params.set('keeper_id', keeperId)
  if (conversationId) {
    params.set('conversation_id', conversationId)
  }
  return apiGet<PersonalConversationData>(`${PERSONAL_KEEPERS_CONVERSATION_PATH}?${params.toString()}`, {
    signal,
    decode: (raw) => decodePersonalConversation(raw, keeperId, conversationId),
  })
}

export function startPersonalConversationApi(
  keeperId: string,
  signal?: AbortSignal,
): Promise<Result<StartedPersonalConversation, ApiError>> {
  const guard = requireMultiAccountSession()
  if (!guard.ok) return Promise.resolve(guard)
  // Exact 1-key wire contract (`server_preview_keeper_conversation.ml:21`).
  return apiMutate<StartedPersonalConversation>(
    'POST',
    PERSONAL_KEEPERS_CONVERSATION_PATH,
    { keeper_id: keeperId },
    { signal, decode: (raw) => decodeStartedPersonalConversation(raw, keeperId) },
  )
}

export function sendPersonalKeeperTurnApi(
  keeperId: string,
  message: string,
  signal?: AbortSignal,
): Promise<Result<PersonalTurnAnswer, ApiError>> {
  const guard = requireMultiAccountSession()
  if (!guard.ok) return Promise.resolve(guard)
  // Exact 2-key wire contract (`server_preview_keeper_turn.ml:19-28`), synchronous up to 120s.
  return apiMutate<PersonalTurnAnswer>(
    'POST',
    PERSONAL_KEEPERS_TURN_PATH,
    { keeper_id: keeperId, message },
    { signal, decode: (raw) => decodePersonalTurnAnswer(raw, keeperId) },
  )
}

export function deletePersonalConversationApi(
  conversationId: string,
  signal?: AbortSignal,
): Promise<Result<DeletedPersonalConversation, ApiError>> {
  const guard = requireMultiAccountSession()
  if (!guard.ok) return Promise.resolve(guard)
  return apiMutate<DeletedPersonalConversation>(
    'DELETE',
    `${PERSONAL_KEEPERS_CONVERSATION_PATH}/${encodeURIComponent(conversationId)}`,
    undefined,
    { signal, decode: (raw) => decodeDeletedPersonalConversation(raw, conversationId) },
  )
}

// ── Honest Error & Outcome Formatters ─────────────────────────────────────

export function formatPersonalTurnFailure(
  failure: PersonalTurnFailure,
  rawFailure: string,
): string {
  switch (failure) {
    case 'not_signed_in':
      return '이 런타임의 공급자 계정이 로그인되어 있지 않습니다. Runtime → Quotas에서 다시 로그인하세요.'
    case 'key_refused':
      return '공급자가 이 런타임의 API 키를 거부했습니다. Runtime → Quotas에서 키를 교체하세요.'
    case 'no_quota':
      return '이 런타임 계정의 남은 할당량이 없습니다. 할당량이 복구된 뒤 다시 시도하세요.'
    case 'silent':
      return '클라이언트가 제한 시간 동안 응답을 보내지 않아 턴이 중단되었습니다.'
    case 'not_started':
      return '모델 클라이언트를 시작하지 못했습니다. 잠시 뒤 다시 시도하세요.'
    case 'configuration_refused':
      return '클라이언트가 이 런타임의 설정을 거부했습니다. 서버 관리자에게 문의하세요.'
    case 'no_answer':
      return 'Keeper가 응답을 남기지 않고 턴을 종료했습니다. 반복되면 새 대화를 시작하세요.'
    case 'unrecognised':
      return `알 수 없는 턴 실패 코드 (${rawFailure})`
  }
}

export function formatVendorCopyOutcome(vendorCopy: VendorCopyDeletionState): string {
  switch (vendorCopy) {
    case 'removed':
      return '대화와 공급자 측 사본을 모두 삭제했습니다.'
    case 'none':
      return '대화 기록을 삭제했습니다.'
    case 'may_remain':
      return '로컬 대화 기록은 삭제했지만 공급자 측 사본이 남아 있을 수 있습니다.'
  }
}

export function formatPersonalKeeperError(
  error: ApiError,
  step: 'list' | 'create' | 'assign' | 'read' | 'turn' | 'start' | 'delete',
): string {
  if (error.kind === 'decode') {
    return `서버 응답 형식이 계약과 다릅니다: ${error.message}`
  }
  if (error.kind === 'unauthorized') {
    return '세션이 만료되었거나 인증이 필요합니다. Account에서 다시 로그인하세요.'
  }
  if (error.kind === 'csrf_rejected') {
    return 'CSRF 검증이 거부되었습니다. 잠시 뒤 다시 시도하세요.'
  }
  const code = error.code
  switch (code) {
    case 'message_too_long':
      return `메시지가 최대 ${PERSONAL_KEEPER_MESSAGE_MAX_BYTES}바이트를 초과했습니다.`
    case 'message_blank':
      return '비어 있는 메시지는 보낼 수 없습니다.'
    case 'keeper_has_no_runtime':
      return '이 Keeper에 연결된 런타임이 없습니다. 먼저 개인 런타임을 연결하세요.'
    case 'account_call_running':
      return '이 런타임 계정에서 다른 호출이 진행 중입니다. 완료된 뒤 다시 시도하세요.'
    case 'conversation_on_other_subscription':
      return '현재 대화가 다른 공급자 계정에서 시작되었습니다. 새 대화를 시작해 이어가세요.'
    case 'runtime_reassigned':
      return '요청 도중 Keeper의 런타임이 변경되었습니다. 다시 시도하세요.'
    case 'runtime_not_supported':
      return '이 런타임에서는 개인 Keeper 대화를 실행할 수 없습니다. 다른 런타임을 선택하세요.'
    case 'native_tools_refused':
      return '멀티 계정 정책상 네이티브 도구가 필요한 이 런타임은 실행할 수 없습니다. 다른 런타임을 선택하세요.'
    case 'account_runtime_invalid':
      return `런타임 설정이 유효하지 않습니다: ${error.message}`
    case 'turn_refused':
      return `턴 실행이 거부되었습니다: ${error.message}`
    case 'deletion_refused':
      return '계정이 비활성 상태여서 대화를 삭제할 수 없습니다.'
    case 'unknown_keeper':
      return '소유한 Keeper 목록에서 대상을 찾을 수 없습니다. 목록을 새로고침하세요.'
    case 'unknown_conversation':
      return '해당 대화를 찾을 수 없습니다. 이미 삭제되었을 수 있습니다.'
    case 'unknown_account':
      return '런타임에 연결된 공급자 계정을 찾을 수 없습니다. Runtime → Quotas를 확인하세요.'
    case 'not_signed_in':
      return '이 런타임의 공급자 계정이 로그인되어 있지 않습니다. Runtime → Quotas에서 연결하세요.'
    case 'key_missing':
      return '이 런타임의 API 키가 서버에 없습니다. Runtime → Quotas에서 키를 등록하세요.'
    case 'key_unreadable':
      return '서버가 이 런타임의 API 키를 읽을 수 없습니다. Runtime → Quotas에서 키를 교체하세요.'
    case 'key_refused':
      return '공급자가 이 런타임의 API 키를 거부했습니다. Runtime → Quotas에서 키를 교체하세요.'
    case 'no_quota':
      return '이 런타임 계정의 남은 할당량이 없습니다.'
    case 'silent':
      return '클라이언트가 제한 시간 동안 응답하지 않아 중단되었습니다.'
    case 'not_started':
      return '클라이언트를 시작하지 못했습니다. 잠시 뒤 다시 시도하세요.'
    case 'configuration_refused':
      return '클라이언트가 이 런타임의 설정을 거부했습니다.'
    case 'no_answer':
      return 'Keeper가 답을 남기지 않고 종료했습니다. 계속 반복되면 새 대화를 시작하세요.'
    case 'answer_unrecorded':
      return 'Keeper가 응답했지만 서버가 대화 기록에 저장하지 못했습니다.'
    case 'conversation_row_half_written':
      return '이전 중단으로 대화 기록 마지막 줄이 불완전합니다. 새 대화를 시작하면 정리됩니다.'
    case 'conversation_row_not_understood':
      return '대화 기록에 해석할 수 없는 줄이 있습니다. 서버 관리자에게 문의하세요.'
    case 'conversation_record_unavailable':
      return '대화 기록을 읽거나 쓸 수 없습니다. 잠시 뒤 다시 시도하세요.'
    case 'conversation_not_deleted':
      return '대화 파일을 완전히 삭제하지 못해 삭제 실패 상태로 표시되었습니다. 다시 삭제를 시도하세요.'
    case 'invalid_request':
      return `요청 형식이 올바르지 않습니다: ${error.message}`
    case 'server_unavailable':
    case 'internal_error':
      return error.message
    default: {
      if (error.kind === 'forbidden') {
        return step === 'read'
          ? '대화 기록 조회 권한(manage_own_keeper + read_state)이 부족하거나 계정이 비활성 상태입니다.'
          : `요청 권한이 거부되었습니다 (403): ${error.message}`
      }
      return error.message
    }
  }
}
