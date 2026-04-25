import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { useEffect, useState, useMemo } from 'preact/hooks'
import { useCombobox } from 'downshift'
import { editKeeperTools, type ToolEditResponse } from '../../api/keeper'
import { toolsData } from './tool-state'

// ── State signals ────────────────────────────

const policyMode = signal<'preset' | 'custom'>('preset')
const preset = signal<
  'minimal' | 'social' | 'messaging' | 'dispatch' | 'coding' | 'research' | 'delivery' | 'full'
>('full')
const alsoAllowItems = signal<string[]>([])
const customAllowItems = signal<string[]>([])
const denyItems = signal<string[]>([])
const saving = signal(false)
const lastError = signal<string | null>(null)
const lastSuccess = signal<string | null>(null)

// Bulk text input: which section is in text mode (null = none)
const textInputSection = signal<'also_allow' | 'custom' | 'deny' | null>(null)
const textInputBuffer = signal('')

// ── Preset metadata ──────────────────────────

const PRESET_DESCRIPTIONS: Record<string, string> = {
  minimal: 'base + status, tool_help',
  social: 'minimal + direct messages and social relay',
  messaging: 'base + board, coordination, voice, governance',
  dispatch: 'goal/task routing, keeper ping, code read, board + shell read',
  coding: 'base + filesystem, library, shell, coding shards',
  research: 'base + filesystem, library, board, autoresearch',
  delivery: 'research + coding + delivery surfaces',
  full: '전체 후보 도구',
}

// ── Tool inventory (from /api/v1/dashboard/tools) ──

const inventoryNames = computed<string[]>(() => {
  const inv = toolsData.value?.tool_inventory?.tools
  return inv ? inv.map(t => t.name).sort() : []
})

const inventoryDescMap = computed<Map<string, string>>(() => {
  const inv = toolsData.value?.tool_inventory?.tools
  const m = new Map<string, string>()
  if (inv) for (const t of inv) m.set(t.name, t.description)
  return m
})

const inventoryCategoryMap = computed<Map<string, string>>(() => {
  const inv = toolsData.value?.tool_inventory?.tools
  const m = new Map<string, string>()
  if (inv) for (const t of inv) m.set(t.name, t.category)
  return m
})

const usageCountMap = computed<Map<string, number>>(() => {
  const top = toolsData.value?.tool_usage?.top_20
  const m = new Map<string, number>()
  if (top) for (const t of top) m.set(t.name, t.call_count)
  return m
})

const RESOLVED_CATEGORY_PREVIEW_LIMIT = 4
const RESOLVED_TOOLS_PER_CATEGORY_LIMIT = 6

// ── Helpers ──────────────────────────────────

function parseToolList(raw: string): string[] {
  return [...new Set(raw.split(/[\n,]/).map(s => s.trim()).filter(Boolean))]
}

function resetEditorState(params: {
  mode?: string | null
  preset?: string | null
  alsoAllow?: string[]
  customAllowlist?: string[]
  denylist?: string[]
}) {
  policyMode.value = params.mode === 'custom' ? 'custom' : 'preset'
  const pv = params.preset
  preset.value =
    pv === 'minimal'
    || pv === 'social'
    || pv === 'messaging'
    || pv === 'dispatch'
    || pv === 'coding'
    || pv === 'research'
    || pv === 'delivery'
    || pv === 'full'
      ? pv : 'full'
  alsoAllowItems.value = [...(params.alsoAllow ?? [])]
  customAllowItems.value = [...(params.customAllowlist ?? [])]
  denyItems.value = [...(params.denylist ?? [])]
  saving.value = false
  lastError.value = null
  lastSuccess.value = null
  textInputSection.value = null
  textInputBuffer.value = ''
}

function addToList(listSig: typeof alsoAllowItems, name: string) {
  const trimmed = name.trim()
  if (trimmed && !listSig.value.includes(trimmed)) {
    listSig.value = [...listSig.value, trimmed]
  }
}

function removeFromList(listSig: typeof alsoAllowItems, name: string) {
  listSig.value = listSig.value.filter(n => n !== name)
}

// ── Sub-components ───────────────────────────

function RemovableChip({ name, onRemove }: { name: string; onRemove: () => void }) {
  return html`
    <span class="inline-flex items-center gap-0.5 py-0.5 px-2 rounded-sm text-3xs font-medium bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-30)]">
      ${name}
      <button type="button"
        class="text-[var(--accent)]/50 hover:text-[#ff6b6b] cursor-pointer text-2xs leading-none transition-colors"
        onClick=${onRemove}
        title="제거"
      >\u00d7</button>
    </span>
  `
}

