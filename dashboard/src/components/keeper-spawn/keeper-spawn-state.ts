import { signal } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'

export interface PersonaSummary {
  name: string
  role?: string
  mode?: string
  description?: string
}

export const personas = signal<PersonaSummary[]>([])
export const personasLoading = signal(false)
export const personasError = signal<string | null>(null)

export async function loadPersonas(): Promise<void> {
  if (personasLoading.value) return
  personasLoading.value = true
  personasError.value = null
  try {
    const raw = await callMcpTool('masc_persona_list', {})
    const parsed = JSON.parse(raw) as { personas?: PersonaSummary[] } | PersonaSummary[]
    const list = Array.isArray(parsed) ? parsed : (parsed.personas ?? [])
    personas.value = list
  } catch (err) {
    personasError.value = err instanceof Error ? err.message : String(err)
    showToast('페르소나 목록 로드 실패', 'error')
  } finally {
    personasLoading.value = false
  }
}

export const spawning = signal(false)
export const spawnResult = signal<{ success: boolean; message: string } | null>(null)
export const showSpawnPanel = signal(false)

export async function spawnKeeperFromPersona(personaName: string, opts?: { dryRun?: boolean; roomScope?: string }): Promise<void> {
  spawning.value = true
  spawnResult.value = null
  try {
    const args: Record<string, unknown> = { persona_name: personaName }
    if (opts?.dryRun) args.dry_run = true
    if (opts?.roomScope) args.room_scope = opts.roomScope
    const result = await callMcpTool('masc_keeper_create_from_persona', args)
    spawnResult.value = { success: true, message: result }
    if (!opts?.dryRun) showToast(`${personaName} 키퍼 생성 완료`, 'success')
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    spawnResult.value = { success: false, message }
    showToast(`키퍼 생성 실패: ${message}`, 'error')
  } finally {
    spawning.value = false
  }
}

export async function shutdownKeeper(keeperName: string): Promise<void> {
  try {
    await callMcpTool('masc_keeper_down', { name: keeperName })
    showToast(`${keeperName} 키퍼 종료 완료`, 'success')
  } catch (err) {
    showToast(`키퍼 종료 실패: ${err instanceof Error ? err.message : String(err)}`, 'error')
  }
}
