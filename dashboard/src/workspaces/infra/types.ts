import type { ComponentChildren } from 'preact'

export interface WorkspaceInspectPayload {
  title: string
  subtitle?: string
  kind: string
  data?: unknown
  render?: () => ComponentChildren
}

export interface WorkspaceViewProps {
  subroute: string
  entityId?: string
  entityTab?: string
  onNavigate: (path: string) => void
  onInspect: (payload: WorkspaceInspectPayload) => void
}

export type InfraSubroute = 'sandboxes' | 'repos' | 'logs'

export const INFRA_TABS: readonly { readonly id: InfraSubroute; readonly label: string }[] = [
  { id: 'sandboxes', label: 'Sandboxes' },
  { id: 'repos', label: 'Repos & 24h Changes' },
  { id: 'logs', label: 'Activity & Logs' },
]

export function normalizeInfraSubroute(raw: string): InfraSubroute {
  const cleaned = raw.trim().toLowerCase()
  if (cleaned === 'repos' || cleaned === 'logs') return cleaned
  return 'sandboxes'
}

// ── Wire Types (authoritative OCaml schemas per #36) ──

export type InfraShimParityStatus = 'matched' | 'mismatch' | 'undeclared' | 'unavailable'

export interface InfraShimParity {
  readonly status: InfraShimParityStatus
  readonly build_identity?: string
  readonly shim_identity?: string
  readonly server_identity?: string | null
  readonly detail?: string
}

export interface InfraMicroVmSocketStatus {
  readonly status: 'socket_present' | 'socket_absent' | 'non_socket' | 'unreadable' | string
  readonly exists?: boolean
  readonly path_basename?: string
  readonly file_kind?: string
}

export interface InfraMicroVmGuest {
  readonly id?: string
  readonly name?: string
  readonly guest_name?: string
  readonly keeper?: string
  readonly backend?: string
  readonly presence?: 'present' | 'absent' | 'probe_pending' | 'unavailable' | string
  readonly state?: string
  readonly status?: string
  readonly agent_socket?: InfraMicroVmSocketStatus | null
  readonly socket_present?: boolean
  readonly shim_parity?: InfraShimParity | string | null
  readonly network_mode?: string
  readonly guest_size?: {
    readonly cpus?: number | null
    readonly memory_mib?: number | null
  } | null
  readonly volume?: {
    readonly name?: string | null
    readonly status?: string
    readonly detail?: string
  } | null
  readonly pid?: number | null
  readonly uptime_sec?: number | null
}

export interface InfraSshReachability {
  readonly status: 'probe_pending' | 'reachable' | 'unreachable' | string
  readonly rtt_ms?: number | null
  readonly detail?: string
  readonly measured_at_unix?: number
}

export interface InfraSshPoolAccount {
  readonly unix_user?: string
  readonly active_sessions?: number | null
  readonly max_sessions?: number
  readonly keepers?: readonly string[]
}

export interface InfraSshKeeperSession {
  readonly keeper: string
  readonly last_dispatch?: unknown
  readonly tool_metrics_24h?: unknown
}

export interface InfraSshPool {
  readonly id?: string
  readonly name?: string
  readonly pool_name?: string
  readonly host?: string
  readonly port?: number
  readonly unix_user?: string
  readonly remote_root?: string
  readonly private_home?: boolean
  readonly rtt_ms?: number | null
  readonly reachability?: InfraSshReachability | null
  readonly max_sessions?: number
  readonly active_sessions?: number | null
  readonly keepers?: readonly string[]
  readonly accounts?: readonly InfraSshPoolAccount[]
  readonly keeper_sessions?: readonly InfraSshKeeperSession[]
  readonly status?: string
}

export interface InfraDockerKeeper {
  readonly keeper?: string
  readonly backend?: string
  readonly network_mode?: string
  readonly container_id?: string
  readonly image?: string
  readonly status?: string
}

