// MASC Dashboard — MDAL (Metric-Driven Agent Loop) API client

import { post } from './core'

export interface MdalLoopActionResponse {
  ok: boolean
  action?: 'start' | 'stop'
  loop_id?: string
  detail?: unknown
  error?: string
}

export interface StartMdalLoopParams {
  profile: string
  metric_fn: string
  goal?: string
  target?: string
  reference?: string
  max_iterations?: number
}

export function startMdalLoop(params: StartMdalLoopParams): Promise<MdalLoopActionResponse> {
  return post('/api/v1/mdal/loops/start', params)
}

export function stopMdalLoop(loopId: string): Promise<MdalLoopActionResponse> {
  return post('/api/v1/mdal/loops/stop', { loop_id: loopId })
}
