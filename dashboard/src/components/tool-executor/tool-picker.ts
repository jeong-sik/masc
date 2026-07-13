import { html } from 'htm/preact'
import { TextInput } from '../common/input'
import { CountBadge } from '../common/badge'
import { ActionButton } from '../common/button'
import { searchQuery, tierFilter, filteredTools, selectedTool, selectTool } from './tool-executor-state'
import type { McpToolSchema } from '../../types/json-schema'

const TIER_OPTIONS = [
  { value: 'all', label: '전체' },
  { value: 'essential', label: 'Essential' },
  { value: 'standard', label: 'Standard' },
  { value: 'full', label: 'Full' },
]

function ToolRow({ tool, isSelected }: { tool: McpToolSchema; isSelected: boolean }) {
  const isReadOnly = tool.annotations?.readOnlyHint === true
  const isDeprecated = tool.annotations?.deprecated === true
  return html`
    <${ActionButton}
      block
      variant=${isSelected ? 'ghost' : 'subtle'}
      size="md"
      pressed=${isSelected}
      class=${`text-left px-3 py-2 ${isDeprecated ? 'opacity-50' : ''}`}
      onClick=${() => selectTool(tool)}>
      <div class="flex items-center gap-1.5">
        <span class="text-xs text-[var(--color-fg-secondary)] font-mono truncate flex-1">${tool.name}</span>
        ${isReadOnly ? html`<${CountBadge} tone="ok">R<//>` : null}
      </div>
      <div class="text-3xs text-[var(--color-fg-muted)] mt-0.5 line-clamp-1">${tool.description}</div>
    <//>
  `
}

export function ToolPicker() {
  const tools = filteredTools.value
  const selected = selectedTool.value
  return html`
    <div class="v2-lab-panel flex flex-col gap-2 h-full">
      <${TextInput} value=${searchQuery.value} placeholder="도구 검색..."
        onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }} />
      <div class="flex gap-1">
        ${TIER_OPTIONS.map(opt => html`
          <${ActionButton}
            variant=${tierFilter.value === opt.value ? 'ghost' : 'subtle'}
            size="sm"
            pressed=${tierFilter.value === opt.value}
            class="text-3xs"
            onClick=${() => { tierFilter.value = opt.value }}>${opt.label}<//>
        `)}
        <span class="text-3xs text-[var(--color-fg-muted)] ml-auto self-center">${tools.length}개</span>
      </div>
      <div class="flex flex-col gap-0.5 overflow-y-auto flex-1 min-h-0 pr-1">
        ${tools.length === 0
          ? html`<p class="text-xs text-[var(--color-fg-muted)] py-4 text-center">결과 없음</p>`
          : tools.map(tool => html`<${ToolRow} key=${tool.name} tool=${tool} isSelected=${selected?.name === tool.name} />`)}
      </div>
    </div>
  `
}
