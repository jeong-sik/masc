import { signal } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'

export type FlowState = 'unknown' | 'running' | 'paused'
export const flowState = signal<FlowState>('unknown')
export const flowLoading = signal(false)

export async function fetchPauseStatus(): Promise<void> {
  try {
    const raw = await callMcpTool('masc_pause_status', {})
    const parsed = JSON.parse(raw) as { paused?: boolean; status?: string }
    flowState.value = parsed.paused === true || parsed.status === 'paused' ? 'paused' : 'running'
  } catch { flowState.value = 'unknown' }
}

export async function pauseRoom(): Promise<void> {
  flowLoading.value = true
  try { await callMcpTool('masc_pause', {}); flowState.value = 'paused'; showToast('룸 일시정지', 'success') }
  catch (err) { showToast(`일시정지 실패: ${err instanceof Error ? err.message : String(err)}`, 'error') }
  finally { flowLoading.value = false }
}

export async function resumeRoom(): Promise<void> {
  flowLoading.value = true
  try { await callMcpTool('masc_resume', {}); flowState.value = 'running'; showToast('룸 재개', 'success') }
  catch (err) { showToast(`재개 실패: ${err instanceof Error ? err.message : String(err)}`, 'error') }
  finally { flowLoading.value = false }
}

export async function interruptRoom(reason?: string): Promise<void> {
  flowLoading.value = true
  try {
    const args: Record<string, unknown> = {}
    if (reason) args.reason = reason
    await callMcpTool('masc_interrupt', args)
    showToast('룸 인터럽트 전송', 'success')
    await fetchPauseStatus()
  } catch (err) {
    showToast(`인터럽트 실패: ${err instanceof Error ? err.message : String(err)}`, 'error')
  } finally { flowLoading.value = false }
}
