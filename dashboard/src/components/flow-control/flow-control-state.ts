import { signal, effect } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { currentDashboardActor, fetchOperatorSnapshot } from '../../api/core'
import {
  confirmOperatorPendingAction,
  dispatchOperatorAction,
} from '../../operator-actions'
import { namespaceTruth, namespaceTruthInitializing } from '../../namespace-truth-store'
import { serverStatus, shellAuthSummary } from '../../store'
import { showToast } from '../common/toast'
import { isRecord } from '../common/normalize'
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

export async function fetchPauseStatus(): Promise<void> {
  if (syncFlowStateFromDashboardSignals({ trustRunning: false })) return
  try {
    const snapshot: unknown = await fetchOperatorSnapshot()
    const workspace = isRecord(snapshot) && isRecord(snapshot.workspace)
      ? snapshot.workspace
      : null
    if (workspace?.initialized === false) {
      flowState.value = 'initializing'
      return
    }
    if (workspace?.paused === true) {
      flowState.value = 'paused'
      return
    }
    if (workspace?.paused === false) {
      flowState.value = 'running'
      return
    }
    flowState.value = 'unknown'
  } catch (err) {
    flowState.value = 'unknown'
    console.warn('Operator snapshot flow-state refresh failed.', err)
  }
}

function confirmationPreview(preview: unknown): string {
  if (typeof preview === 'string') return preview
  if (preview === undefined) return 'Pause namespace automation?'
  return JSON.stringify(preview, null, 2) ?? String(preview)
}

async function executeNamespaceAction(
  actionType: 'namespace_pause' | 'namespace_resume',
  payload: Record<string, unknown>,
): Promise<boolean> {
  const actor = currentDashboardActor()
  const result = await dispatchOperatorAction({
    actor,
    action_type: actionType,
    target_type: 'workspace',
    payload,
  })
  if (!result.confirm_required) return true

  const confirmToken = result.confirm_token?.trim()
  if (!confirmToken) {
    throw new Error('Operator action requires confirmation but returned no confirm token.')
  }
  const approved = window.confirm(confirmationPreview(result.preview))
  await confirmOperatorPendingAction(actor, confirmToken, approved ? 'confirm' : 'deny')
  return approved
}

export async function pauseWorkspace(): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'admin')
  if (!access.allowed) {
    showToast(access.reason ?? 'Missing permission to pause the namespace.', 'error', 6000)
    return
  }
  flowLoading.value = true
  try {
    const executed = await executeNamespaceAction('namespace_pause', {
      reason: 'Paused from the dashboard flow-control panel.',
    })
    if (!executed) {
      showToast('Namespace pause was denied.', 'warning')
      return
    }
    flowState.value = 'paused'
    showToast('Namespace paused.', 'success')
  } catch (err) {
    showToast(`Pause failed: ${errorToString(err)}`, 'error')
  } finally {
    flowLoading.value = false
  }
}

export async function resumeWorkspace(): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'admin')
  if (!access.allowed) {
    showToast(access.reason ?? 'Missing permission to resume the namespace.', 'error', 6000)
    return
  }
  flowLoading.value = true
  try {
    const executed = await executeNamespaceAction('namespace_resume', {})
    if (!executed) {
      showToast('Namespace resume was denied.', 'warning')
      return
    }
    flowState.value = 'running'
    showToast('Namespace resumed.', 'success')
  } catch (err) {
    showToast(`Resume failed: ${errorToString(err)}`, 'error')
  } finally {
    flowLoading.value = false
  }
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

export async function cleanupZombies(): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? 'Missing permission to clean up zombie agents.', 'error', 6000)
    return
  }
  maintenanceLoading.value = true
  try {
    const raw = await callMcpTool('masc_cleanup_zombies', {})
    maintenanceResult.value = raw
    showToast('Zombie cleanup complete.', 'success')
  } catch (err) {
    showToast(`Zombie cleanup failed: ${errorToString(err)}`, 'error')
  } finally { maintenanceLoading.value = false }
}
