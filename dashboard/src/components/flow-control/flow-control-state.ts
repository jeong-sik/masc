import { signal, computed, effect } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { namespaceTruth, namespaceTruthInitializing } from '../../namespace-truth-store'
import { serverStatus } from '../../store'
import { showToast } from '../common/toast'
import { createAsyncResource, getData } from '../../lib/async-state'

export type FlowState = 'unknown' | 'initializing' | 'running' | 'paused'
export const flowState = signal<FlowState>('unknown')
export const flowLoading = signal(false)

// Room strategy resource
const roomStrategyResource = createAsyncResource<Record<string, unknown>>()
const roomStrategyMutating = signal(false)
export const roomStrategy = computed(() => getData(roomStrategyResource.state.value) ?? null)
export const roomStrategyLoading = computed(() =>
  roomStrategyMutating.value || roomStrategyResource.state.value.status === 'loading',
)

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

export async function fetchPauseStatus(): Promise<void> {
  if (syncFlowStateFromDashboardSignals()) return
  try {
    const raw = await callMcpTool('masc_pause_status', {})
    const parsed = JSON.parse(raw) as { paused?: boolean | null; status?: string; initializing?: boolean }
    if (parsed.paused === true || parsed.status === 'paused') {
      flowState.value = 'paused'
      return
    }
    if (parsed.initializing === true || parsed.status === 'initializing') {
      flowState.value = 'initializing'
      return
    }
    flowState.value = 'running'
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


// ── Room Strategy ───────────────────────────────

export async function fetchRoomStrategy(): Promise<void> {
  await roomStrategyResource.load(async () => {
    const raw = await callMcpTool('masc_room_strategy_get', {})
    return JSON.parse(raw) as Record<string, unknown>
  }).catch(() => {
    showToast('프로젝트 전략 조회 실패', 'error')
  })
}

export async function setRoomStrategy(updates: Record<string, unknown>): Promise<void> {
  roomStrategyMutating.value = true
  try {
    await callMcpTool('masc_room_strategy_set', updates)
    showToast('프로젝트 전략 업데이트 완료', 'success')
    await fetchRoomStrategy()
  } catch (err) {
    showToast(`프로젝트 전략 저장 실패: ${err instanceof Error ? err.message : String(err)}`, 'error')
  } finally {
    roomStrategyMutating.value = false
  }
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
