import type {
  ConfigCategorySpec as ConfigCategory,
  ConfigFieldSpec as ConfigField,
  ConfigPatchChange,
  ConfigReloadScope as ReloadScope,
} from '../../api/config-schema'

export interface WorldConfigExportResponse {
  readonly ok: boolean
  readonly scope?: string
  readonly bundle?: unknown
  readonly lock_warnings?: readonly unknown[]
  readonly error?: string
}

/**
 * TUI v2.6 canonical 7 settings categories (#6).
 * Server categories matching by id or title are merged cleanly; any extra server
 * category is preserved rather than dropped.
 */
export const CANONICAL_SETTINGS_CATEGORIES: readonly { readonly id: string; readonly title: string }[] = [
  { id: 'general', title: 'General & UI' },
  { id: 'providers', title: 'Providers & Models' },
  { id: 'routing', title: 'Routing & Failover' },
  { id: 'keepers', title: 'Keepers & Companies' },
  { id: 'sandbox', title: 'Sandbox & SSH' },
  { id: 'voice', title: 'Voice & Integrations' },
  { id: 'board_memory_candle', title: 'Board, Memory & Candle' },
]

export function matchCanonicalCategoryId(cat: ConfigCategory): string {
  const id = cat.id.toLowerCase()
  const title = cat.title.toLowerCase()
  if (id.includes('general') || title.includes('general') || title.includes('ui')) return 'general'
  if (id.includes('provider') || title.includes('provider') || title.includes('model')) return 'providers'
  if (id.includes('rout') || id.includes('lane') || id.includes('failover') || title.includes('routing')) return 'routing'
  if (id.includes('keeper') || id.includes('compan') || title.includes('keeper')) return 'keepers'
  if (id.includes('sandbox') || id.includes('ssh') || id.includes('docker') || title.includes('sandbox')) return 'sandbox'
  if (id.includes('voice') || id.includes('integrat') || id.includes('gate') || title.includes('voice')) return 'voice'
  if (id.includes('board') || id.includes('memory') || id.includes('candle') || title.includes('candle')) return 'board_memory_candle'
  return cat.id
}

export function organizeCategoriesIntoSeven(
  serverCategories: readonly ConfigCategory[],
): readonly ConfigCategory[] {
  const buckets = new Map<string, { title: string; fields: ConfigField[] }>()
  for (const c of CANONICAL_SETTINGS_CATEGORIES) {
    buckets.set(c.id, { title: c.title, fields: [] })
  }

  for (const cat of serverCategories) {
    const mappedId = matchCanonicalCategoryId(cat)
    const existing = buckets.get(mappedId)
    if (existing) {
      existing.fields.push(...cat.fields)
    } else {
      buckets.set(mappedId, { title: cat.title, fields: [...cat.fields] })
    }
  }

  return [...buckets.entries()].map(([id, entry]) => ({
    id,
    title: entry.title,
    field_count: entry.fields.length,
    fields: entry.fields,
  }))
}

export function reloadScopeNotice(scope: ReloadScope): { label: string; detail: string; tone: 'ok' | 'info' | 'warn' } {
  switch (scope) {
    case 'hot_reload':
      return {
        label: 'hot_reload (즉시 반영)',
        detail: '적용 즉시 실행 중인 서버에 반영됩니다. 재시작이 필요하지 않습니다.',
        tone: 'ok',
      }
    case 'next_turn':
      return {
        label: 'next_turn (다음 턴 반영)',
        detail: '이미 진행 중인 턴은 유지되며 다음 턴부터 새 설정이 적용됩니다.',
        tone: 'info',
      }
    case 'restart_required':
      return {
        label: 'restart_required (서버 재시작 필요)',
        detail: '이 변경은 TOML에 저장되지만 MASC 서버를 재시작해야 완전히 반영됩니다.',
        tone: 'warn',
      }
  }
}

export function patchOpForField(field: ConfigField, nextValue: unknown, remove = false): ConfigPatchChange | null {
  if (remove) {
    return { op: 'remove', table: field.table, key: field.key, full_key: field.full_key }
  }
  const t = field.type.toLowerCase()
  if (t === 'bool' || t === 'boolean') {
    return { op: 'set_bool', table: field.table, key: field.key, full_key: field.full_key, value: Boolean(nextValue) }
  }
  if (t === 'int' || t === 'integer') {
    const n = typeof nextValue === 'number' ? nextValue
      : typeof nextValue === 'string' && nextValue.trim() ? Number(nextValue) : NaN
    return Number.isSafeInteger(n) ? { op: 'set_int', table: field.table, key: field.key, full_key: field.full_key, value: n } : null
  }
  if (t === 'float' || t === 'number') {
    const n = typeof nextValue === 'number' ? nextValue
      : typeof nextValue === 'string' && nextValue.trim() ? Number(nextValue) : NaN
    return Number.isFinite(n) ? { op: 'set_float', table: field.table, key: field.key, full_key: field.full_key, value: n } : null
  }
  if (t === 'string_array' || t === 'string_list' || Array.isArray(nextValue)) {
    const arr = Array.isArray(nextValue)
      ? nextValue.map((x) => String(x))
      : String(nextValue).split('\n').map((s) => s.trim()).filter(Boolean)
    return { op: 'set_string_array', table: field.table, key: field.key, full_key: field.full_key, value: arr }
  }
  return { op: 'set_string', table: field.table, key: field.key, full_key: field.full_key, value: String(nextValue ?? '') }
}
