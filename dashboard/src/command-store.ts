import { signal } from '@preact/signals'
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
import type {
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
  CommandPlaneHelpResponse,
  CommandPlaneOrchestraResponse,
  CommandPlaneSnapshot,
  CommandPlaneSummarySnapshot,
  CommandPlaneSwarmResponse,
  CommandPlaneSurface,
} from './types'
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

export * from './command-normalizers'
export * from './command-normalizers-swarm'

export const commandPlaneSummary = signal<CommandPlaneSummarySnapshot | null>(null)
export const commandPlaneSnapshot = signal<CommandPlaneSnapshot | null>(null)
export const commandPlaneLoading = signal(false)
export const commandPlaneDetailLoading = signal(false)
export const commandPlaneError = signal<string | null>(null)
export const commandPlaneDetailError = signal<string | null>(null)
export const commandPlaneActionBusy = signal<string | null>(null)
export const commandPlaneActionError = signal<string | null>(null)
export const commandPlaneSurface = signal<CommandPlaneSurface>('operations')
export const commandPlaneHelp = signal<CommandPlaneHelpResponse | null>(null)
export const commandPlaneHelpLoading = signal(false)
export const commandPlaneHelpError = signal<string | null>(null)
export const commandPlaneSwarm = signal<CommandPlaneSwarmResponse | null>(null)
export const commandPlaneSwarmLoading = signal(false)
export const commandPlaneSwarmError = signal<string | null>(null)
export const commandPlaneOrchestra = signal<CommandPlaneOrchestraResponse | null>(null)
export const commandPlaneOrchestraLoading = signal(false)
export const commandPlaneOrchestraError = signal<string | null>(null)
export const commandPlaneChainSummary = signal<CommandPlaneChainSummary | null>(null)
export const commandPlaneChainLoading = signal(false)
export const commandPlaneChainError = signal<string | null>(null)
export const commandPlaneChainRun = signal<CommandPlaneChainRunResponse | null>(null)
export const commandPlaneChainRunLoading = signal(false)
export const commandPlaneChainRunError = signal<string | null>(null)
export const commandPlaneChainFocusOperationId = signal<string | null>(null)
let activeChainRunRequestId: string | null = null

function surfaceNeedsDetail(surface: CommandPlaneSurface): boolean {
  return surface !== 'swarm' && surface !== 'orchestra'
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

export async function refreshCommandPlaneSummary(): Promise<void> {
  commandPlaneLoading.value = true
  commandPlaneError.value = null
  try {
    const raw = await fetchCommandPlaneSummary()
    commandPlaneSummary.value = normalizeSummarySnapshot(raw)
  } catch (err) {
    commandPlaneError.value =
      err instanceof Error ? err.message : 'Failed to load command-plane summary'
  } finally {
    commandPlaneLoading.value = false
  }
}

export function focusCommandPlaneChainOperation(operationId: string | null): void {
  commandPlaneChainFocusOperationId.value = operationId
}

export async function refreshCommandPlaneSnapshot(): Promise<void> {
  commandPlaneDetailLoading.value = true
  commandPlaneDetailError.value = null
  try {
    const raw = await fetchCommandPlaneSnapshot()
    commandPlaneSnapshot.value = normalizeSnapshot(raw)
  } catch (err) {
    commandPlaneDetailError.value =
      err instanceof Error ? err.message : 'Failed to load command-plane snapshot'
  } finally {
    commandPlaneDetailLoading.value = false
  }
}

export async function ensureCommandPlaneDetail(): Promise<void> {
  if (commandPlaneSnapshot.value || commandPlaneDetailLoading.value) return
  await refreshCommandPlaneSnapshot()
}

export async function refreshCommandPlaneCurrentSurface(): Promise<void> {
  await refreshCommandPlaneSummary()
  if (surfaceNeedsDetail(commandPlaneSurface.value)) {
    await refreshCommandPlaneSnapshot()
  }
}

export async function refreshCommandPlaneChainSummary(): Promise<void> {
  commandPlaneChainLoading.value = true
  commandPlaneChainError.value = null
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
  } catch (err) {
    commandPlaneChainError.value =
      err instanceof Error ? err.message : 'Failed to load chain summary'
  } finally {
    commandPlaneChainLoading.value = false
  }
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

export async function refreshCommandPlaneHelp(): Promise<void> {
  commandPlaneHelpLoading.value = true
  commandPlaneHelpError.value = null
  try {
    const raw = await fetchCommandPlaneHelp()
    commandPlaneHelp.value = normalizeHelp(raw)
  } catch (err) {
    commandPlaneHelpError.value =
      err instanceof Error ? err.message : 'Failed to load command-plane help'
  } finally {
    commandPlaneHelpLoading.value = false
  }
}

export async function refreshCommandPlaneSwarm(
  runId = currentSwarmRunId(),
  operationId = currentSwarmOperationId(),
): Promise<void> {
  commandPlaneSwarmLoading.value = true
  commandPlaneSwarmError.value = null
  try {
    const raw = await fetchCommandPlaneSwarm(runId, operationId)
    commandPlaneSwarm.value = normalizeSwarm(raw)
  } catch (err) {
    commandPlaneSwarmError.value =
      err instanceof Error ? err.message : 'Failed to load command-plane swarm view'
  } finally {
    commandPlaneSwarmLoading.value = false
  }
}

export async function refreshCommandPlaneOrchestra(
  runId = currentSwarmRunId(),
  operationId = currentSwarmOperationId(),
): Promise<void> {
  commandPlaneOrchestraLoading.value = true
  commandPlaneOrchestraError.value = null
  try {
    const raw = await fetchCommandPlaneOrchestra(runId, operationId)
    commandPlaneOrchestra.value = normalizeOrchestra(raw)
  } catch (err) {
    commandPlaneOrchestraError.value =
      err instanceof Error ? err.message : 'Failed to load orchestra map'
  } finally {
    commandPlaneOrchestraLoading.value = false
  }
}

async function runAction(key: string, path: string, body: Record<string, unknown>): Promise<void> {
  commandPlaneActionBusy.value = key
  commandPlaneActionError.value = null
  try {
    await runCommandPlaneAction(path, body)
    await refreshCommandPlaneSummary()
    if (commandPlaneSnapshot.value || surfaceNeedsDetail(commandPlaneSurface.value)) {
      await refreshCommandPlaneSnapshot()
    }
    await refreshCommandPlaneSwarm()
    await refreshCommandPlaneOrchestra()
    await refreshCommandPlaneChainSummary()
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
  void refreshCommandPlaneCurrentSurface()
  void refreshCommandPlaneChainSummary()
  if (
    commandPlaneSurface.value === 'swarm'
    || commandPlaneSurface.value === 'orchestra'
    || commandPlaneSwarm.value !== null
  ) {
    void refreshCommandPlaneSwarm()
  }
  if (commandPlaneSurface.value === 'orchestra' || commandPlaneOrchestra.value !== null) {
    void refreshCommandPlaneOrchestra()
  }
})
