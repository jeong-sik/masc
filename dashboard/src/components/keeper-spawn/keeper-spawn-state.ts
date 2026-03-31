import { signal, computed } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { asString, extractArray, isRecord } from '../common/normalize'
import { showToast } from '../common/toast'
import { createAsyncResource, getData } from '../../lib/async-state'

export interface PersonaSummary {
  name: string
  displayName?: string
  role?: string
  mode?: string
  description?: string
}

export function normalizePersonaSummary(raw: unknown): PersonaSummary | null {
  if (!isRecord(raw)) return null

  const name = asString(raw.persona_name) ?? asString(raw.name)
  if (!name) return null

  return {
    name,
    displayName: asString(raw.display_name) ?? asString(raw.displayName) ?? asString(raw.name),
    role: asString(raw.role),
    mode: asString(raw.mode),
    description: asString(raw.description) ?? asString(raw.trait),
  }
}

export function normalizePersonaSummaries(raw: unknown): PersonaSummary[] {
  return extractArray(raw, ['personas'])
    .map(normalizePersonaSummary)
    .filter((persona): persona is PersonaSummary => persona !== null)
}

const personasResource = createAsyncResource<PersonaSummary[]>()

export const personas = computed(() => getData(personasResource.state.value) ?? [])
export const personasLoading = computed(() => personasResource.state.value.status === 'loading')
export const personasError = computed<string | null>(() => {
  const s = personasResource.state.value
  return s.status === 'error' ? s.message : null
})

export async function loadPersonas(): Promise<void> {
  await personasResource.load(async () => {
    const raw = await callMcpTool('masc_persona_list', {})
    return normalizePersonaSummaries(JSON.parse(raw))
  }).catch(() => {
    showToast('페르소나 목록 로드 실패', 'error')
  })
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
