import { Schema } from 'effect'
import { ApiRequestError, get, postControlPlane } from './core'
import { errorToString } from '../lib/format-string'

const strings = Schema.Array(Schema.String)
const manifest = Schema.Struct({
  schema_version: Schema.Literal(1), name: Schema.String, description: Schema.String,
  created_at: Schema.String, override_count: Schema.Int, override_keys: strings,
  keepers: strings, assignment_count: Schema.Int, lane_count: Schema.Int,
})
const preservedSettings = Schema.Array(Schema.Struct({
  lane: Schema.String, setting: Schema.Literal('max_output_tokens', 'thinking'),
}))
const skippedLanes = Schema.Array(Schema.Struct({ lane: Schema.String, reason: Schema.String }))
const skippedAssignments = Schema.Array(Schema.Struct({ keeper: Schema.String, reason: Schema.String }))
const defaults = Schema.Struct({
  status: Schema.Literal('unknown', 'matches', 'differs'),
  changes: Schema.Array(Schema.Struct({
    key: Schema.String, saved_sha256: Schema.NullOr(Schema.String), current_sha256: Schema.NullOr(Schema.String),
  })),
})
const listing = Schema.Struct({
  ok: Schema.Literal(true), presets: Schema.Array(manifest),
  unreadable: Schema.Array(Schema.Struct({ name: Schema.String, reason: Schema.String })),
})
const part = Schema.Struct({
  effect: Schema.Literal('immediate', 'keeper_restart'), applied: strings,
  skipped: Schema.Array(Schema.Struct({ key: Schema.String, reason: Schema.String })),
})
const registry = Schema.Union(
  Schema.Struct({ status: Schema.Literal('applied'), requires_restart: Schema.Literal(false), targets: Schema.Literal('runtime_bindings', 'replacement_catalog') }),
  Schema.Struct({ status: Schema.Literal('unpublished'), requires_restart: Schema.Literal(true) }),
  Schema.Struct({ status: Schema.Literal('kept'), requires_restart: Schema.Literal(false), next_boot_publishes: Schema.Literal(false), reason: Schema.String }),
)
const sha256 = Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/))
const commitOrder = Schema.String.pipe(Schema.filter(value => /^[1-9][0-9]*$/.test(value)
  && BigInt(value) <= 9223372036854775807n, { message: () => 'Expected positive decimal int64 commit order' }))
const commitFields = { source_revision: sha256, order: commitOrder,
  warnings: Schema.Array(Schema.Struct({ code: Schema.Literal('runtime_config_lock_release_unconfirmed'), detail: Schema.NonEmptyString })) }
const commitReceipt = Schema.Union(
  Schema.Struct({ ...commitFields, durability: Schema.Literal('durable'), durability_detail: Schema.Null }),
  Schema.Struct({ ...commitFields, durability: Schema.Literal('unconfirmed'), durability_detail: Schema.NonEmptyString }),
)
const runtime = Schema.Union(
  Schema.Struct({ effect: Schema.Literal('runtime_commit'), status: Schema.Literal('unchanged') }),
  Schema.Struct({ effect: Schema.Literal('runtime_commit'), status: Schema.Literal('failed'), error: Schema.String }),
  Schema.Struct({
    effect: Schema.Literal('runtime_commit'), status: Schema.Literal('committed'),
    commit: commitReceipt,
    exact_output_registry: registry,
  }),
)
const report = Schema.Struct({
  restored: Schema.String, autosave: Schema.String, prompt_overrides: part, instructions: part,
  runtime, default_prompts: defaults, preserved_lane_settings: Schema.optional(preservedSettings),
  skipped_lanes: Schema.optional(skippedLanes),
  skipped_assignments: Schema.optional(skippedAssignments),
})
const detail = Schema.Struct({
  ok: Schema.Literal(true), directory: Schema.String,
  saved_settings: Schema.Union(
    Schema.Struct({ status: Schema.Literal('matches', 'differs') }),
    Schema.Struct({ status: Schema.Literal('unavailable'), reason: Schema.String }),
  ),
  default_prompts: defaults,
  preset: Schema.Struct({
    name: Schema.String, description: Schema.String, created_at: Schema.String,
    prompt_overrides: Schema.Array(Schema.Struct({ key: Schema.String, bytes: Schema.Int })),
    instructions: Schema.Array(Schema.Struct({ keeper_file: Schema.String, bytes: Schema.Int })),
    assignments: Schema.Array(Schema.Struct({ keeper: Schema.String, runtime: Schema.String })),
    lanes: Schema.Array(Schema.Struct({ id: Schema.String, available: Schema.optional(Schema.Boolean) })),
    preserved_lane_settings: Schema.optional(preservedSettings),
    skipped_lanes: Schema.optional(skippedLanes),
  }),
})

