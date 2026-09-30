import { signal, effect } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { currentDashboardActor } from '../../api/core'
import { dispatchOperatorAction, confirmOperatorPendingAction } from '../../operator-store'
import {
  namespaceTruth, namespaceTruthInitializing, namespaceTruthError, refreshNamespaceTruth,
} from '../../namespace-truth-store'
import { serverStatus, shellAuthSummary } from '../../store'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'

type FlowState = 'unknown' | 'initializing' | 'running' | 'paused'
export const flowState = signal<FlowState>('unknown')
export const flowLoading = signal(false)

// Maintenance state
export const maintenanceResult = signal<string | null>(null)
export const maintenanceLoading = signal(false)

export function syncFlowStateFromDashboardSignals(): boolean {
  if (namespaceTruthError.value) {
    flowState.value = 'unknown'
    return false
  }
  if (namespaceTruthInitializing.value) {
    flowState.value = 'initializing'
    return true
  }

  const paused = namespaceTruth.value?.root.status?.paused ?? serverStatus.value?.paused
  if (typeof paused === 'boolean') {
    flowState.value = paused ? 'paused' : 'running'
    return true
  }
  flowState.value = 'unknown'
  return false
}

effect(() => {
  syncFlowStateFromDashboardSignals()
})

export async function fetchPauseStatus(): Promise<void> {
  if (syncFlowStateFromDashboardSignals()) return
  await refreshNamespaceTruth({ force: true })
  syncFlowStateFromDashboardSignals()
}

async function changeNamespacePause(paused: boolean): Promise<void> {
  if (flowLoading.value) return
  const verb = paused ? 'Pause' : 'Resume'
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? `Missing permission to ${verb.toLowerCase()} the namespace.`, 'error', 6000)
    return
  }
  flowLoading.value = true
  try {
    const actor = currentDashboardActor()
    const result = await dispatchOperatorAction({
      actor,
      action_type: paused ? 'namespace_pause' : 'namespace_resume',
      target_type: 'workspace',
      payload: {},
    })
    if (result.confirm_required) {
      if (!result.confirm_token) throw new Error('Server did not return a confirmation token.')
      const confirmed = await requestConfirm({
        title: `${verb} namespace`,
        message: paused
          ? 'Pause namespace automation and spawning until resumed?'
          : 'Resume namespace automation and spawning?',
        confirmText: verb,
        tone: paused ? 'danger' : 'info',
      })
      await confirmOperatorPendingAction(actor, result.confirm_token, confirmed ? 'confirm' : 'deny')
      if (!confirmed) return
    }
    await refreshNamespaceTruth({ force: true })
    syncFlowStateFromDashboardSignals()
    const expected: FlowState = paused ? 'paused' : 'running'
    if (flowState.value === expected) {
      showToast(paused ? 'Namespace paused.' : 'Namespace resumed.', 'success')
    } else {
      showToast(`${verb} sent; namespace state is ${flowState.value}.`, 'warning')
    }
  } catch (err) {
    showToast(`${verb} failed: ${errorToString(err)}`, 'error')
  } finally {
    flowLoading.value = false
  }
}

export async function pauseWorkspace(): Promise<void> {
  await changeNamespacePause(true)
}

export async function resumeWorkspace(): Promise<void> {
  await changeNamespacePause(false)
}

// ── Maintenance ─────────────────────────────────

export async function runGarbageCollection(): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'admin')
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
