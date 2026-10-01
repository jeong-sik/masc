import { postControlPlane } from './core'
import { isRecord } from '../lib/type-guards'
export interface Integration { id: string; display_name: string; protocol: string | null; setup_support: string; endpoint?: string; credential_kind?: string }
export interface Source { integration_id: string; endpoint?: string; api_key?: string; account_ref?: string }
export interface Model { id: string; label: string; context: number | null; tools: boolean | null; source?: string
  supported_reasoning_efforts?: string[]; default_reasoning_effort?: string }
export type Selection = { kind: 'existing'; id: string; label: string } | { kind: 'new'; source: Source; model: Model; label: string }
const positive = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) > 0
export async function discoverSetupModels(source: Source, options: { signal?: AbortSignal } = {}): Promise<Model[]> {
  const response = await postControlPlane<unknown>('/api/v1/setup/models', source, undefined, options)
  return parseModels(response)
}
function reasoningEfforts(row: Record<string, unknown>): Pick<Model, 'supported_reasoning_efforts' | 'default_reasoning_effort'> {
  const hasSupported = Object.hasOwn(row, 'supported_reasoning_efforts')
  const hasDefault = Object.hasOwn(row, 'default_reasoning_effort')
  if (!hasSupported && !hasDefault) return {}
  const supported = row.supported_reasoning_efforts
  const defaultEffort = row.default_reasoning_effort
  if (!hasSupported || !hasDefault || !Array.isArray(supported)
    || !supported.every((value): value is string => typeof value === 'string' && value !== '')
    || new Set(supported).size !== supported.length || typeof defaultEffort !== 'string' || defaultEffort === '') {
    throw new Error('Invalid model reasoning effort metadata')
  }
  return { supported_reasoning_efforts: supported, default_reasoning_effort: defaultEffort }
}
function parseModels(response: unknown): Model[] {
  if (!isRecord(response) || !Array.isArray(response.models)) throw new Error('Invalid model inventory')
  const seen = new Set<string>()
  return response.models.map(row => {
    if (!isRecord(row) || typeof row.id !== 'string' || !row.id || seen.has(row.id)) throw new Error('Invalid model identity')
    seen.add(row.id)
    return { id: row.id, label: typeof row.label === 'string' ? row.label : row.id,
      source: typeof response.source === 'string' ? response.source : undefined,
      ...reasoningEfforts(row),
      context: positive(row.context) ? row.context : null, tools: typeof row.tools === 'boolean' ? row.tools : null }
  })
}
export async function selectSetupAccount(integration_id: string, options: { signal?: AbortSignal } = {}): Promise<Source> {
  const response = await postControlPlane<unknown>('/api/v1/setup/accounts/select', { integration_id }, undefined, options)
  if (!isRecord(response) || response.schema !== 'masc.web_setup_account_selection.v1'
    || response.account_selected !== true || response.invocation_verified !== false
    || typeof response.account_ref !== 'string' || !/^[a-f0-9]{64}$/.test(response.account_ref)) throw new Error('Account selection not confirmed')
  return { integration_id, account_ref: response.account_ref }
}
export async function importAntigravityAccount(integration_id: string, options: { signal?: AbortSignal } = {}): Promise<{ source: Source; models: Model[] }> {
  const response = await postControlPlane<unknown>('/api/v1/setup/accounts/antigravity', { integration_id }, undefined, options)
  if (!isRecord(response) || response.schema !== 'masc.web_setup_account.v1'
    || response.account_imported !== true || response.invocation_verified !== false
    || typeof response.account_ref !== 'string' || !/^[a-f0-9]{64}$/.test(response.account_ref)) throw new Error('Account import not confirmed')
  return { source: { integration_id, account_ref: response.account_ref }, models: parseModels(response.catalog) }
}
// A runtime MASC published without a response and tool measurement because
// its provider declined the check for the account's usage (a spent quota or
// a rate limit).
export type Unverified = { runtime_id: string; code: string }
// What a save left unconfirmed. Both lists empty means every selected runtime
// answered a real check in this save. [notRechecked] names selected runtimes
// the save did not call again; it says nothing about whether they ever passed.
export type SaveOutcome = { unverified: Unverified[]; notRechecked: string[] }
function readUnverifiedRows(rows: unknown, runtimeIds: unknown[]): Unverified[] | null {
  if (!Array.isArray(rows)) return null
  const parsed = rows.map(row => isRecord(row) && typeof row.runtime_id === 'string' && runtimeIds.includes(row.runtime_id)
    && typeof row.code === 'string' && row.code ? { runtime_id: row.runtime_id, code: row.code } : null)
  return parsed.every((row): row is Unverified => row !== null) ? parsed : null
}
function readSaveOutcome(response: Record<string, unknown>, runtimeIds: unknown[]): SaveOutcome | null {
  if (response.readiness === 'verified') {
    return response.unverified === undefined && response.not_rechecked === undefined ? { unverified: [], notRechecked: [] } : null
  }
  const unverified = readUnverifiedRows(response.unverified, runtimeIds)
  if (unverified === null) return null
  if (response.readiness === 'usage_limited') {
    return unverified.length > 0 && response.not_rechecked === undefined ? { unverified, notRechecked: [] } : null
  }
  if (response.readiness !== 'partly_checked') return null
  const kept = response.not_rechecked
  if (!Array.isArray(kept) || kept.length === 0 || !kept.every((id): id is string => typeof id === 'string' && runtimeIds.includes(id))) return null
  return { unverified, notRechecked: kept }
}
export async function saveSetupSelections(revision: string, choices: Selection[], options: { signal?: AbortSignal } = {}): Promise<SaveOutcome> {
  const connections: { source: Source; models: { id: string; context: number; streaming: boolean }[] }[] = []
  const selection = choices.map(choice => {
    if (choice.kind === 'existing') return { runtime_id: choice.id }
    if (!positive(choice.model.context)) throw new Error('Model context is not reported')
    const index = connections.length
    connections.push({ source: choice.source, models: [{ id: choice.model.id, context: choice.model.context, streaming: true }] })
    return { connection: index, model: 0 }
  })
  const response = await postControlPlane<unknown>('/api/v1/setup/connections', { revision, connections, selection }, undefined, options)
  if (!isRecord(response) || response.configured !== true
    || !Array.isArray(response.runtime_ids) || response.runtime_ids.length === 0 || response.runtime_ids.length > choices.length
    || new Set(response.runtime_ids).size !== response.runtime_ids.length
    || response.runtime_ids.some(id => typeof id !== 'string' || !id)
    || response.runtime_id !== response.runtime_ids[0]) throw new Error('Unconfirmed configuration save')
  const outcome = readSaveOutcome(response, response.runtime_ids)
  if (outcome === null) throw new Error('Unconfirmed configuration save')
  return outcome
}

export async function prepareSetupModel(source: Source, model: Model, load: boolean, options: { signal?: AbortSignal } = {}): Promise<Model> {
  const response = await postControlPlane<unknown>('/api/v1/setup/context', { source, model: model.id, load }, undefined, options)
  if (!isRecord(response) || response.model !== model.id || !positive(response.context)) throw new Error('Context not confirmed')
  return { ...model, context: response.context, tools: typeof response.tools === 'boolean' ? response.tools : model.tools }
}
