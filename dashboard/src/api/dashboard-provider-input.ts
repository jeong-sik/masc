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

// One retained part of the request, in the order the request carries them:
// the system prompt, the messages, the tool schemas. `index` is the position
// the server numbers for /provider-input/part?index=.
export type ProviderInputPart =
  | { kind: 'system_prompt'; index: number; bytes: number; sha256: string }
  | { kind: 'message'; role: string; index: number; bytes: number; sha256: string }
  | { kind: 'tool_schema'; name: string; index: number; bytes: number; sha256: string }

// The parts list carries no text. A part's text is read with
// fetchKeeperProviderInputPart when a reader opens it.
export type ProviderInputSnapshot = {
  keeper: string
  traceId: string
  absoluteTurn: number
  turnRef: string
  runtimeProfile: string
  capturedAt: number
  wire: ProviderInputWire
  parts: ProviderInputPart[]
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

function decodePart(raw: unknown): ProviderInputPart | null {
  if (!isRecord(raw)) return null
  const index = nonNegativeInteger(raw.index)
  const bytes = nonNegativeInteger(raw.bytes)
  const digest = sha256(raw.sha256)
  if (index === null || bytes === null || digest === null) return null
  if (raw.kind === 'system_prompt') {
    if (!hasExactKeys(raw, ['index', 'kind', 'bytes', 'sha256'])) return null
    return { kind: 'system_prompt', index, bytes, sha256: digest }
  }
  if (raw.kind === 'message') {
    const role = nonEmptyString(raw.role)
    if (!hasExactKeys(raw, ['index', 'kind', 'role', 'bytes', 'sha256']) || role === null) return null
    return { kind: 'message', role, index, bytes, sha256: digest }
  }
  if (raw.kind === 'tool_schema') {
    const name = nonEmptyString(raw.name)
    if (!hasExactKeys(raw, ['index', 'kind', 'name', 'bytes', 'sha256']) || name === null) return null
    return { kind: 'tool_schema', name, index, bytes, sha256: digest }
  }
  return null
}

function decodeParts(raw: unknown): ProviderInputPart[] | null {
  if (!Array.isArray(raw)) return null
  const decoded: ProviderInputPart[] = []
  for (let index = 0; index < raw.length; index += 1) {
    const part = decodePart(raw[index])
    if (part === null || part.index !== index) return null
    decoded.push(part)
  }
  return decoded
}

function samePart(left: ProviderInputPart, right: ProviderInputPart): boolean {
  if (
    left.index !== right.index
    || left.bytes !== right.bytes
    || left.sha256 !== right.sha256
  ) return false
  switch (left.kind) {
    case 'system_prompt':
      return right.kind === 'system_prompt'
    case 'message':
      return right.kind === 'message' && right.role === left.role
    case 'tool_schema':
      return right.kind === 'tool_schema' && right.name === left.name
  }
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
    'parts',
  ])) return null
  const keeper = nonEmptyString(raw.keeper)
  const traceId = nonEmptyString(raw.trace_id)
  const absoluteTurn = nonNegativeInteger(raw.absolute_turn)
  const turnRef = nonEmptyString(raw.turn_ref)
  const runtimeProfile = nonEmptyString(raw.runtime_profile)
  const capturedAt = finiteNonNegative(raw.captured_at)
  const wire = decodeWire(raw.wire)
  const parts = decodeParts(raw.parts)
  if (
    raw.dashboard_surface !== '/api/v1/keepers/:name/provider-input'
    || raw.schema !== 'masc.provider-input-manifest.v1'
    || keeper === null
    || traceId === null
    || absoluteTurn === null
    || turnRef === null
    || turnRef !== `${traceId}#${absoluteTurn}`
    || runtimeProfile === null
    || capturedAt === null
    || wire === null
    || parts === null
  ) return null
  return {
    keeper,
    traceId,
    absoluteTurn,
    turnRef,
    runtimeProfile,
    capturedAt,
    wire,
    parts,
  }
}

// The answer must name the keeper, the turn and the part the list named, and
// carry the byte count the list counted; anything else is another part.
export function decodeProviderInputPart(
  raw: unknown,
  expected: { keeper: string; turnRef: string; part: ProviderInputPart },
): string | null {
  if (!isRecord(raw) || !hasExactKeys(raw, [
    'dashboard_surface',
    'schema',
    'keeper',
    'turn_ref',
    'part',
    'text',
  ])) return null
  const part = decodePart(raw.part)
  if (
    raw.dashboard_surface !== '/api/v1/keepers/:name/provider-input/part'
    || raw.schema !== 'masc.provider-input-part.v1'
    || raw.keeper !== expected.keeper
    || raw.turn_ref !== expected.turnRef
    || part === null
    || !samePart(part, expected.part)
    || typeof raw.text !== 'string'
    || new TextEncoder().encode(raw.text).length !== part.bytes
  ) return null
  return raw.text
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

export async function fetchKeeperProviderInputPart(
  name: string,
  turnRef: string,
  part: ProviderInputPart,
  opts?: AbortableRequestOptions,
): Promise<string> {
  await ensureDevToken()
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/provider-input/part?turn_ref=${encodeURIComponent(turnRef)}&index=${part.index}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const text = decodeProviderInputPart(raw, { keeper: name, turnRef, part })
    if (text === null) throw new Error('유효하지 않은 keeper provider-input part payload')
    return text
  })
}
