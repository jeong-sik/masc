import { signal, effect } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { currentDashboardActor, get } from '../../api/core'
import { dispatchOperatorAction, confirmOperatorPendingAction } from '../../operator-store'
import {
  namespaceTruth, namespaceTruthInitializing, namespaceTruthError, refreshNamespaceTruth,
} from '../../namespace-truth-store'
import { serverStatus, shellAuthSummary } from '../../store'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'
import { isRecord } from '../common/normalize'

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

// Once a direct read has established authority, dashboard projections only
// trigger a new authoritative read; their stale status cannot overwrite it.
let hasDirectReadback = false
let pauseReadSequence = 0

effect(() => {
  void namespaceTruth.value
  void namespaceTruthInitializing.value
  void namespaceTruthError.value
  void serverStatus.value
  if (hasDirectReadback) {
    void revalidateWorkspacePause()
  } else {
    syncFlowStateFromDashboardSignals()
  }
})

async function readWorkspacePause(): Promise<boolean> {
  const sequence = ++pauseReadSequence
  try {
    const observed = await get<unknown>('/api/v1/operator/pause-status')
    if (!isRecord(observed) || observed.ok !== true || observed.initializing !== false
      || typeof observed.paused !== 'boolean') {
      throw new Error('Namespace pause readback is unavailable.')
    }
    if (sequence === pauseReadSequence) {
      hasDirectReadback = true
      flowState.value = observed.paused ? 'paused' : 'running'
    }
    return observed.paused
  } catch (error) {
    if (sequence === pauseReadSequence) flowState.value = 'unknown'
    throw error
  }
}

async function revalidateWorkspacePause(): Promise<void> {
  try { await readWorkspacePause() } catch { /* The current read withdraws its own state. */ }
}

export async function fetchPauseStatus(): Promise<void> {
  if (hasDirectReadback) {
    await revalidateWorkspacePause()
    return
  }
  if (syncFlowStateFromDashboardSignals()) {
    if (flowState.value !== 'running') return
    // A healthy SSE stream does not refresh Workspace pause authority.
    await revalidateWorkspacePause()
    return
  }
  await refreshNamespaceTruth({ force: true })
  syncFlowStateFromDashboardSignals()
  if (flowState.value === 'running') await revalidateWorkspacePause()
}

async function changeNamespacePause(paused: boolean): Promise<void> {
  if (flowLoading.value) return
  const verb = paused ? 'Pause' : 'Resume'
  const access = dashboardAuthAccess(shellAuthSummary.value, 'admin')
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
    }, { refresh: 'background' })
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
      await confirmOperatorPendingAction(actor, result.confirm_token, confirmed ? 'confirm' : 'deny', { refresh: 'background' })
      if (!confirmed) return
    }
    // Project snapshots refresh asynchronously. Read the current Workspace
    // pause state after confirmation rather than treating that projection as
    // acknowledgement of this action.
    flowState.value = 'unknown'
    const observedPaused = await readWorkspacePause()
    // Updating the broader projection is independent of this direct readback.
    void refreshNamespaceTruth({ force: true })
    if (observedPaused === paused) {
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
