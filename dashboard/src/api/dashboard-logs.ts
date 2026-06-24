// MASC Dashboard — System logs / provider logs / dashboard config fetchers.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get } from './core'
import { ensureDevToken } from './dev-token'
import { parseDashboardConfigResponse, type DashboardConfigResponse } from './schemas/dashboard-config'
import { parseLogsResponse, type LogsResponse } from './schemas/logs'
import {
  parseProviderLogTailResponse,
  parseProviderLogsCatalogResponse,
  type ProviderLogsCatalogResponse,
  type ProviderLogTailResponse,
} from './schemas/provider-logs'

export async function fetchLogs(opts?: {
  limit?: number
  level?: string
  module?: string
  since_seq?: number
  before_seq?: number
  category?: string
  exclude_category?: string
}): Promise<LogsResponse> {
  const params = new URLSearchParams()
  if (opts?.limit) params.set('limit', String(opts.limit))
  if (opts?.level) params.set('level', opts.level)
  if (opts?.module) params.set('module', opts.module)
  if (typeof opts?.since_seq === 'number' && opts.since_seq >= 0) {
    params.set('since_seq', String(opts.since_seq))
  }
  if (typeof opts?.before_seq === 'number' && opts.before_seq >= 0) {
    params.set('before_seq', String(opts.before_seq))
  }
  if (opts?.category) params.set('category', opts.category)
  if (opts?.exclude_category) params.set('exclude_category', opts.exclude_category)
  const qs = params.toString()
  const raw = await get<unknown>(`/api/v1/dashboard/logs${qs ? `?${qs}` : ''}`)
  return parseLogsResponse(raw)
}

export async function fetchProviderLogsCatalog(): Promise<ProviderLogsCatalogResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/provider-logs')
  return parseProviderLogsCatalogResponse(raw)
}

export async function fetchProviderLogTail(
  provider: string,
  opts?: { lines?: number },
): Promise<ProviderLogTailResponse> {
  const params = new URLSearchParams()
  params.set('provider', provider)
  if (opts?.lines) params.set('lines', String(opts.lines))
  const raw = await get<unknown>(`/api/v1/dashboard/provider-logs/tail?${params.toString()}`)
  return parseProviderLogTailResponse(raw)
}

export async function fetchDashboardConfig(): Promise<DashboardConfigResponse> {
  await ensureDevToken()
  return get<unknown>('/api/v1/dashboard/config').then(parseDashboardConfigResponse)
}

/** Parse runtime context-ratio thresholds from the dashboard config response.
    Falls back to the compiled defaults when keys are missing or malformed. */
export function parseContextThresholds(
  data: DashboardConfigResponse,
  defaults: { critical: number; warn: number; compacting: number },
): { critical: number; warn: number; compacting: number } {
  const cat = data.categories.dashboard ?? []
  const find = (env: string): number | null => {
    const entry = cat.find(e => e.env === env)
    if (!entry || entry.value == null) return null
    const n = parseFloat(entry.value)
    return Number.isFinite(n) ? n : null
  }
  return {
    critical: find('MASC_DASHBOARD_CTX_HANDOFF_IMMINENT') ?? defaults.critical,
    warn: find('MASC_DASHBOARD_CTX_PREPARING') ?? defaults.warn,
    compacting: find('MASC_DASHBOARD_CTX_COMPACTING') ?? defaults.compacting,
  }
}
