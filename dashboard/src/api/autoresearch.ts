// MASC Dashboard — Autoresearch API client
// Fetches loop list and detail from dedicated HTTP endpoints.
//
// Response shapes are defined by `src/api/schemas/autoresearch.ts` and
// every response is validated through `v.parse` at the boundary.
// Shape drift from the backend raises `AutoresearchSchemaDriftError`,
// never `undefined` access downstream.

import { get, post } from './core'
import {
  parseAutoresearchLoopActionResponse,
  parseAutoresearchLoopDetail,
  parseAutoresearchLoopsResponse,
  type AutoresearchCycleRecord,
  type AutoresearchLoopActionResponse,
  type AutoresearchLoopDetail,
  type AutoresearchLoopsResponse,
  type AutoresearchLoopSummary,
} from './schemas/autoresearch'

export type {
  AutoresearchCycleRecord,
  AutoresearchLoopActionResponse,
  AutoresearchLoopDetail,
  AutoresearchLoopsResponse,
  AutoresearchLoopSummary,
}
export { AutoresearchSchemaDriftError } from './schemas/autoresearch'

export interface StartAutoresearchLoopParams {
  goal: string
  metric_fn: string
  target_file: string
  workdir?: string
  max_cycles?: number
  cycle_timeout_s?: number
  model_model?: string
  baseline?: number
  patience?: number
  build_verify_fn?: string
}

export async function fetchAutoresearchLoops(offset = 0, limit = 100): Promise<AutoresearchLoopsResponse> {
  const url = `/api/v1/autoresearch/loops?offset=${offset}&limit=${limit}`
  const raw = await get<unknown>(url)
  return parseAutoresearchLoopsResponse(raw)
}

export async function fetchAutoresearchLoopDetail(
  loopId: string,
  historyLimit = 100,
): Promise<AutoresearchLoopDetail> {
  const url = `/api/v1/autoresearch/loops/${encodeURIComponent(loopId)}?history_limit=${historyLimit}`
  const raw = await get<unknown>(url)
  return parseAutoresearchLoopDetail(raw)
}

export async function retryAutoresearchLoop(loopId: string): Promise<AutoresearchLoopActionResponse> {
  const raw = await post<unknown>('/api/v1/autoresearch/loops/retry', { loop_id: loopId })
  return parseAutoresearchLoopActionResponse(raw)
}

export async function deleteAutoresearchLoop(loopId: string): Promise<AutoresearchLoopActionResponse> {
  const raw = await post<unknown>('/api/v1/autoresearch/loops/delete', { loop_id: loopId })
  return parseAutoresearchLoopActionResponse(raw)
}

export async function startAutoresearchLoop(
  params: StartAutoresearchLoopParams,
): Promise<AutoresearchLoopActionResponse> {
  const raw = await post<unknown>('/api/v1/autoresearch/loops/start', params)
  return parseAutoresearchLoopActionResponse(raw)
}
