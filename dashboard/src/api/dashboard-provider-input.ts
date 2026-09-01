import { get, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import { isRecord } from '../components/common/normalize'

export type ProviderInputWire = {
  phase: 'Pre_dispatch_serialization'
  captureId: string | null
  provider: string
  model: string
  httpCodec: string
  stream: boolean
  bodyBytes: number
  bodySha256: string
}

export type ProviderInputSystemPrompt = {
  bytes: number
  sha256: string
  text: string
}

export type ProviderInputMessage = {
  index: number
  role: string
  bytes: number
  sha256: string
  content: unknown
}

export type ProviderInputToolSchema = {
  index: number
  name: string
  bytes: number
  sha256: string
  content: unknown
}

export type ProviderInputSnapshot = {
  keeper: string
  traceId: string
  absoluteTurn: number
  turnRef: string
  runtimeProfile: string
  capturedAt: number
  wire: ProviderInputWire
  systemPrompt: ProviderInputSystemPrompt | null
  messages: ProviderInputMessage[]
  toolSchemas: ProviderInputToolSchema[]
}

function hasExactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  return actual.length === wanted.length && actual.every((key, index) => key === wanted[index])
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null
}

function nonNegativeInteger(value: unknown): number | null {
  return typeof value === 'number'
    && Number.isSafeInteger(value)
    && value >= 0
    ? value
    : null
}

function finiteNonNegative(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
    ? value
    : null
}

function sha256(value: unknown): string | null {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value) ? value : null
}

function decodeWire(raw: unknown): ProviderInputWire | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'phase',
    'capture_id',
    'provider',
    'model',
    'http_codec',
    'stream',
    'body_bytes',
    'body_sha256',
  ])) return null
  const captureId = raw.capture_id === null ? null : nonEmptyString(raw.capture_id)
  const provider = nonEmptyString(raw.provider)
  const model = nonEmptyString(raw.model)
  const httpCodec = nonEmptyString(raw.http_codec)
  const bodyBytes = nonNegativeInteger(raw.body_bytes)
  const bodySha256 = sha256(raw.body_sha256)
  if (
    raw.phase !== 'Pre_dispatch_serialization'
    || (raw.capture_id !== null && captureId === null)
    || provider === null
    || model === null
    || httpCodec === null
    || typeof raw.stream !== 'boolean'
    || bodyBytes === null
    || bodySha256 === null
  ) return null
  return {
    phase: raw.phase,
    captureId,
    provider,
    model,
    httpCodec,
    stream: raw.stream,
    bodyBytes,
    bodySha256,
  }
}

function decodeSystemPrompt(raw: unknown): ProviderInputSystemPrompt | null | undefined {
  if (raw === null) return null
  if (!isRecord(raw) || !hasExactKeys(raw, ['bytes', 'sha256', 'text'])) return undefined
  const bytes = nonNegativeInteger(raw.bytes)
  const digest = sha256(raw.sha256)
  const text = nonEmptyString(raw.text)
  if (bytes === null || digest === null || text === null || new TextEncoder().encode(text).length !== bytes) {
    return undefined
  }
  return { bytes, sha256: digest, text }
}

function decodeIndexed<T>(
  raw: unknown,
  labelKey: 'role' | 'name',
  project: (value: {
    index: number
    label: string
    bytes: number
    sha256: string
    content: unknown
  }) => T,
): T[] | null {
  if (!Array.isArray(raw)) return null
  const decoded: T[] = []
  for (let index = 0; index < raw.length; index += 1) {
    const value = raw[index]
    if (!isRecord(value) || !hasExactKeys(value, [
      'index', labelKey, 'bytes', 'sha256', 'content',
    ])) return null
    const actualIndex = nonNegativeInteger(value.index)
    const label = nonEmptyString(value[labelKey])
    const bytes = nonNegativeInteger(value.bytes)
    const digest = sha256(value.sha256)
    if (actualIndex !== index || label === null || bytes === null || digest === null) return null
    decoded.push(project({ index, label, bytes, sha256: digest, content: value.content }))
  }
  return decoded
}

export function decodeProviderInputSnapshot(raw: unknown): ProviderInputSnapshot | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'dashboard_surface',
    'schema',
    'keeper',
    'trace_id',
    'absolute_turn',
    'turn_ref',
    'runtime_profile',
    'captured_at',
    'wire',
    'system_prompt',
    'messages',
    'tool_schemas',
  ])) return null
  const keeper = nonEmptyString(raw.keeper)
  const traceId = nonEmptyString(raw.trace_id)
  const absoluteTurn = nonNegativeInteger(raw.absolute_turn)
  const turnRef = nonEmptyString(raw.turn_ref)
  const runtimeProfile = nonEmptyString(raw.runtime_profile)
  const capturedAt = finiteNonNegative(raw.captured_at)
  const wire = decodeWire(raw.wire)
  const systemPrompt = decodeSystemPrompt(raw.system_prompt)
  const messages = decodeIndexed(raw.messages, 'role', value => ({
    index: value.index,
    role: value.label,
    bytes: value.bytes,
    sha256: value.sha256,
    content: value.content,
  }))
  const toolSchemas = decodeIndexed(raw.tool_schemas, 'name', value => ({
    index: value.index,
    name: value.label,
    bytes: value.bytes,
    sha256: value.sha256,
    content: value.content,
  }))
  if (
    raw.dashboard_surface !== '/api/v1/keepers/:name/provider-input'
    || raw.schema !== 'masc.resolved-provider-input.v1'
    || keeper === null
    || traceId === null
    || absoluteTurn === null
    || turnRef === null
    || turnRef !== `${traceId}#${absoluteTurn}`
    || runtimeProfile === null
    || capturedAt === null
    || wire === null
    || systemPrompt === undefined
    || messages === null
    || toolSchemas === null
  ) return null
  return {
    keeper,
    traceId,
    absoluteTurn,
    turnRef,
    runtimeProfile,
    capturedAt,
    wire,
    systemPrompt,
    messages,
    toolSchemas,
  }
}

export async function fetchKeeperProviderInput(
  name: string,
  turnRef: string,
  opts?: AbortableRequestOptions,
): Promise<ProviderInputSnapshot> {
  await ensureDevToken()
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/provider-input?turn_ref=${encodeURIComponent(turnRef)}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeProviderInputSnapshot(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper provider-input payload')
    return decoded
  })
}
