import { signal, computed } from '@preact/signals'
import { callMcpTool } from '../../api/mcp'
import { asBoolean, asString, asStringArray, extractArray, isRecord } from '../common/normalize'
import { showToast } from '../common/toast'
import { createAsyncResource, getData } from '../../lib/async-state'
import { shellAuthSummary } from '../../store'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'

export interface PersonaSummary {
  name: string
  displayName?: string
  role?: string
  mode?: string
  description?: string
}

export interface PersonaFieldCatalogEntry {
  path: string
  type?: string
  required?: boolean
  defaultValue?: unknown
  choices?: unknown
  effect?: string
}

export interface PersonaSchema {
  personasRoot?: string
  profilePathPattern?: string
  handleRules?: string
  fieldCatalog: PersonaFieldCatalogEntry[]
  archetypeAxes: Array<{ name: string; choices: string[]; effect?: string }>
}

export interface PersonaFieldExplanation {
  path: string
  value?: unknown
  effect?: string
}

export interface PersonaDraft {
  handle: string
  profile: Record<string, unknown>
  fieldExplanations: PersonaFieldExplanation[]
  rawModel?: string
}

export interface PersonaSaveResult {
  handle: string
  personasRoot?: string
  profilePath?: string
  saved: boolean
  dryRun: boolean
  profile?: Record<string, unknown>
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

function parseToolJson(raw: string): unknown {
  try {
    return JSON.parse(raw)
  } catch {
    return raw
  }
}

function normalizeFieldCatalogEntry(raw: unknown): PersonaFieldCatalogEntry | null {
  if (!isRecord(raw)) return null
  const path = asString(raw.path)
  if (!path) return null
  return {
    path,
    type: asString(raw.type),
    required: asBoolean(raw.required),
    defaultValue: raw.default,
    choices: raw.choices,
    effect: asString(raw.effect),
  }
}

export function normalizePersonaSchema(raw: unknown): PersonaSchema {
  if (!isRecord(raw)) {
    return { fieldCatalog: [], archetypeAxes: [] }
  }
  const axes = extractArray(raw, ['archetype_axes']).flatMap(axis => {
    if (!isRecord(axis)) return []
    const name = asString(axis.name)
    if (!name) return []
    return [{ name, choices: asStringArray(axis.choices), effect: asString(axis.effect) }]
  })
  return {
    personasRoot: asString(raw.personas_root),
    profilePathPattern: asString(raw.profile_path_pattern),
    handleRules: asString(raw.handle_rules),
    fieldCatalog: extractArray(raw, ['field_catalog'])
      .map(normalizeFieldCatalogEntry)
      .filter((entry): entry is PersonaFieldCatalogEntry => entry !== null),
    archetypeAxes: axes,
  }
}

function normalizePersonaFieldExplanation(raw: unknown): PersonaFieldExplanation | null {
  if (!isRecord(raw)) return null
  const path = asString(raw.path)
  if (!path) return null
  return {
    path,
    value: raw.value,
    effect: asString(raw.effect),
  }
}

export function normalizePersonaDraft(raw: unknown): PersonaDraft | null {
  if (!isRecord(raw)) return null
  const handle = asString(raw.handle)
  const profile = raw.profile
  if (!handle || !isRecord(profile)) return null
  return {
    handle,
    profile,
    fieldExplanations: extractArray(raw, ['field_explanations'])
      .map(normalizePersonaFieldExplanation)
      .filter((entry): entry is PersonaFieldExplanation => entry !== null),
    rawModel: asString(raw.raw_model),
  }
}

export function normalizePersonaSaveResult(raw: unknown): PersonaSaveResult | null {
  if (!isRecord(raw)) return null
  const handle = asString(raw.handle)
  if (!handle) return null
  return {
    handle,
    personasRoot: asString(raw.personas_root),
    profilePath: asString(raw.profile_path),
    saved: asBoolean(raw.saved, false),
    dryRun: asBoolean(raw.dry_run, false),
    profile: isRecord(raw.profile) ? raw.profile : undefined,
  }
}

const personasResource = createAsyncResource<PersonaSummary[]>()
const personaSchemaResource = createAsyncResource<PersonaSchema>()

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

export async function loadPersonaSchema(): Promise<void> {
  await personaSchemaResource.load(async () => {
    const raw = await callMcpTool('masc_persona_schema', {})
    return normalizePersonaSchema(parseToolJson(raw))
  }).catch(() => {
    showToast('페르소나 스키마 로드 실패', 'error')
  })
}

export const spawning = signal(false)
export const spawnResult = signal<{ success: boolean; message: string } | null>(null)
export const showSpawnPanel = signal(false)
export const personaGenerating = signal(false)
export const personaSaving = signal(false)
export const personaDraft = signal<PersonaDraft | null>(null)
export const personaSaveResult = signal<PersonaSaveResult | null>(null)
export const personaAuthoringResult = signal<{ success: boolean; message: string } | null>(null)

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
    if (!opts?.dryRun) showToast(`${personaName} 키퍼 생성 완료`, 'success')
  } catch (err) {
    const message = formatKeeperSpawnError(err instanceof Error ? err.message : String(err))
    spawnResult.value = { success: false, message }
    showToast(`키퍼 생성 실패: ${message}`, 'error')
  } finally {
    spawning.value = false
  }
}

