import { signal, effect } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { namespaceTruth, namespaceTruthInitializing } from '../../namespace-truth-store'
import { serverStatus } from '../../store'
import { showToast } from '../common/toast'

type FlowState = 'unknown' | 'initializing' | 'running' | 'paused'
export const flowState = signal<FlowState>('unknown')
export const flowLoading = signal(false)

// Maintenance state
export const maintenanceResult = signal<string | null>(null)
export const maintenanceLoading = signal(false)

function syncFlowStateFromDashboardSignals(): boolean {
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
    flowState.value = 'running'
    return true
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
  if (syncFlowStateFromDashboardSignals()) return
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

export async function pauseRoom(): Promise<void> {
  flowLoading.value = true
  try { await callMcpTool('masc_pause', {}); flowState.value = 'paused'; showToast('프로젝트 일시정지', 'success') }
  catch (err) { showToast(`일시정지 실패: ${err instanceof Error ? err.message : String(err)}`, 'error') }
  finally { flowLoading.value = false }
}

export async function resumeRoom(): Promise<void> {
  flowLoading.value = true
  try { await callMcpTool('masc_resume', {}); flowState.value = 'running'; showToast('프로젝트 재개', 'success') }
  catch (err) { showToast(`재개 실패: ${err instanceof Error ? err.message : String(err)}`, 'error') }
  finally { flowLoading.value = false }
}

// ── Maintenance ─────────────────────────────────

export async function runGarbageCollection(): Promise<void> {
  maintenanceLoading.value = true
  try {
    const raw = await callMcpTool('masc_gc', {})
    maintenanceResult.value = raw
    showToast('GC 완료', 'success')
  } catch (err) {
    showToast(`GC 실패: ${err instanceof Error ? err.message : String(err)}`, 'error')
  } finally { maintenanceLoading.value = false }
}

export async function cleanupZombies(): Promise<void> {
  maintenanceLoading.value = true
  try {
    const raw = await callMcpTool('masc_cleanup_zombies', {})
    maintenanceResult.value = raw
    showToast('좀비 정리 완료', 'success')
  } catch (err) {
    showToast(`좀비 정리 실패: ${err instanceof Error ? err.message : String(err)}`, 'error')
  } finally { maintenanceLoading.value = false }
}
