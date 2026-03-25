import {
  fetchChainRun,
  fetchChainSummary,
  fetchCommandPlaneHelp,
  fetchCommandPlaneOrchestra,
  fetchCommandPlaneSnapshot,
  fetchCommandPlaneSummary,
  fetchCommandPlaneSwarm,
  runCommandPlaneAction,
} from './api'
import type { CommandPlaneSurface } from './types'
import { registerCommandPlaneRefresh } from './sse-store'
import {
  normalizeSnapshot,
  normalizeSummarySnapshot,
  normalizeChainSummary,
  normalizeChainRunResponse,
  normalizeHelp,
  normalizeSwarm,
  normalizeOrchestra,
} from './command-normalizers-swarm'
import {
  commandPlaneSummary,
  commandPlaneSnapshot,
  commandPlaneLoading,
  commandPlaneDetailLoading,
  commandPlaneError,
  commandPlaneDetailError,
  commandPlaneActionBusy,
  commandPlaneActionError,
  commandPlaneSurface,
  commandPlaneHelp,
  commandPlaneHelpLoading,
  commandPlaneHelpError,
  commandPlaneSwarm,
  commandPlaneSwarmLoading,
  commandPlaneSwarmError,
  commandPlaneOrchestra,
  commandPlaneOrchestraLoading,
  commandPlaneOrchestraError,
  commandPlaneChainSummary,
  commandPlaneChainLoading,
  commandPlaneChainError,
  commandPlaneChainRun,
  commandPlaneChainRunLoading,
  commandPlaneChainRunError,
  commandPlaneChainFocusOperationId,
} from './command-signals'

let activeChainRunRequestId: string | null = null

interface RefreshOptions {
  force?: boolean
}

const COMMAND_REFRESH_TTL_MS = 1_000
const COMMAND_HELP_TTL_MS = 60_000

let summaryRefreshInflight: Promise<void> | null = null
let detailRefreshInflight: Promise<void> | null = null
let helpRefreshInflight: Promise<void> | null = null
let chainRefreshInflight: Promise<void> | null = null
let swarmRefreshInflight: Promise<void> | null = null
let orchestraRefreshInflight: Promise<void> | null = null

let lastSummaryRefreshAt = 0
let lastDetailRefreshAt = 0
let lastHelpRefreshAt = 0
let lastChainRefreshAt = 0
let lastSwarmRefreshAt = 0
let lastOrchestraRefreshAt = 0
let lastSwarmRefreshKey = ''
let lastOrchestraRefreshKey = ''

function surfaceNeedsDetail(surface: CommandPlaneSurface): boolean {
  return surface !== 'swarm' && surface !== 'orchestra'
}

function isFresh(lastAt: number, ttlMs: number, opts?: RefreshOptions): boolean {
  return !opts?.force && Date.now() - lastAt < ttlMs
}

function refreshKey(runId?: string, operationId?: string): string {
  return `${runId ?? ''}:${operationId ?? ''}`
}

