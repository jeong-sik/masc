// MASC Dashboard — MDAL (Metric-Driven Agent Loop) API client

import { post } from './core'

export interface MdalLoopActionResponse {
  ok: boolean
  action?: 'stop'
  loop_id?: string
  detail?: unknown
  error?: string
}

export function stopMdalLoop(loopId: string): Promise<MdalLoopActionResponse> {
  return post('/api/v1/mdal/loops/stop', { loop_id: loopId })
}