function ReadOnlyChip({ name }: { name: string }) {
  return html`
    <span class="inline-flex items-center py-0.5 px-2 rounded-sm text-3xs font-medium bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-30)]">
      ${name}
    </span>
  `
}

/** Resolved allowlist grouped by category. */
export interface ResolvedAllowlistGroup {
  category: string
  names: string[]
}

export function buildResolvedAllowlistGroups(
  tools: string[],
  catMap: Map<string, string>,
): ResolvedAllowlistGroup[] {
  const groups = new Map<string, string[]>()
  for (const name of tools) {
    const cat = catMap.get(name) ?? 'other'
    const list = groups.get(cat)
    if (list) list.push(name)
    else groups.set(cat, [name])
  }

  return Array.from(groups.entries())
    .map(([category, names]) => ({
      category,
      names,
    }))
    .sort((left, right) => right.names.length - left.names.length || left.category.localeCompare(right.category))
}

/**
 * Pure filter for resolved allowlist tool names.
 *
 * Case-insensitive substring match on the tool name itself and on its
 * category (via `catMap`) so operators can locate a tool by partial
 * name or by category (e.g. "board", "shell").
 *
 * Empty/whitespace query returns the input reference unchanged so
 * useMemo keeps referential identity for the non-filtering path.
 *
 * Input is never mutated.
 */
export function filterResolvedTools(
  tools: readonly string[],
  catMap: Map<string, string>,
  query: string,
): readonly string[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return tools
  return tools.filter(name => {
    if (name.toLowerCase().includes(needle)) return true
    const cat = catMap.get(name)
    if (cat && cat.toLowerCase().includes(needle)) return true
    return false
  })
}

export function ResolvedPreview({ tools, catMap }: { tools: string[]; catMap: Map<string, string> }) {
  const [expanded, setExpanded] = useState(false)
  const [query, setQuery] = useState('')
  const firstTool = tools[0] ?? null
  const lastTool = tools.length > 0 ? tools[tools.length - 1] : null

  useEffect(() => {
    setExpanded(false)
  }, [tools.length, firstTool, lastTool])

  const visibleTools = useMemo(
    () => filterResolvedTools(tools, catMap, query),
    [tools, catMap, query],
  )

  if (tools.length === 0) {
    return html`
      <div class="flex flex-col gap-1">
        <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">resolved allowlist (0)</span>
        <span class="text-2xs text-[var(--text-muted)] italic" role="status">resolved allowlist 없음</span>
      </div>
    `
  }

  const isFiltering = query.trim() !== ''
  const groups = buildResolvedAllowlistGroups([...visibleTools], catMap)
  const visibleGroups = expanded ? groups : groups.slice(0, RESOLVED_CATEGORY_PREVIEW_LIMIT)
  const hasHiddenContent = groups.length > RESOLVED_CATEGORY_PREVIEW_LIMIT
    || groups.some(group => group.names.length > RESOLVED_TOOLS_PER_CATEGORY_LIMIT)

  return html`
    <div class="flex flex-col gap-1">
      <div class="flex items-center justify-between gap-2">
        <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">
          resolved allowlist (${tools.length}개, ${groups.length} 카테고리)
        </span>
        <input
          type="search"
          value=${query}
          placeholder="도구/카테고리 필터"
          aria-label="resolved allowlist 필터"
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          class="min-w-35 max-w-55 flex-1 rounded border border-[var(--card-border)] bg-[var(--white-3)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-muted)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
        />
      </div>
      ${isFiltering && visibleTools.length === 0
        ? html`<div class="py-3 text-center text-2xs text-[var(--text-muted)]" role="status">필터 결과 없음 (${tools.length}개 도구)</div>`
        : html`
          <div class="flex flex-col gap-2">
            ${visibleGroups.map(group => {
              const visibleNames = expanded ? group.names : group.names.slice(0, RESOLVED_TOOLS_PER_CATEGORY_LIMIT)
              const hiddenToolCount = Math.max(0, group.names.length - visibleNames.length)
              return html`
              <div class="flex flex-col gap-1">
                <span class="text-3xs font-bold uppercase tracking-widest text-[var(--text-muted)]">${group.category} (${group.names.length})</span>
                <div class="flex flex-wrap gap-1">
                  ${visibleNames.map(name => html`<${ReadOnlyChip} name=${name} />`)}
                  ${!expanded && hiddenToolCount > 0
                    ? html`
                        <span class="inline-flex items-center py-0.5 px-2 rounded-sm text-3xs font-medium border border-dashed border-[var(--card-border)] text-[var(--text-muted)]">
                          +${hiddenToolCount}
                        </span>
                      `
                    : null}
                </div>
              </div>
            `
            })}
          </div>
          ${hasHiddenContent
            ? html`
                <button type="button"
                  class="self-start text-3xs text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer transition-colors"
                  aria-expanded=${expanded}
                  aria-label=${expanded ? 'resolved allowlist 접기' : `resolved allowlist 전체 ${tools.length}개 보기`}
                  onClick=${() => setExpanded(value => !value)}
                >
                  ${expanded ? '접기' : `전체 ${tools.length}개 보기`}
                </button>
              `
            : null}
        `}
    </div>
  `
}

