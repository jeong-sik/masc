import { post } from './core'
import { isRecord } from '../lib/type-guards'
export interface Integration { id: string; display_name: string; protocol: string | null; setup_support: string; endpoint?: string; credential_kind?: string }
export interface Source { integration_id: string; endpoint?: string; api_key?: string }
export interface Model { id: string; label: string; context: number | null; tools: boolean | null }
export type Selection = { kind: 'existing'; id: string; label: string } | { kind: 'new'; source: Source; model: Model; label: string }
const positive = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) > 0
export async function discoverSetupModels(source: Source): Promise<Model[]> {
  const response = await post<unknown>('/api/v1/setup/models', source)
  if (!isRecord(response) || !Array.isArray(response.models)) throw new Error('Invalid model inventory')
  const seen = new Set<string>()
  return response.models.map(row => {
    if (!isRecord(row) || typeof row.id !== 'string' || !row.id || seen.has(row.id)) throw new Error('Invalid model identity')
    seen.add(row.id)
    return { id: row.id, label: typeof row.label === 'string' ? row.label : row.id,
      context: positive(row.context) ? row.context : null, tools: typeof row.tools === 'boolean' ? row.tools : null }
  })
}
export async function saveSetupSelections(revision: string, choices: Selection[]): Promise<void> {
  const connections: { source: Source; models: { id: string; context: number; streaming: boolean }[] }[] = []
  const selection = choices.map(choice => {
    if (choice.kind === 'existing') return { runtime_id: choice.id }
    if (!positive(choice.model.context)) throw new Error('Model context is not reported')
    const index = connections.length
    connections.push({ source: choice.source, models: [{ id: choice.model.id, context: choice.model.context, streaming: true }] })
    return { connection: index, model: 0 }
  })
  const response = await post<unknown>('/api/v1/setup/connections', { revision, connections, selection })
  if (!isRecord(response) || response.configured !== true || response.readiness !== 'verified'
    || !Array.isArray(response.runtime_ids) || response.runtime_ids.length === 0 || response.runtime_ids.length > choices.length
    || new Set(response.runtime_ids).size !== response.runtime_ids.length
    || response.runtime_ids.some(id => typeof id !== 'string' || !id)
    || response.runtime_id !== response.runtime_ids[0]) throw new Error('Unconfirmed configuration save')
}

export async function prepareSetupModel(source: Source, model: Model, load: boolean): Promise<Model> {
  const response = await post<unknown>('/api/v1/setup/context', { source, model: model.id, load })
  if (!isRecord(response) || response.model !== model.id || !positive(response.context)) throw new Error('Context not confirmed')
  return { ...model, context: response.context, tools: typeof response.tools === 'boolean' ? response.tools : model.tools }
}