export type PromptPresetManifest = Schema.Schema.Type<typeof manifest>
export type PromptPresetListing = Schema.Schema.Type<typeof listing>
export type PromptPresetDetail = Schema.Schema.Type<typeof detail>
export type PromptPresetReport = Schema.Schema.Type<typeof report>
export type PreservedLaneSettings = Schema.Schema.Type<typeof preservedSettings>
export type PromptPresetWrite<T> =
  | { kind: 'confirmed'; value: T }
  | { kind: 'refused'; detail: string }
  | { kind: 'unconfirmed'; detail: string }

export const parsePromptPresetListing = Schema.decodeUnknownSync(listing)
export const parsePromptPresetDetail = Schema.decodeUnknownSync(detail)
const decodeRuntimeReceipt = Schema.decodeUnknownSync(runtime, { onExcessProperty: 'error' })
const decodeReport = Schema.decodeUnknownSync(report)
export function parsePromptPresetReport(value: unknown): PromptPresetReport {
  // Runtime variants are receipts: discarding a commit from an "unchanged"
  // packet would erase observed effects. Other read projections remain additive.
  if (typeof value !== 'object' || value === null || !('runtime' in value)) throw new Error('Missing runtime receipt')
  decodeRuntimeReceipt(value.runtime)
  return decodeReport(value)
}

export function fetchPromptPresets(): Promise<PromptPresetListing> {
  return get<unknown>('/api/v1/presets').then(parsePromptPresetListing)
}

export function fetchPromptPresetDetail(name: string): Promise<PromptPresetDetail> {
  return get<unknown>(`/api/v1/presets/show?name=${encodeURIComponent(name)}`).then(parsePromptPresetDetail)
}

export interface PromptPresetRequestOptions { beforeDispatch?: () => void }

async function write<T>(path: string, body: unknown, decode: (value: unknown) => T, options: PromptPresetRequestOptions): Promise<PromptPresetWrite<T>> {
  try { options.beforeDispatch?.() }
  catch (error) { return { kind: 'refused', detail: errorToString(error) } }
  try {
    const raw = await postControlPlane<unknown>(path, body)
    if (typeof raw === 'object' && raw !== null && 'ok' in raw && raw.ok === false
      && 'error' in raw && typeof raw.error === 'string') {
      return { kind: 'refused', detail: raw.error }
    }
    return { kind: 'confirmed', value: decode(raw) }
  } catch (error) {
    // A transport/body/receipt failure can follow a committed write. Only an
    // explicit client/auth refusal proves this request did not apply.
    const refused = error instanceof ApiRequestError
      && error.status !== undefined && error.status >= 400 && error.status < 500
    return { kind: refused ? 'refused' : 'unconfirmed', detail: errorToString(error) }
  }
}

export function savePromptPreset(name: string, description: string, options: PromptPresetRequestOptions = {}): Promise<PromptPresetWrite<PromptPresetManifest>> {
  const decode = Schema.decodeUnknownSync(Schema.Struct({ ok: Schema.Literal(true), preset: manifest }))
  return write('/api/v1/presets/create', { name, description }, value => {
    const saved = decode(value).preset
    if (saved.name !== name) throw new Error('저장 요청과 응답의 이름이 일치하지 않습니다.')
    return saved
  }, options)
}

export function restorePromptPreset(name: string, options: PromptPresetRequestOptions = {}): Promise<PromptPresetWrite<PromptPresetReport>> {
  const decode = Schema.decodeUnknownSync(Schema.Struct({ ok: Schema.Literal(true), report: Schema.Unknown }))
  return write('/api/v1/presets/restore', { name }, value => {
    const restored = parsePromptPresetReport(decode(value).report)
    if (restored.restored !== name) throw new Error('복원 요청과 응답의 이름이 일치하지 않습니다.')
    return restored
  }, options)
}

export function promptPresetReportNeedsAttention(value: PromptPresetReport): boolean {
  if (value.prompt_overrides.skipped.length || value.instructions.skipped.length || value.skipped_lanes?.length || value.skipped_assignments?.length) return true
  switch (value.runtime.status) {
    case 'failed': return true
    case 'unchanged': return false
    case 'committed': return value.runtime.commit.durability !== 'durable'
      || value.runtime.commit.warnings.length > 0 || value.runtime.exact_output_registry.status !== 'applied'
  }
}
