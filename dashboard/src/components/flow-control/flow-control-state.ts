import { signal, effect } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { namespaceTruth, namespaceTruthInitializing } from '../../namespace-truth-store'
import { serverStatus, shellAuthSummary } from '../../store'
import { showToast } from '../common/toast'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'

type FlowState = 'unknown' | 'initializing' | 'running' | 'paused'
export const flowState = signal<FlowState>('unknown')
export const flowLoading = signal(false)

// Maintenance state
export const maintenanceResult = signal<string | null>(null)
export const maintenanceLoading = signal(false)

export function syncFlowStateFromDashboardSignals(options: { trustRunning: boolean } = { trustRunning: true }): boolean {
  if (namespaceTruthInitializing.value) {
    flowState.value = 'initializing'
    return true
  }

  const paused = namespaceTruth.value?.root.status?.paused ?? serverStatus.value?.paused
  if (paused === true) {
    flowState.value = 'paused'
    return true
  }
  if (paused === false) {
    if (options.trustRunning) {
      flowState.value = 'running'
      return true
    }
    return false
  }
  return false
}

effect(() => {
  syncFlowStateFromDashboardSignals()
})

function normalizedFlowStatus(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

export async function fetchPauseStatus(): Promise<void> {
  if (syncFlowStateFromDashboardSignals({ trustRunning: false })) return
  try {
    const raw = await callMcpTool('masc_pause_status', {})
    const parsed = JSON.parse(raw) as { paused?: boolean | null; status?: string; initializing?: boolean }
    const status = normalizedFlowStatus(parsed.status)
    if (parsed.paused === true || status === 'paused') {
      flowState.value = 'paused'
      return
    }
    if (parsed.initializing === true || status === 'initializing') {
      flowState.value = 'initializing'
      return
    }
    if (parsed.paused === false || status === 'running') {
      flowState.value = 'running'
      return
    }
    flowState.value = 'unknown'
  } catch { flowState.value = 'unknown' }
}

export async function pauseWorkspace(): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? 'Missing permission to pause the namespace.', 'error', 6000)
    return
  }
  flowLoading.value = true
  try { await callMcpTool('masc_pause', {}); flowState.value = 'paused'; showToast('Namespace paused.', 'success') }
  catch (err) { showToast(`Pause failed: ${errorToString(err)}`, 'error') }
  finally { flowLoading.value = false }
}

export async function resumeWorkspace(): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? 'Missing permission to resume the namespace.', 'error', 6000)
    return
  }
  flowLoading.value = true
  try { await callMcpTool('masc_resume', {}); flowState.value = 'running'; showToast('Namespace resumed.', 'success') }
  catch (err) { showToast(`Resume failed: ${errorToString(err)}`, 'error') }
  finally { flowLoading.value = false }
}

// ── Maintenance ─────────────────────────────────

export async function runGarbageCollection(): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? 'Missing permission to run GC.', 'error', 6000)
    return
  }
  maintenanceLoading.value = true
  try {
    const raw = await callMcpTool('masc_gc', {})
    maintenanceResult.value = raw
    showToast('GC complete.', 'success')
  } catch (err) {
    showToast(`GC failed: ${errorToString(err)}`, 'error')
  } finally { maintenanceLoading.value = false }
}
