import { signal, computed } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { createAsyncResource, getData } from '../../lib/async-state'
import { refreshExecution, shellAuthSummary } from '../../store'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'
import {
  parsePersonaListResponse,
  type PersonaSummary,
} from '../../api/schemas/persona'

export type { PersonaSummary } from '../../api/schemas/persona'

export const personasResource = createAsyncResource<readonly PersonaSummary[]>()

export const personas = computed(() => getData(personasResource.state.value) ?? [])
export const personasLoading = computed(() => personasResource.state.value.status === 'loading')
export const personasError = computed<string | null>(() => {
  const s = personasResource.state.value
  return s.status === 'error' ? s.message : null
})

export async function loadPersonas(): Promise<void> {
  await personasResource.load(async () => {
    const raw = await callMcpTool('masc_persona_list', { detailed: true })
    return parsePersonaListResponse(JSON.parse(raw)).personas
  })
}

export const spawning = signal(false)
export const spawnResult = signal<{ success: boolean; message: string } | null>(null)
export const showSpawnPanel = signal(false)

function formatKeeperSpawnError(message: string): string {
  const forbiddenMatch = message.match(/Forbidden:\s+([^\s]+)\s+cannot\s+masc_keeper_create_from_persona/i)
  if (!forbiddenMatch) return message

  const actor = forbiddenMatch[1]
  return `${actor} 세션은 현재 키퍼 생성 권한이 없습니다. 이 프로젝트의 auth가 읽기 전용(default_role=reader)으로 열려 있거나 reader 토큰을 사용 중일 때 생기는 오류입니다. worker/admin Bearer token을 설정하거나 프로젝트 기본 권한을 올린 뒤 다시 시도하세요.`
}

export async function spawnKeeperFromPersona(personaName: string, opts?: { dryRun?: boolean }): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    const message = access.reason ?? '키퍼 생성 권한이 없습니다.'
    spawnResult.value = { success: false, message }
    showToast(message, 'error', 6000)
    return
  }
  spawning.value = true
  spawnResult.value = null
  try {
    const args: Record<string, unknown> = { persona_name: personaName }
    if (opts?.dryRun) args.dry_run = true
    const result = await callMcpTool('masc_keeper_create_from_persona', args)
    spawnResult.value = { success: true, message: result }
    if (!opts?.dryRun) {
      showToast(`${personaName} 키퍼 생성 완료`, 'success')
      void refreshExecution({ force: true })
    }
  } catch (err) {
    const message = formatKeeperSpawnError(errorToString(err))
    spawnResult.value = { success: false, message }
    showToast(`키퍼 생성 실패: ${message}`, 'error')
  } finally {
    spawning.value = false
  }
}

// ---------------------------------------------------------------------------
// Persona create/edit/delete state.
//
// A persona profile.json has two layers the backend loaders read from
// distinct locations:
//   - identity (top level): display_name -> "name", role, trait;
//   - keeper-template defaults (nested "keeper" object): instructions,
//     mention_targets, proactive_enabled — the defaults a keeper spawned from
//     this persona inherits.
// masc_persona_create / masc_persona_update take these fields (see
// keeper_schema.ml) and write them to the correct layer. We forward exactly
// those fields. The old
// `mode`/`description` form fields did not exist in the schema and were
// silently dropped upstream; they are gone.
// ---------------------------------------------------------------------------

export interface PersonaFields {
  persona_name: string
  display_name?: string
  role?: string
  trait?: string
  instructions?: string
  mention_targets?: string[]
  proactive_enabled?: boolean
}

// Shared field projection. A field is forwarded only when the caller set it,
// so update keeps partial-merge semantics (unset field -> unchanged on disk).
function personaArgs(fields: Omit<PersonaFields, 'persona_name'>): Record<string, unknown> {
  const args: Record<string, unknown> = {}
  if (fields.display_name !== undefined) args.display_name = fields.display_name
  if (fields.role !== undefined) args.role = fields.role
  if (fields.trait !== undefined) args.trait = fields.trait
  if (fields.instructions !== undefined) args.instructions = fields.instructions
  if (fields.mention_targets !== undefined && fields.mention_targets.length > 0) {
    args.mention_targets = fields.mention_targets
  }
  if (fields.proactive_enabled !== undefined) args.proactive_enabled = fields.proactive_enabled
  return args
}

export const showCreateForm = signal(false)
export const editingPersona = signal<PersonaSummary | null>(null)

export async function createPersona(fields: PersonaFields): Promise<boolean> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? '페르소나 생성 권한이 없습니다.', 'error')
    return false
  }
  const { persona_name, ...rest } = fields
  const args: Record<string, unknown> = { persona_name, ...personaArgs(rest) }
  try {
    await callMcpTool('masc_persona_create', args)
    showToast(`${persona_name} 페르소나 생성 완료`, 'success')
    void loadPersonas()
    return true
  } catch (err) {
    showToast(`페르소나 생성 실패: ${errorToString(err)}`, 'error')
    return false
  }
}

export async function updatePersona(
  name: string,
  patch: Omit<PersonaFields, 'persona_name'>,
): Promise<boolean> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? '페르소나 수정 권한이 없습니다.', 'error')
    return false
  }
  const args: Record<string, unknown> = { persona_name: name, ...personaArgs(patch) }
  try {
    await callMcpTool('masc_persona_update', args)
    showToast(`${name} 페르소나 수정 완료`, 'success')
    void loadPersonas()
    return true
  } catch (err) {
    showToast(`페르소나 수정 실패: ${errorToString(err)}`, 'error')
    return false
  }
}

export async function deletePersona(name: string): Promise<boolean> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? '페르소나 삭제 권한이 없습니다.', 'error')
    return false
  }
  try {
    await callMcpTool('masc_persona_delete', { persona_name: name })
    showToast(`${name} 페르소나 삭제 완료`, 'success')
    void loadPersonas()
    return true
  } catch (err) {
    showToast(`페르소나 삭제 실패: ${errorToString(err)}`, 'error')
    return false
  }
}
