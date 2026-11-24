import { apiGetV2, apiMutateV2, type ApiError } from '../core/transport'
import type { Result } from '../lib/result'
import { isRecord, isStringArray } from '../lib/type-guards'

export type ConfigReloadScope = 'hot_reload' | 'next_turn' | 'restart_required'

export interface ConfigFieldSpec {
  readonly table: string
  readonly key: string
  readonly full_key: string
  readonly type: string
  readonly current_value: unknown
  readonly default_value: unknown
  readonly provenance: string
  readonly reload_scope: ConfigReloadScope
  readonly secret: boolean
  readonly writable: boolean
  readonly description: string
  readonly enum_values?: readonly string[]
  readonly label?: string
  readonly entity_group?: string
  readonly entity_title?: string
  readonly sub_group?: string | null
}

export interface ConfigCategorySpec {
  readonly id: string
  readonly title: string
  readonly field_count: number
  readonly fields: readonly ConfigFieldSpec[]
}

export interface ConfigSchemaData {
  readonly target: string
  readonly keeper?: string | null
  readonly file_exists: boolean
  readonly file_sha256: string
  readonly categories: readonly ConfigCategorySpec[]
}

export interface ConfigPatchChange {
  readonly op: 'set' | 'set_string' | 'set_int' | 'set_float' | 'set_bool' | 'set_string_array' | 'remove'
  readonly table: string
  readonly key: string
  readonly full_key?: string
  readonly value?: unknown
}

export interface ConfigPatchResult {
  readonly applied: boolean
  readonly dry_run: boolean
  readonly target: string
  readonly changed: boolean
  readonly before_sha256: string
  readonly new_sha256: string
  readonly snapshot_id: string | null
  readonly snapshot_path?: string
  readonly reload_scope: ConfigReloadScope
  readonly unified_diff: string
  readonly diff_hunks: readonly unknown[]
  readonly validation_warnings: readonly string[]
}

function isReloadScope(value: unknown): value is ConfigReloadScope {
  return value === 'hot_reload' || value === 'next_turn' || value === 'restart_required'
}

function decodeFields(raw: unknown): ConfigFieldSpec[] {
  if (!Array.isArray(raw)) return []
  const fields: ConfigFieldSpec[] = []
  for (const field of raw) {
    if (!isRecord(field) || typeof field.table !== 'string'
        || typeof field.key !== 'string' || !field.key
        || typeof field.full_key !== 'string' || !field.full_key
        || typeof field.type !== 'string' || !field.type
        || !isReloadScope(field.reload_scope)) continue
    fields.push({
      table: field.table,
      key: field.key,
      full_key: field.full_key,
      type: field.type,
      current_value: field.current_value,
      default_value: field.default_value,
      provenance: typeof field.provenance === 'string' ? field.provenance : 'default',
      reload_scope: field.reload_scope,
      secret: field.secret !== false,
      writable: field.writable === true,
      description: typeof field.description === 'string' ? field.description : '',
      enum_values: isStringArray(field.enum_values) ? field.enum_values : undefined,
      label: typeof field.label === 'string' ? field.label : undefined,
      entity_group: typeof field.entity_group === 'string' ? field.entity_group : undefined,
      entity_title: typeof field.entity_title === 'string' ? field.entity_title : undefined,
      sub_group: typeof field.sub_group === 'string' || field.sub_group === null ? field.sub_group : undefined,
    })
  }
  return fields
}

function decodeConfigSchema(raw: unknown): ConfigSchemaData {
  if (!isRecord(raw) || typeof raw.target !== 'string' || !raw.target
      || typeof raw.file_exists !== 'boolean' || typeof raw.file_sha256 !== 'string'
      || !Array.isArray(raw.categories)) {
    throw new Error('Invalid configuration schema')
  }
  const categories: ConfigCategorySpec[] = []
  for (const category of raw.categories) {
    if (!isRecord(category) || typeof category.id !== 'string' || typeof category.title !== 'string') continue
    const fields = decodeFields(category.fields)
    categories.push({ id: category.id, title: category.title, fields, field_count: fields.length })
  }
  return {
    target: raw.target,
    keeper: typeof raw.keeper === 'string' ? raw.keeper : null,
    file_exists: raw.file_exists,
    file_sha256: raw.file_sha256,
    categories,
  }
}

function decodeConfigPatchResult(raw: unknown, dryRun: boolean): ConfigPatchResult {
  const snapshotId = isRecord(raw) && typeof raw.snapshot_id === 'string' ? raw.snapshot_id : null
  if (!isRecord(raw) || raw.applied !== !dryRun || raw.dry_run !== dryRun
      || typeof raw.target !== 'string' || !raw.target || typeof raw.changed !== 'boolean'
      || typeof raw.before_sha256 !== 'string' || !raw.before_sha256
      || typeof raw.new_sha256 !== 'string' || !raw.new_sha256
      || !isReloadScope(raw.reload_scope) || typeof raw.unified_diff !== 'string'
      || (dryRun ? raw.snapshot_id !== null : !snapshotId)) {
    throw new Error('Invalid configuration patch receipt')
  }
  return {
    applied: raw.applied,
    dry_run: raw.dry_run,
    target: raw.target,
    changed: raw.changed,
    before_sha256: raw.before_sha256,
    new_sha256: raw.new_sha256,
    snapshot_id: snapshotId,
    snapshot_path: typeof raw.snapshot_path === 'string' ? raw.snapshot_path : undefined,
    reload_scope: raw.reload_scope,
    unified_diff: raw.unified_diff,
    diff_hunks: Array.isArray(raw.diff_hunks) ? raw.diff_hunks : [],
    validation_warnings: isStringArray(raw.validation_warnings) ? raw.validation_warnings : [],
  }
}

export function fetchConfigSchemaApi(target: string, signal?: AbortSignal): Promise<Result<ConfigSchemaData, ApiError>> {
  return apiGetV2<ConfigSchemaData>(
    '/api/v1/config/schema?target=' + encodeURIComponent(target),
    { decode: decodeConfigSchema, signal },
  )
}

export function postConfigPatchApi(params: {
  readonly target: string
  readonly keeperName?: string
  readonly expectedSha256?: string
  readonly dryRun: boolean
  readonly changes: readonly ConfigPatchChange[]
}): Promise<Result<ConfigPatchResult, ApiError>> {
  return apiMutateV2<ConfigPatchResult>('POST', '/api/v1/config/patch', {
    target: params.target,
    keeper_name: params.keeperName,
    expected_sha256: params.expectedSha256,
    dry_run: params.dryRun,
    changes: params.changes,
  }, { decode: (raw) => decodeConfigPatchResult(raw, params.dryRun) })
}