function currentLocationParams(): URLSearchParams {
  if (typeof window === 'undefined') return new URLSearchParams()
  const search = new URLSearchParams(window.location.search)
  const hash = window.location.hash.replace(/^#/, '')
  const queryIdx = hash.indexOf('?')
  if (queryIdx >= 0) {
    const hashSearch = new URLSearchParams(hash.slice(queryIdx + 1))
    hashSearch.forEach((value, key) => {
      if (!search.has(key)) search.set(key, value)
    })
  }
  return search
}

function currentSwarmRunId(): string | undefined {
  const params = currentLocationParams()
  const value = params.get('run_id') ?? undefined
  return value && value.trim() !== '' ? value.trim() : undefined
}

function currentSwarmOperationId(): string | undefined {
  const params = currentLocationParams()
  const value = params.get('operation_id') ?? undefined
  return value && value.trim() !== '' ? value.trim() : undefined
}

export function setCommandPlaneSurface(surface: CommandPlaneSurface): void {
  commandPlaneSurface.value = surface
  if (surfaceNeedsDetail(surface)) {
    void ensureCommandPlaneDetail()
  }
}

export async function refreshCommandPlaneSummary(opts?: RefreshOptions): Promise<void> {
  if (summaryRefreshInflight) return summaryRefreshInflight
  if (isFresh(lastSummaryRefreshAt, COMMAND_REFRESH_TTL_MS, opts)) return
  commandPlaneLoading.value = true
  commandPlaneError.value = null
  summaryRefreshInflight = (async () => {
    try {
      const raw = await fetchCommandPlaneSummary()
      commandPlaneSummary.value = normalizeSummarySnapshot(raw)
      lastSummaryRefreshAt = Date.now()
    } catch (err) {
      commandPlaneError.value =
        err instanceof Error ? err.message : 'Failed to load command-plane summary'
    } finally {
      commandPlaneLoading.value = false
      summaryRefreshInflight = null
    }
  })()
  return summaryRefreshInflight
}

export function focusCommandPlaneChainOperation(operationId: string | null): void {
  commandPlaneChainFocusOperationId.value = operationId
}

export async function refreshCommandPlaneSnapshot(opts?: RefreshOptions): Promise<void> {
  if (detailRefreshInflight) return detailRefreshInflight
  if (isFresh(lastDetailRefreshAt, COMMAND_REFRESH_TTL_MS, opts)) return
  commandPlaneDetailLoading.value = true
  commandPlaneDetailError.value = null
  detailRefreshInflight = (async () => {
    try {
      const raw = await fetchCommandPlaneSnapshot()
      commandPlaneSnapshot.value = normalizeSnapshot(raw)
      lastDetailRefreshAt = Date.now()
    } catch (err) {
      commandPlaneDetailError.value =
        err instanceof Error ? err.message : 'Failed to load command-plane snapshot'
    } finally {
      commandPlaneDetailLoading.value = false
      detailRefreshInflight = null
    }
  })()
  return detailRefreshInflight
}

export async function ensureCommandPlaneDetail(): Promise<void> {
  if (commandPlaneSnapshot.value || commandPlaneDetailLoading.value) return
  await refreshCommandPlaneSnapshot()
}

export async function refreshCommandPlaneCurrentSurface(opts?: RefreshOptions): Promise<void> {
  await refreshCommandPlaneSummary(opts)
  if (surfaceNeedsDetail(commandPlaneSurface.value)) {
    await refreshCommandPlaneSnapshot(opts)
  }
}

export async function refreshCommandPlaneChainSummary(opts?: RefreshOptions): Promise<void> {
  if (chainRefreshInflight) return chainRefreshInflight
  if (isFresh(lastChainRefreshAt, COMMAND_REFRESH_TTL_MS, opts)) return
  commandPlaneChainLoading.value = true
  commandPlaneChainError.value = null
  chainRefreshInflight = (async () => {
    try {
      const raw = await fetchChainSummary()
      const normalized = normalizeChainSummary(raw)
      commandPlaneChainSummary.value = normalized
      const focused = commandPlaneChainFocusOperationId.value
      if (normalized.operations.length === 0) {
        commandPlaneChainFocusOperationId.value = null
      } else if (!focused || !normalized.operations.some(item => item.operation.operation_id === focused)) {
        commandPlaneChainFocusOperationId.value = normalized.operations[0]?.operation.operation_id ?? null
      }
      lastChainRefreshAt = Date.now()
    } catch (err) {
      commandPlaneChainError.value =
        err instanceof Error ? err.message : 'Failed to load chain summary'
    } finally {
      commandPlaneChainLoading.value = false
      chainRefreshInflight = null
    }
  })()
  return chainRefreshInflight
}

export function clearCommandPlaneChainRun(): void {
  activeChainRunRequestId = null
  commandPlaneChainRun.value = null
  commandPlaneChainRunLoading.value = false
  commandPlaneChainRunError.value = null
}

export async function loadCommandPlaneChainRun(runId: string): Promise<void> {
  activeChainRunRequestId = runId
  commandPlaneChainRunLoading.value = true
  commandPlaneChainRunError.value = null
  try {
    const raw = await fetchChainRun(runId)
    if (activeChainRunRequestId !== runId) return
    commandPlaneChainRun.value = normalizeChainRunResponse(raw)
  } catch (err) {
    if (activeChainRunRequestId !== runId) return
    commandPlaneChainRun.value = null
    commandPlaneChainRunError.value =
      err instanceof Error ? err.message : 'Failed to load chain run'
  } finally {
    if (activeChainRunRequestId === runId) {
      commandPlaneChainRunLoading.value = false
    }
  }
}

export async function refreshCommandPlaneHelp(opts?: RefreshOptions): Promise<void> {
  if (helpRefreshInflight) return helpRefreshInflight
  if (isFresh(lastHelpRefreshAt, COMMAND_HELP_TTL_MS, opts)) return
  commandPlaneHelpLoading.value = true
  commandPlaneHelpError.value = null
  helpRefreshInflight = (async () => {
    try {
      const raw = await fetchCommandPlaneHelp()
      commandPlaneHelp.value = normalizeHelp(raw)
      lastHelpRefreshAt = Date.now()
    } catch (err) {
      commandPlaneHelpError.value =
        err instanceof Error ? err.message : 'Failed to load command-plane help'
    } finally {
      commandPlaneHelpLoading.value = false
      helpRefreshInflight = null
    }
  })()
  return helpRefreshInflight
}

export async function refreshCommandPlaneSwarm(
  runId = currentSwarmRunId(),
  operationId = currentSwarmOperationId(),
  opts?: RefreshOptions,
): Promise<void> {
  const key = refreshKey(runId, operationId)
  if (swarmRefreshInflight && key === lastSwarmRefreshKey) return swarmRefreshInflight
  if (key === lastSwarmRefreshKey && isFresh(lastSwarmRefreshAt, COMMAND_REFRESH_TTL_MS, opts)) return
  commandPlaneSwarmLoading.value = true
  commandPlaneSwarmError.value = null
  lastSwarmRefreshKey = key
  swarmRefreshInflight = (async () => {
    try {
      const raw = await fetchCommandPlaneSwarm(runId, operationId)
      commandPlaneSwarm.value = normalizeSwarm(raw)
      lastSwarmRefreshAt = Date.now()
    } catch (err) {
      commandPlaneSwarmError.value =
        err instanceof Error ? err.message : 'Failed to load command-plane swarm view'
    } finally {
      commandPlaneSwarmLoading.value = false
      swarmRefreshInflight = null
    }
  })()
  return swarmRefreshInflight
}

export async function refreshCommandPlaneOrchestra(
  runId = currentSwarmRunId(),
  operationId = currentSwarmOperationId(),
  opts?: RefreshOptions,
): Promise<void> {
  const key = refreshKey(runId, operationId)
  if (orchestraRefreshInflight && key === lastOrchestraRefreshKey) return orchestraRefreshInflight
  if (key === lastOrchestraRefreshKey && isFresh(lastOrchestraRefreshAt, COMMAND_REFRESH_TTL_MS, opts)) return
  commandPlaneOrchestraLoading.value = true
  commandPlaneOrchestraError.value = null
  lastOrchestraRefreshKey = key
  orchestraRefreshInflight = (async () => {
    try {
      const raw = await fetchCommandPlaneOrchestra(runId, operationId)
      commandPlaneOrchestra.value = normalizeOrchestra(raw)
      lastOrchestraRefreshAt = Date.now()
    } catch (err) {
      commandPlaneOrchestraError.value =
        err instanceof Error ? err.message : 'Failed to load orchestra map'
    } finally {
      commandPlaneOrchestraLoading.value = false
      orchestraRefreshInflight = null
    }
  })()
  return orchestraRefreshInflight
}

async function runAction(key: string, path: string, body: Record<string, unknown>): Promise<void> {
  commandPlaneActionBusy.value = key
  commandPlaneActionError.value = null
  try {
    await runCommandPlaneAction(path, body)
    await refreshCommandPlaneSummary({ force: true })
    if (commandPlaneSnapshot.value || surfaceNeedsDetail(commandPlaneSurface.value)) {
      await refreshCommandPlaneSnapshot({ force: true })
    }
    await refreshCommandPlaneSwarm(undefined, undefined, { force: true })
    await refreshCommandPlaneOrchestra(undefined, undefined, { force: true })
    await refreshCommandPlaneChainSummary({ force: true })
  } catch (err) {
    commandPlaneActionError.value =
      err instanceof Error ? err.message : 'Failed to execute command-plane action'
    throw err
  } finally {
    commandPlaneActionBusy.value = null
  }
}

export function pauseCommandPlaneOperation(operationId: string): Promise<void> {
  return runAction(`pause:${operationId}`, '/api/v1/command-plane/operations/pause', {
    operation_id: operationId,
  })
}

export function resumeCommandPlaneOperation(operationId: string): Promise<void> {
  return runAction(`resume:${operationId}`, '/api/v1/command-plane/operations/resume', {
    operation_id: operationId,
  })
}

export function recallCommandPlaneOperation(operationId: string): Promise<void> {
  return runAction(`recall:${operationId}`, '/api/v1/command-plane/dispatch/recall', {
    operation_id: operationId,
  })
}

export function runCommandPlaneDispatchTick(
  filters: { operationId?: string; detachmentId?: string } = {},
): Promise<void> {
  return runAction('dispatch:tick', '/api/v1/command-plane/dispatch/tick', {
    ...(filters.operationId ? { operation_id: filters.operationId } : {}),
    ...(filters.detachmentId ? { detachment_id: filters.detachmentId } : {}),
  })
}

export function approveCommandPlaneDecision(decisionId: string): Promise<void> {
  return runAction(`approve:${decisionId}`, '/api/v1/command-plane/policy/approve', {
    decision_id: decisionId,
  })
}

export function denyCommandPlaneDecision(decisionId: string): Promise<void> {
  return runAction(`deny:${decisionId}`, '/api/v1/command-plane/policy/deny', {
    decision_id: decisionId,
  })
}

export function toggleCommandPlaneFreeze(unitId: string, enabled: boolean): Promise<void> {
  return runAction(`freeze:${unitId}`, '/api/v1/command-plane/policy/freeze', {
    unit_id: unitId,
    enabled,
  })
}

export function toggleCommandPlaneKillSwitch(unitId: string, enabled: boolean): Promise<void> {
  return runAction(`kill:${unitId}`, '/api/v1/command-plane/policy/kill-switch', {
    unit_id: unitId,
    enabled,
  })
}

registerCommandPlaneRefresh(() => {
  void refreshCommandPlaneCurrentSurface({ force: true })
  void refreshCommandPlaneChainSummary({ force: true })
  if (
    commandPlaneSurface.value === 'swarm'
    || commandPlaneSurface.value === 'orchestra'
    || commandPlaneSwarm.value !== null
  ) {
    void refreshCommandPlaneSwarm(undefined, undefined, { force: true })
  }
  if (commandPlaneSurface.value === 'orchestra' || commandPlaneOrchestra.value !== null) {
    void refreshCommandPlaneOrchestra(undefined, undefined, { force: true })
  }
})
