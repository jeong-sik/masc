import { signal, computed, batch } from '@preact/signals'
import type { McpToolSchema, JsonSchema } from '../../types/json-schema'
import { listAllMcpTools, callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { buildDefaults, stripEmptyOptionals, validateRequired } from './schema-form'
import { shellAuthSummary } from '../../store'
import { dashboardAuthAccess, type DashboardAuthRole } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'
import { currentStoredTokenRevision, subscribeStoredTokenChanges } from '../../api/core'
import { storedTokenRevision } from '../../api/token-revision'

const allToolSchemas = signal<McpToolSchema[]>([])
export const schemasLoading = signal(false)
export const schemasError = signal<string | null>(null)
let schemaCacheReceipt: { readonly authRevision: number; readonly at: number } | null = null

export const searchQuery = signal('')
export const tierFilter = signal<string>('all')

interface ToolResult { readonly success: boolean; readonly text: string; readonly toolName: string; readonly timestamp: number }
interface SelectionState {
  readonly id: symbol
  readonly authRevision: number
  readonly tool: McpToolSchema | null
  readonly values: Record<string, unknown>
  readonly errors: string[]
  readonly result: ToolResult | null
}
function emptySelection(): SelectionState {
  return Object.freeze({ id: Symbol('tool-selection'), authRevision: currentStoredTokenRevision(), tool: null, values: {}, errors: [], result: null })
}
const selection = signal<SelectionState>(emptySelection())
const visibleSelection = computed(() => selection.value.authRevision === storedTokenRevision.value ? selection.value : null)
export const selectedTool = computed(() => visibleSelection.value?.tool ?? null)
export const formValues = computed(() => visibleSelection.value?.values ?? {})
export const validationErrors = computed(() => visibleSelection.value?.errors ?? [])
export const lastResult = computed(() => visibleSelection.value?.result ?? null)
interface ExecutionOwner { readonly id: symbol; readonly authRevision: number; readonly selection: symbol }
const execution = signal<ExecutionOwner | null>(null)
export const executing = computed(() => execution.value !== null && execution.value.authRevision === storedTokenRevision.value)

function selectedToolRequiredRole(tool: McpToolSchema | null): DashboardAuthRole {
  return tool?.annotations?.readOnlyHint === true ? 'reader' : 'worker'
}

export const selectedToolAccess = computed(() => (
  dashboardAuthAccess(shellAuthSummary.value, selectedToolRequiredRole(selectedTool.value))
))

export const filteredTools = computed(() => {
  let tools = allToolSchemas.value
  const q = searchQuery.value.toLowerCase().trim()
  if (q) {
    tools = tools.filter(t => t.name.toLowerCase().includes(q) || t.description.toLowerCase().includes(q))
  }
  if (tierFilter.value !== 'all') {
    tools = tools.filter(t => {
      const tier = (t.annotations as Record<string, unknown> | undefined)?.['x-tier']
      return tier === tierFilter.value
    })
  }
  return tools
})

type SchemaReadOwner =
  | { readonly kind: 'preparing'; readonly id: symbol; readonly authRevision: number }
  | { readonly kind: 'admitted'; readonly id: symbol; readonly authRevision: number }
let schemaReadOwner: SchemaReadOwner | null = null
subscribeStoredTokenChanges(() => {
  const revision = currentStoredTokenRevision()
  if (schemaReadOwner?.kind === 'admitted' && schemaReadOwner.authRevision !== revision) schemaReadOwner = null
  batch(() => {
    if (schemaCacheReceipt?.authRevision !== revision) {
      schemaCacheReceipt = null
      allToolSchemas.value = []
    }
    if (schemaReadOwner?.authRevision !== revision) {
      schemasLoading.value = false
      schemasError.value = null
    }
  })
})

const CACHE_TTL_MS = 5 * 60 * 1000

export async function loadToolSchemas(force = false): Promise<void> {
  const authRevision = currentStoredTokenRevision()
  if (!force && schemaCacheReceipt?.authRevision === authRevision && allToolSchemas.value.length > 0 && Date.now() - schemaCacheReceipt.at < CACHE_TTL_MS) return
  if (schemaReadOwner?.authRevision === authRevision) return
  const id = Symbol('schema-read')
  schemaReadOwner = Object.freeze({ kind: 'preparing', id, authRevision })
  const owns = () => schemaReadOwner?.id === id && currentStoredTokenRevision() === schemaReadOwner.authRevision
  try {
    schemasLoading.value = true
    if (!owns()) return
    schemasError.value = null
    if (!owns()) return
    const raw = await listAllMcpTools({ onAdmission: admission => {
      if (schemaReadOwner?.id !== id) return
      schemaReadOwner = Object.freeze({ kind: 'admitted', id, authRevision: admission.authRevision })
      if (owns()) schemasLoading.value = true
    } })
    if (!owns()) return
    allToolSchemas.value = raw.map(t => ({
      ...t,
      inputSchema: t.inputSchema as unknown as JsonSchema,
    })) as McpToolSchema[]
    if (!owns()) return
    schemaCacheReceipt = Object.freeze({ authRevision: currentStoredTokenRevision(), at: Date.now() })
  } catch (err) {
    if (!owns()) return
    schemasError.value = errorToString(err)
    if (!owns()) return
    showToast('도구 스키마 로드 실패', 'error')
  } finally {
    try {
      if (owns()) schemasLoading.value = false
    } finally {
      if (schemaReadOwner?.id === id) schemaReadOwner = null
    }
  }
}

export function selectTool(tool: McpToolSchema): void {
  selection.value = Object.freeze({ ...emptySelection(), tool, values: buildDefaults(tool.inputSchema) })
}

export function clearSelection(): void {
  selection.value = emptySelection()
}

export function updateFormValues(values: Record<string, unknown>): void {
  const current = visibleSelection.value
  if (!current) return
  selection.value = Object.freeze({ ...current, values,
    errors: current.errors.filter(name => values[name] === undefined || values[name] === null || values[name] === '') })
}

class ToolExecutionSupersededError extends Error {}

export async function executeTool(): Promise<void> {
  const submitted = visibleSelection.value
  const tool = submitted?.tool
  if (!submitted || !tool || executing.value) return
  const access = dashboardAuthAccess(shellAuthSummary.value, selectedToolRequiredRole(tool))
  if (!access.allowed) {
    showToast(access.reason ?? `${tool.name} 실행 권한 없음`, 'error', 6000)
    return
  }
  const missing = validateRequired(submitted.values, tool.inputSchema)
  if (missing.length > 0) {
    selection.value = Object.freeze({ ...submitted, errors: missing })
    showToast(`필수 필드 누락: ${missing.join(', ')}`, 'error')
    return
  }
  const id = Symbol('tool-execution')
  const args = stripEmptyOptionals(submitted.values, tool.inputSchema)
  const owns = () => execution.value?.id === id && execution.value.authRevision === currentStoredTokenRevision()
  const ownsSelection = () => owns() && selection.value.id === submitted.id && selection.value.authRevision === currentStoredTokenRevision()
  try {
    execution.value = Object.freeze({ id, authRevision: submitted.authRevision, selection: submitted.id })
    if (!ownsSelection()) return
    selection.value = Object.freeze({ ...submitted, result: null })
    if (!ownsSelection()) return
    const text = await callMcpTool(tool.name, args, { onAdmission: binding => {
      const pending = execution.value
      if (pending?.id !== id || pending.authRevision !== binding.fromRevision
        || binding.authRevision !== currentStoredTokenRevision()
        || selection.value.id !== submitted.id) throw new ToolExecutionSupersededError()
      batch(() => {
        execution.value = Object.freeze({ id, authRevision: binding.authRevision, selection: submitted.id })
        selection.value = Object.freeze({ ...selection.value, authRevision: binding.authRevision })
      })
      if (!ownsSelection()) throw new ToolExecutionSupersededError()
    } })
    if (!ownsSelection()) return
    selection.value = Object.freeze({ ...selection.value, result: { success: true, text, toolName: tool.name, timestamp: Date.now() } })
    if (!ownsSelection()) return
    showToast(`${tool.name} 실행 완료`, 'success')
  } catch (err) {
    if (!ownsSelection()) return
    const message = errorToString(err)
    selection.value = Object.freeze({ ...selection.value, result: { success: false, text: message, toolName: tool.name, timestamp: Date.now() } })
    if (!ownsSelection()) return
    showToast(`${tool.name} 실행 실패`, 'error')
  } finally {
    if (execution.value?.id === id) execution.value = null
  }
}