export interface GeneratePersonaDraftInput {
  concept: string
  handle?: string
  displayName?: string
  language?: string
  proactiveEnabled?: boolean
}

export async function generatePersonaDraft(input: GeneratePersonaDraftInput): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    const message = access.reason ?? '페르소나 생성 권한이 없습니다.'
    personaAuthoringResult.value = { success: false, message }
    showToast(message, 'error', 6000)
    return
  }
  const concept = input.concept.trim()
  if (!concept) {
    personaAuthoringResult.value = { success: false, message: '컨셉을 입력하세요.' }
    showToast('컨셉을 입력하세요.', 'error')
    return
  }
  personaGenerating.value = true
  personaAuthoringResult.value = null
  try {
    const args: Record<string, unknown> = {
      concept,
      language: input.language?.trim() || 'ko',
      proactive_enabled: input.proactiveEnabled === true,
    }
    if (input.handle?.trim()) args.handle = input.handle.trim()
    if (input.displayName?.trim()) args.display_name = input.displayName.trim()
    const result = await callMcpTool('masc_persona_generate', args)
    const draft = normalizePersonaDraft(parseToolJson(result))
    if (!draft) throw new Error('페르소나 생성 결과를 해석할 수 없습니다.')
    personaDraft.value = draft
    personaSaveResult.value = null
    personaAuthoringResult.value = { success: true, message: result }
    showToast(`${draft.handle} 페르소나 초안 생성`, 'success')
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    personaAuthoringResult.value = { success: false, message }
    showToast(`페르소나 생성 실패: ${message}`, 'error')
  } finally {
    personaGenerating.value = false
  }
}

export async function savePersonaDraft(opts?: { overwrite?: boolean; dryRun?: boolean }): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    const message = access.reason ?? '페르소나 저장 권한이 없습니다.'
    personaAuthoringResult.value = { success: false, message }
    showToast(message, 'error', 6000)
    return
  }
  const draft = personaDraft.value
  if (!draft) {
    personaAuthoringResult.value = { success: false, message: '저장할 페르소나 초안이 없습니다.' }
    showToast('저장할 페르소나 초안이 없습니다.', 'error')
    return
  }
  personaSaving.value = true
  personaAuthoringResult.value = null
  try {
    const result = await callMcpTool('masc_persona_save', {
      handle: draft.handle,
      profile: draft.profile,
      overwrite: opts?.overwrite === true,
      dry_run: opts?.dryRun === true,
    })
    const normalized = normalizePersonaSaveResult(parseToolJson(result))
    if (!normalized) throw new Error('페르소나 저장 결과를 해석할 수 없습니다.')
    personaSaveResult.value = normalized
    personaAuthoringResult.value = { success: true, message: result }
    if (normalized.saved) {
      await loadPersonas()
      showToast(`${draft.handle} 페르소나 저장 완료`, 'success')
    } else {
      showToast(`${draft.handle} 페르소나 저장 dry-run 완료`, 'success')
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    personaAuthoringResult.value = { success: false, message }
    showToast(`페르소나 저장 실패: ${message}`, 'error')
  } finally {
    personaSaving.value = false
  }
}

export async function shutdownKeeper(keeperName: string): Promise<void> {
  const access = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  if (!access.allowed) {
    showToast(access.reason ?? '키퍼 종료 권한이 없습니다.', 'error', 6000)
    return
  }
  try {
    await callMcpTool('masc_keeper_down', { name: keeperName })
    showToast(`${keeperName} 키퍼 종료 완료`, 'success')
  } catch (err) {
    showToast(`키퍼 종료 실패: ${err instanceof Error ? err.message : String(err)}`, 'error')
  }
}
