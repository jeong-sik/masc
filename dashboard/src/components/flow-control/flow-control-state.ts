import { signal } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { shellAuthSummary } from '../../store'
import { showToast } from '../common/toast'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'

// Maintenance state
export const maintenanceResult = signal<string | null>(null)
export const maintenanceLoading = signal(false)

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