/** Search-based tool picker using downshift useCombobox for keyboard nav + ARIA. */
function ToolSearchPicker({
  items,
  onAdd,
  onRemove,
  placeholder,
  excludeItems,
}: {
  items: string[]
  onAdd: (name: string) => void
  onRemove: (name: string) => void
  placeholder: string
  excludeItems?: string[]
}) {
  const [inputValue, setInputValue] = useState('')
  const excluded = useMemo(() => new Set([...items, ...(excludeItems ?? [])]), [items, excludeItems])
  const descMap = inventoryDescMap.value
  const catMap = inventoryCategoryMap.value
  const usageMap = usageCountMap.value
  const allNames = inventoryNames.value

  const filtered = useMemo(() => {
    const q = inputValue.toLowerCase().trim()
    if (q.length === 0) return []
    const matched = allNames.filter(name => !excluded.has(name) && name.toLowerCase().includes(q))
    matched.sort((a, b) => (usageMap.get(b) ?? 0) - (usageMap.get(a) ?? 0))
    return matched.slice(0, 15)
  }, [inputValue, excluded, allNames, usageMap])

  // Group filtered items by category for rendering (flat array for downshift, visual grouping for UI)
  const groupedFiltered = useMemo(() => {
    const groups = new Map<string, string[]>()
    for (const name of filtered) {
      const cat = catMap.get(name) ?? 'other'
      const list = groups.get(cat)
      if (list) list.push(name)
      else groups.set(cat, [name])
    }
    return groups
  }, [filtered, catMap])

  const {
    isOpen,
    highlightedIndex,
    getMenuProps,
    getInputProps,
    getItemProps,
  } = useCombobox({
    items: filtered,
    inputValue,
    itemToString: item => item ?? '',
    onInputValueChange: ({ inputValue: v }) => setInputValue(v ?? ''),
    onSelectedItemChange: ({ selectedItem }) => {
      if (selectedItem) {
        onAdd(selectedItem)
        setInputValue('')
      }
    },
    stateReducer: (_state, { type, changes }) => {
      if (type === useCombobox.stateChangeTypes.InputKeyDownEnter) {
        if (changes.selectedItem == null && inputValue.trim()) {
          onAdd(inputValue.trim())
          return { ...changes, inputValue: '', isOpen: false }
        }
      }
      return changes
    },
  })

  const showMenu = isOpen && (filtered.length > 0 || inputValue.trim().length > 1)

  return html`
    <div class="flex flex-col gap-1.5">
      ${items.length > 0
        ? html`
          <div class="flex flex-wrap gap-1">
            ${items.map(name => html`
              <${RemovableChip} name=${name} onRemove=${() => onRemove(name)} />
            `)}
          </div>
        `
        : null}

      <div class="relative">
        <input
          aria-label="도구 검색"
          ...${getInputProps({
            placeholder,
            class: 'w-full px-3 py-1.5 rounded border border-[var(--card-border)] bg-[var(--white-3)] text-2xs text-[var(--text-body)] placeholder:text-[var(--text-muted)]',
          })}
        />

        <ul ...${getMenuProps({
          class: showMenu && filtered.length > 0
            ? 'absolute z-10 top-full left-0 right-0 mt-1 max-h-55 overflow-y-auto custom-scrollbar rounded border border-[var(--card-border)] bg-[var(--backdrop-modal)] shadow-sm backdrop-blur-sm list-none m-0 p-0'
            : 'hidden',
        })}>
          ${showMenu && filtered.length > 0
            ? Array.from(groupedFiltered.entries()).map(([cat, names]) => html`
              ${groupedFiltered.size > 1
                ? html`<li class="px-3 pt-2 pb-0.5 text-3xs font-bold uppercase tracking-widest text-[var(--text-muted)] select-none" aria-hidden="true">${cat}</li>`
                : null}
              ${names.map(name => {
                const idx = filtered.indexOf(name)
                const usage = usageMap.get(name)
                return html`
                  <li
                    ...${getItemProps({ item: name, index: idx })}
                    class=${`w-full flex items-start gap-2 text-left px-3 py-1.5 cursor-pointer transition-colors ${
                      highlightedIndex === idx
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                        : 'hover:bg-[var(--accent-10)]'
                    }`}
                  >
                    <span class="text-2xs text-[var(--text-body)] font-medium shrink-0">${name}</span>
                    ${usage ? html`<span class="text-3xs text-[var(--text-muted)] shrink-0 tabular-nums">${usage}x</span>` : null}
                    ${descMap.has(name)
                      ? html`<span class="text-3xs text-[var(--text-muted)] truncate" title=${descMap.get(name)}>${descMap.get(name)}</span>`
                      : null}
                  </li>
                `
              })}
            `)
            : null}
        </ul>
        ${showMenu && filtered.length === 0
          ? html`
            <div class="absolute z-10 top-full left-0 right-0 mt-1 px-3 py-2 rounded border border-[var(--card-border)] bg-[var(--backdrop-modal)] text-2xs text-[var(--text-muted)]">
              ${allNames.length === 0
                ? '도구 목록 로딩 중... Enter로 직접 추가 가능'
                : '일치하는 도구 없음. Enter로 직접 추가 가능'}
            </div>`
          : null}
      </div>
    </div>
  `
}

