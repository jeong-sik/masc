import { signal, computed, batch } from '@preact/signals'
import type { McpToolSchema, JsonSchema } from '../../types/json-schema'
import { listAllMcpTools, callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { buildDefaults, stripEmptyOptionals, validateRequired } from './schema-form'
import { shellAuthSummary } from '../../store'
import { dashboardAuthAccess, type DashboardAuthRole } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'
import { currentStoredTokenRevision, subscribeStoredTokenChanges } from '../../api/core'

const allToolSchemas = signal<McpToolSchema[]>([])
export const schemasLoading = signal(false)
export const schemasError = signal<string | null>(null)
let schemaCacheReceipt: { readonly authRevision: number; readonly at: number } | null = null

export const searchQuery = signal('')
export const tierFilter = signal<string>('all')

export const selectedTool = signal<McpToolSchema | null>(null)
export const formValues = signal<Record<string, unknown>>({})
export const validationErrors = signal<string[]>([])

export const executing = signal(false)
export const lastResult = signal<{ success: boolean; text: string; toolName: string; timestamp: number } | null>(null)

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

let selectionOwner = Object.freeze({})
interface ExecutionOwner { readonly authRevision: number; readonly selection: object }
let executionOwner: ExecutionOwner | null = null

type SchemaReadOwner =
  | { readonly kind: 'preparing'; readonly id: symbol; readonly authRevision: number }
  | { readonly kind: 'admitted'; readonly id: symbol; readonly authRevision: number }
let schemaReadOwner: SchemaReadOwner | null = null
subscribeStoredTokenChanges(() => {
  const revision = currentStoredTokenRevision()
  if (schemaReadOwner?.kind === 'admitted' && schemaReadOwner.authRevision !== revision) schemaReadOwner = null
  executionOwner = null
  batch(() => {
    if (schemaCacheReceipt?.authRevision !== revision) {
      schemaCacheReceipt = null
      allToolSchemas.value = []
    }
    if (schemaReadOwner?.authRevision !== revision) {
      schemasLoading.value = false
      schemasError.value = null
    }
    executing.value = false
    clearSelection()
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
  selectionOwner = Object.freeze({})
  selectedTool.value = tool
  formValues.value = buildDefaults(tool.inputSchema)
  validationErrors.value = []
  lastResult.value = null
}

export function clearSelection(): void {
  selectionOwner = Object.freeze({})
  selectedTool.value = null
  formValues.value = {}
  validationErrors.value = []
  lastResult.value = null
}

export function updateFormValues(values: Record<string, unknown>): void {
  formValues.value = values
  if (validationErrors.value.length > 0) {
    validationErrors.value = validationErrors.value.filter(
      name => values[name] === undefined || values[name] === null || values[name] === '',
    )
  }
}

export async function executeTool(): Promise<void> {
  const tool = selectedTool.value
  if (!tool || executionOwner) return
  const access = dashboardAuthAccess(shellAuthSummary.value, selectedToolRequiredRole(tool))
  if (!access.allowed) {
    showToast(access.reason ?? `${tool.name} 실행 권한 없음`, 'error', 6000)
    return
  }
  const missing = validateRequired(formValues.value, tool.inputSchema)
  if (missing.length > 0) {
    validationErrors.value = missing
    showToast(`필수 필드 누락: ${missing.join(', ')}`, 'error')
    return
  }
  const owner = Object.freeze({ authRevision: currentStoredTokenRevision(), selection: selectionOwner })
  const args = stripEmptyOptionals(formValues.value, tool.inputSchema)
  executionOwner = owner
  const owns = () => executionOwner === owner && owner.authRevision === currentStoredTokenRevision()
  const ownsSelection = () => owns() && selectionOwner === owner.selection
  try {
    executing.value = true
    if (!ownsSelection()) return
    lastResult.value = null
    if (!ownsSelection()) return
    const text = await callMcpTool(tool.name, args)
    if (!ownsSelection()) return
    lastResult.value = { success: true, text, toolName: tool.name, timestamp: Date.now() }
    if (!ownsSelection()) return
    showToast(`${tool.name} 실행 완료`, 'success')
  } catch (err) {
    if (!ownsSelection()) return
    const message = errorToString(err)
    lastResult.value = { success: false, text: message, toolName: tool.name, timestamp: Date.now() }
    if (!ownsSelection()) return
    showToast(`${tool.name} 실행 실패`, 'error')
  } finally {
    try {
      if (owns()) executing.value = false
    } finally {
      if (executionOwner === owner) executionOwner = null
    }
  }
}
