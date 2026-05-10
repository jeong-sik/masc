import { get, post, fetchWithTimeout, type GetOptions } from './core'
import {
  parseIdeAnnotations,
  parseIdeCodeRegions,
  type IdeAnnotation,
  type IdeCodeRegion,
  type AnnotationKind,
} from './schemas/ide-annotations'

export type { IdeAnnotation, IdeCodeRegion, AnnotationKind } from './schemas/ide-annotations'

export interface IdeApiOptions extends GetOptions {
  readonly keeper?: string
}

export interface IdeAnnotationFilter {
  readonly file_path?: string
  readonly keeper_id?: string
  readonly goal_id?: string
  readonly task_id?: string
}

export interface CreateAnnotationInput {
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly kind: AnnotationKind
  readonly content: string
  readonly goal_id?: string
  readonly task_id?: string
  readonly task_id?: string
}

function appendFilterParams(
  params: URLSearchParams,
  filter: IdeAnnotationFilter,
): void {
  if (filter.file_path) params.set('file_path', filter.file_path)
  if (filter.keeper_id) params.set('keeper_id', filter.keeper_id)
  if (filter.goal_id) params.set('goal_id', filter.goal_id)
  if (filter.task_id) params.set('task_id', filter.task_id)
}

function appendWorkspaceParams(
  params: URLSearchParams,
  opts: IdeApiOptions,
): void {
  if (opts.keeper) params.set('keeper', opts.keeper)
}

export async function fetchIdeAnnotations(
  filter: IdeAnnotationFilter = {},
  opts: IdeApiOptions = {},
): Promise<ReadonlyArray<IdeAnnotation>> {
  const params = new URLSearchParams()
  appendFilterParams(params, filter)
  appendWorkspaceParams(params, opts)
  const query = params.size > 0 ? `?${params.toString()}` : ''
  const raw = await get<unknown>(`/api/v1/ide/annotations${query}`, opts)
  if (!isRecord(raw) || raw.ok !== true) return []
  return parseIdeAnnotations(raw.data)
}

export async function createIdeAnnotation(
  input: CreateAnnotationInput,
  _opts: IdeApiOptions = {},
): Promise<IdeAnnotation | null> {
  const raw = await post<unknown>('/api/v1/ide/annotations', input)
  if (!isRecord(raw) || raw.ok !== true) return null
  return parseIdeAnnotations([raw.data])[0] ?? null
}

export async function deleteIdeAnnotation(
  id: string,
  keeperId: string,
  opts: IdeApiOptions = {},
): Promise<boolean> {
  const params = new URLSearchParams()
  params.set('keeper_id', keeperId)
  appendWorkspaceParams(params, opts)
  const path = `/api/v1/ide/annotations/${encodeURIComponent(id)}?${params.toString()}`
  try {
    const res = await fetchWithTimeout(path, { method: 'DELETE' }, 15_000)
    return res.ok
  } catch {
    return false
  }
}

export async function fetchIdeRegions(
  filePath: string,
  opts: IdeApiOptions = {},
): Promise<ReadonlyArray<IdeCodeRegion>> {
  const params = new URLSearchParams()
  params.set('file_path', filePath)
  appendWorkspaceParams(params, opts)
  const raw = await get<unknown>(`/api/v1/ide/regions?${params.toString()}`, opts)
  if (!isRecord(raw) || raw.ok !== true) return []
  return parseIdeCodeRegions(raw.data)
}

export async function fetchIdePresence(
  opts: IdeApiOptions = {},
): Promise<unknown> {
  const params = new URLSearchParams()
  appendWorkspaceParams(params, opts)
  const raw = await get<unknown>(`/api/v1/ide/presence?${params.toString()}`, opts)
  if (!isRecord(raw) || raw.ok !== true) return null
  return raw.data
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