/** Toggle between search picker and raw textarea for a section. */
function TextModeToggle({
  section,
  listSig,
}: {
  section: 'also_allow' | 'custom' | 'deny'
  listSig: typeof alsoAllowItems
}) {
  const isText = textInputSection.value === section

  if (!isText) {
    return html`
      <button type="button"
        class="text-3xs text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer transition-colors"
        onClick=${() => {
          textInputBuffer.value = listSig.value.join(', ')
          textInputSection.value = section
        }}
      >텍스트 입력</button>
    `
  }

  return html`
    <div class="flex gap-2">
      <button type="button"
        class="text-3xs text-[var(--ok)] hover:text-[var(--ok)] cursor-pointer transition-colors"
        onClick=${() => {
          listSig.value = parseToolList(textInputBuffer.value)
          textInputSection.value = null
        }}
      >적용</button>
      <button type="button"
        class="text-3xs text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer transition-colors"
        onClick=${() => { textInputSection.value = null }}
      >취소</button>
    </div>
  `
}

// ── Section header with label + text toggle ──

function SectionHeader({
  label,
  section,
  listSig,
}: {
  label: string
  section: 'also_allow' | 'custom' | 'deny'
  listSig: typeof alsoAllowItems
}) {
  return html`
    <div class="flex items-center justify-between">
      <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">
        ${label}${listSig.value.length > 0 ? html` <span class="text-[var(--text-body)]">(${listSig.value.length})</span>` : ''}
      </span>
      <${TextModeToggle} section=${section} listSig=${listSig} />
    </div>
  `
}

// ── Main export ──────────────────────────────