export interface InfraSandboxesData {
  readonly probe_state: {
    readonly kind: 'fresh' | 'warming' | 'stale' | 'error'
    readonly measured_at_unix: number
    readonly error?: string
  }
  readonly summary: {
    readonly microvm_declared: number
    readonly microvm_running: number
    readonly microvm_sockets_present: number
    readonly microvm_shim_mismatch: number
    readonly ssh_pools: number
    readonly ssh_keepers: number
    readonly ssh_unbound_keepers: number
    readonly ssh_active_sessions: number | null
    readonly ssh_max_sessions: number
    readonly docker_keepers: number
  }
  readonly shim_parity: InfraShimParity
  readonly microvm_guests: readonly InfraMicroVmGuest[]
  readonly ssh_pools: readonly InfraSshPool[]
  readonly ssh_unbound_keepers: readonly unknown[]
  readonly docker_keepers: readonly InfraDockerKeeper[]
  readonly volume_gc_report: Record<string, unknown> | null
  readonly host_storage: Record<string, unknown> | null
  readonly tool_metrics_24h?: unknown
  readonly unobserved_reasons: readonly { readonly scope: string; readonly reason: string }[]
}

export interface InfraRepository {
  readonly id: string
  readonly name: string
  readonly url: string
  readonly codebase?: string | null
  readonly local_path: string
  readonly default_branch: string
  readonly status: string
  readonly auto_sync: boolean
  readonly sync_interval: number
}

export interface RepoActivityChange {
  readonly at: number
  readonly keeper: string
  readonly turn: number | null
  readonly task_id: string | null
  readonly execution_id: string | null
  readonly line_evidence: unknown | null
  readonly location: unknown
  readonly change: unknown
  readonly succeeded: boolean
}

export interface RepoActivityData {
  readonly repo_id: string
  readonly window_hours: number
  readonly incomplete: number
  readonly unattributed: number
  readonly changes: readonly RepoActivityChange[]
}

export type TimelineKind = 'LOG' | 'EVT'
export type TimelineLevel = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR'

export interface TimelineEntry {
  readonly id: string
  readonly kind: TimelineKind
  readonly seq: number | null
  readonly tsUnix: number
  readonly tsDisplay: string
  readonly level: TimelineLevel
  readonly source: string
  readonly module: string
  readonly keeper: string | null
  readonly message: string
  readonly details: Readonly<Record<string, unknown>>
}

export function formatUnixTs(unixSec: number | null | undefined): string {
  if (typeof unixSec !== 'number' || !Number.isFinite(unixSec) || unixSec <= 0) return '없음'
  return new Date(unixSec * 1000).toISOString().replace('T', ' ').slice(5, 19)
}

export function extractChangePath(location: unknown): string {
  if (typeof location === 'string' && location.trim()) return location
  if (location && typeof location === 'object') {
    const rec = location as Record<string, unknown>
    for (const k of ['path', 'relative_path', 'file', 'file_path']) {
      if (typeof rec[k] === 'string' && rec[k]!.trim()) return rec[k]!
    }
  }
  return '(경로 미보고)'
}

export function extractChangeBeforeAfter(change: unknown): { before: string; after: string; unified?: string } {
  if (typeof change === 'string') return { before: '', after: change }
  if (change && typeof change === 'object') {
    const rec = change as Record<string, unknown>
    if (typeof rec.unified_diff === 'string') {
      return { before: '', after: '', unified: rec.unified_diff }
    }
    if (typeof rec.diff === 'string') {
      return { before: '', after: '', unified: rec.diff }
    }
    const before = typeof rec.before === 'string'
      ? rec.before
      : typeof rec.old_text === 'string'
        ? rec.old_text
        : typeof rec.old_string === 'string'
          ? rec.old_string
          : ''
    const after = typeof rec.after === 'string'
      ? rec.after
      : typeof rec.new_text === 'string'
        ? rec.new_text
        : typeof rec.new_string === 'string'
          ? rec.new_string
          : typeof rec.content === 'string'
            ? rec.content
            : JSON.stringify(change, null, 2)
    return { before, after }
  }
  return { before: '', after: '' }
}
