import { get, NAMESPACE_TRUTH_GET_TIMEOUT_MS } from './core'
import type {
  DashboardNamespaceTruthResponse,
  DashboardShellResponse,
} from '../types'

type AbortableRequestOptions = {
  signal?: AbortSignal
}

type DashboardShellRequestOptions = AbortableRequestOptions & {
  light?: boolean
}

export function fetchDashboardShell(opts?: DashboardShellRequestOptions): Promise<DashboardShellResponse> {
  const qs = opts?.light ? '?light=true' : ''
  return get(`/api/v1/dashboard/shell${qs}`, { signal: opts?.signal })
}

export function fetchDashboardNamespaceTruth(
  opts?: AbortableRequestOptions,
): Promise<DashboardNamespaceTruthResponse> {
  return get('/api/v1/dashboard/project-snapshot', {
    timeoutMs: NAMESPACE_TRUTH_GET_TIMEOUT_MS,
    signal: opts?.signal,
  })
}