export function ToolAllowlistEditor({
  keeperName,
  currentMode,
  currentPreset,
  currentAlsoAllow,
  currentCustomAllowlist,
  currentDenylist,
  resolvedAllowlist,
  onUpdated,
}: {
  keeperName: string
  currentMode?: string | null
  currentPreset?: string | null
  currentAlsoAllow?: string[]
  currentCustomAllowlist?: string[]
  currentDenylist?: string[]
  resolvedAllowlist: string[]
  onUpdated: (response: ToolEditResponse) => void
}) {
  useEffect(() => {
    resetEditorState({
      mode: currentMode,
      preset: currentPreset,
      alsoAllow: currentAlsoAllow,
      customAllowlist: currentCustomAllowlist,
      denylist: currentDenylist,
    })
  }, [
    keeperName,
    currentMode,
    currentPreset,
    JSON.stringify(currentAlsoAllow ?? []),
    JSON.stringify(currentCustomAllowlist ?? []),
    JSON.stringify(currentDenylist ?? []),
  ])

  const isCustomEmpty = policyMode.value === 'custom' && customAllowItems.value.length === 0

  async function applyChanges(): Promise<void> {
    saving.value = true
    lastError.value = null
    lastSuccess.value = null
    try {
      const response = await editKeeperTools(keeperName, {
        action: 'set_policy',
        mode: policyMode.value,
        preset: policyMode.value === 'preset' ? preset.value : undefined,
        allow: policyMode.value === 'custom' ? customAllowItems.value : undefined,
        also_allow: policyMode.value === 'preset' ? alsoAllowItems.value : undefined,
        deny: denyItems.value,
      })
      if (!response.ok) {
        lastError.value = response.error ?? '알 수 없는 오류'
        return
      }
      lastSuccess.value = `${response.total_active}개 도구 활성`
      onUpdated(response)
    } catch (err) {
      lastError.value = err instanceof Error ? err.message : '요청 실패'
    } finally {
      saving.value = false
    }
  }

  return html`
    <div class="flex flex-col gap-3 mt-2 p-3 rounded border border-[var(--card-border)] bg-[var(--panel-dark-60)]" role="region" aria-label="도구 정책 편집">
      <div class="flex items-center justify-between">
        <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">도구 정책 편집</span>
        <button type="button"
          class="text-3xs text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer"
          onClick=${() => resetEditorState({
            mode: currentMode,
            preset: currentPreset,
            alsoAllow: currentAlsoAllow,
            customAllowlist: currentCustomAllowlist,
            denylist: currentDenylist,
          })}
        >초기화</button>
      </div>

      <!-- Mode toggle -->
      <div class="flex gap-2">
        ${(['preset', 'custom'] as const).map(mode => html`
          <button type="button"
            class=${`py-1 px-3 rounded text-3xs font-medium border transition-colors cursor-pointer ${
              policyMode.value === mode
                ? 'border-[var(--accent-30)] bg-[var(--accent-soft)] text-[var(--accent)]'
                : 'border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)]'
            }`}
            aria-pressed=${policyMode.value === mode}
            onClick=${() => { policyMode.value = mode; textInputSection.value = null }}
          >${mode}</button>
        `)}
      </div>

      <!-- Preset mode -->
      ${policyMode.value === 'preset'
        ? html`
          <label class="flex flex-col gap-1">
            <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">preset</span>
            <select
              aria-label="프리셋"
              class="w-full px-3 py-2 rounded border border-[var(--card-border)] bg-[var(--white-3)] text-2xs text-[var(--text-body)]"
              value=${preset.value}
              onChange=${(e: Event) => { preset.value = (e.target as HTMLSelectElement).value as typeof preset.value }}
            >
              ${Object.entries(PRESET_DESCRIPTIONS).map(([key, desc]) => html`
                <option value=${key}>${key} \u2014 ${desc}</option>
              `)}
            </select>
          </label>

          <div class="flex flex-col gap-1">
            <${SectionHeader} label="also allow" section="also_allow" listSig=${alsoAllowItems} />
            ${textInputSection.value === 'also_allow'
              ? html`
                <textarea
                  aria-label="also allow 도구 입력"
                  class="min-h-18 w-full px-3 py-2 rounded border border-[var(--card-border)] bg-[var(--white-3)] text-2xs text-[var(--text-body)] placeholder:text-[var(--text-muted)]"
                  placeholder="쉼표 또는 줄바꿈으로 구분"
                  value=${textInputBuffer.value}
                  onInput=${(e: Event) => { textInputBuffer.value = (e.target as HTMLTextAreaElement).value }}
                />`
              : html`
                <${ToolSearchPicker}
                  items=${alsoAllowItems.value}

                  onAdd=${(name: string) => addToList(alsoAllowItems, name)}
                  onRemove=${(name: string) => removeFromList(alsoAllowItems, name)}
                  placeholder="추가 허용 도구 검색..."
                  excludeItems=${denyItems.value}
                />`}
          </div>
        `
        : html`
          <div class="flex flex-col gap-1">
            <${SectionHeader} label="custom allowlist" section="custom" listSig=${customAllowItems} />

            ${isCustomEmpty
              ? html`
                <div class="flex flex-col gap-2 px-3 py-2 rounded bg-[var(--bad-12)] border border-[var(--bad-30)]">
                  <div class="flex items-start gap-2">
                    <span class="text-[var(--bad)] text-sm shrink-0 font-bold">0</span>
                    <span class="text-2xs text-[var(--bad)] leading-snug">
                      allowlist가 비어 있으면 이 키퍼는 <strong>도구를 하나도 사용할 수 없습니다</strong>.
                    </span>
                  </div>
                  ${resolvedAllowlist.length > 0
                    ? html`
                      <button type="button"
                        class="self-start py-1 px-3 rounded text-3xs font-medium border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--accent)] hover:bg-[var(--accent-22)] cursor-pointer transition-colors"
                        onClick=${() => { customAllowItems.value = [...resolvedAllowlist] }}
                      >현재 resolved list에서 복사 (${resolvedAllowlist.length}개)</button>
                    `
                    : null}
                </div>`
              : null}

            ${textInputSection.value === 'custom'
              ? html`
                <textarea
                  aria-label="custom 도구 입력"
                  class="min-h-[88px] w-full px-3 py-2 rounded border border-[var(--card-border)] bg-[var(--white-3)] text-2xs text-[var(--text-body)] placeholder:text-[var(--text-muted)]"
                  placeholder="쉼표 또는 줄바꿈으로 구분"
                  value=${textInputBuffer.value}
                  onInput=${(e: Event) => { textInputBuffer.value = (e.target as HTMLTextAreaElement).value }}
                />`
              : html`
                <${ToolSearchPicker}
                  items=${customAllowItems.value}

                  onAdd=${(name: string) => addToList(customAllowItems, name)}
                  onRemove=${(name: string) => removeFromList(customAllowItems, name)}
                  placeholder="허용 도구 검색..."
                  excludeItems=${denyItems.value}
                />`}
          </div>
        `}

      <!-- Denylist -->
      <div class="flex flex-col gap-1">
        <${SectionHeader} label="denylist" section="deny" listSig=${denyItems} />
        ${textInputSection.value === 'deny'
          ? html`
            <textarea
              aria-label="denylist 도구 입력"
              class="min-h-18 w-full px-3 py-2 rounded border border-[var(--card-border)] bg-[var(--white-3)] text-2xs text-[var(--text-body)] placeholder:text-[var(--text-muted)]"
              placeholder="쉼표 또는 줄바꿈으로 구분"
              value=${textInputBuffer.value}
              onInput=${(e: Event) => { textInputBuffer.value = (e.target as HTMLTextAreaElement).value }}
            />`
          : html`
            <${ToolSearchPicker}
              items=${denyItems.value}
              onAdd=${(name: string) => addToList(denyItems, name)}
              onRemove=${(name: string) => removeFromList(denyItems, name)}
              placeholder="차단 도구 검색..."
              excludeItems=${policyMode.value === 'custom' ? customAllowItems.value : alsoAllowItems.value}
            />`}
      </div>

      <!-- Resolved allowlist grouped by category -->
      <${ResolvedPreview} tools=${resolvedAllowlist} catMap=${inventoryCategoryMap.value} />

      <!-- Apply -->
      <div class="flex items-center gap-3">
        <button type="button"
          class=${`py-1.5 px-4 rounded text-3xs font-medium transition-colors cursor-pointer disabled:opacity-50 ${
            isCustomEmpty
              ? 'bg-[var(--bad-light)] text-white hover:bg-[var(--bad)]'
              : 'bg-[var(--ok)] text-[#000] hover:bg-[var(--emerald)]'
          }`}
          onClick=${applyChanges}
          disabled=${saving.value}
        >
          ${saving.value
            ? '저장 중...'
            : isCustomEmpty
              ? '도구 0개로 적용'
              : '정책 적용'}
        </button>
        <span class="text-3xs text-[var(--text-muted)]">
          ${policyMode.value === 'custom'
            ? `${customAllowItems.value.length}개 허용${denyItems.value.length > 0 ? `, ${denyItems.value.length}개 차단` : ''}`
            : `preset: ${preset.value}${alsoAllowItems.value.length > 0 ? ` + ${alsoAllowItems.value.length}개 추가` : ''}${denyItems.value.length > 0 ? `, ${denyItems.value.length}개 차단` : ''}`}
        </span>
      </div>

      ${lastError.value
        ? html`<span class="text-3xs text-[var(--bad)]">${lastError.value}</span>`
        : null}
      ${lastSuccess.value
        ? html`<span class="text-3xs text-[var(--ok)]">${lastSuccess.value}</span>`
        : null}
    </div>
  `
}
