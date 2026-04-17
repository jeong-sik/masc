import { signal, computed } from '@preact/signals'
import type { McpToolSchema, JsonSchema } from '../../types/json-schema'
import { listAllMcpTools, callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { buildDefaults, stripEmptyOptionals, validateRequired } from './schema-form'

const allToolSchemas = signal<McpToolSchema[]>([])
export const schemasLoading = signal(false)
export const schemasError = signal<string | null>(null)
const schemasLoadedAt = signal<number>(0)

export const searchQuery = signal('')
export const tierFilter = signal<string>('all')

export const selectedTool = signal<McpToolSchema | null>(null)
export const formValues = signal<Record<string, unknown>>({})
export const validationErrors = signal<string[]>([])

export const executing = signal(false)
export const lastResult = signal<{ success: boolean; text: string; toolName: string; timestamp: number } | null>(null)

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

const CACHE_TTL_MS = 5 * 60 * 1000

export async function loadToolSchemas(force = false): Promise<void> {
  if (!force && allToolSchemas.value.length > 0 && Date.now() - schemasLoadedAt.value < CACHE_TTL_MS) return
  if (schemasLoading.value) return
  schemasLoading.value = true
  schemasError.value = null
  try {
    const raw = await listAllMcpTools()
    allToolSchemas.value = raw.map(t => ({
      ...t,
      inputSchema: t.inputSchema as unknown as JsonSchema,
    })) as McpToolSchema[]
    schemasLoadedAt.value = Date.now()
  } catch (err) {
    schemasError.value = err instanceof Error ? err.message : String(err)
    showToast('도구 스키마 로드 실패', 'error')
  } finally {
    schemasLoading.value = false
  }
}

export function selectTool(tool: McpToolSchema): void {
  selectedTool.value = tool
  formValues.value = buildDefaults(tool.inputSchema)
  validationErrors.value = []
  lastResult.value = null
}

export function clearSelection(): void {
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
  if (!tool || executing.value) return
  const missing = validateRequired(formValues.value, tool.inputSchema)
  if (missing.length > 0) {
    validationErrors.value = missing
    showToast(`필수 필드 누락: ${missing.join(', ')}`, 'error')
    return
  }
  executing.value = true
  lastResult.value = null
  try {
    const args = stripEmptyOptionals(formValues.value, tool.inputSchema)
    const text = await callMcpTool(tool.name, args)
    lastResult.value = { success: true, text, toolName: tool.name, timestamp: Date.now() }
    showToast(`${tool.name} 실행 완료`, 'success')
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    lastResult.value = { success: false, text: message, toolName: tool.name, timestamp: Date.now() }
    showToast(`${tool.name} 실행 실패`, 'error')
  } finally {
    executing.value = false
  }
}
