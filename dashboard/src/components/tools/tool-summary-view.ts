// Summary view: top essential tools + never-used tools

import { html } from 'htm/preact'
import type { DashboardToolInventoryItem } from '../../api'
import { toolBadge } from './tool-state'

export function ToolSummaryView({ inventory }: { inventory: DashboardToolInventoryItem[] }) {
  const essential = inventory
    .filter(item => item.tier === 'essential' && item.enabled_in_current_mode)
    .slice(0, 10)

  const neverUsed = inventory
    .filter(item => item.lifecycle !== 'deprecated' && item.visibility !== 'hidden')
    .slice(-5)
    .reverse()

  const visible = inventory.filter(item => item.visibility !== 'hidden')
  const hiddenCount = inventory.length - visible.length
  const visibleCount = visible.length
  const enabledCount = visible.filter(item => item.enabled_in_current_mode).length
  const deprecatedCount = visible.filter(item => item.lifecycle === 'deprecated').length

  return html`
    <div class="py-2">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3 my-4">
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${visibleCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">공개 도구</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${enabledCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">활성화됨</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${hiddenCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">내부 전용</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${deprecatedCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">폐기 예정</span>
        </div>
      </div>

      ${essential.length > 0 ? html`
        <div class="mt-5">
          <h4 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-3">필수 도구 (상위 ${essential.length}개)</h4>
          <div class="flex flex-col">
            ${essential.map(item => html`
              <div class="flex items-center gap-3 py-2.5 border-b border-[var(--white-4)] hover:bg-[var(--white-3)] transition-colors px-2 rounded" key=${item.name}>
                <span class="text-[13px] font-medium text-[var(--text-strong)] min-w-[180px] shrink-0">${item.name}</span>
                <span class="text-[12px] text-[var(--text-muted)] flex-1 overflow-hidden text-ellipsis whitespace-nowrap">${item.description?.slice(0, 60) ?? ''}</span>
                ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
              </div>
            `)}
          </div>
        </div>
      ` : null}

      ${neverUsed.length > 0 ? html`
        <div class="mt-5">
          <h4 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-3">미사용 도구 (${neverUsed.length}개)</h4>
          <div class="flex flex-col">
            ${neverUsed.map(item => html`
              <div class="flex items-center gap-3 py-2.5 border-b border-[var(--white-4)] hover:bg-[var(--white-3)] transition-colors px-2 rounded" key=${item.name}>
                <span class="text-[13px] font-medium text-[var(--text-strong)] min-w-[180px] shrink-0">${item.name}</span>
                <span class="text-[12px] text-[var(--text-muted)] flex-1 overflow-hidden text-ellipsis whitespace-nowrap">${item.description?.slice(0, 60) ?? ''}</span>
                ${toolBadge(item.category)}
              </div>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}
