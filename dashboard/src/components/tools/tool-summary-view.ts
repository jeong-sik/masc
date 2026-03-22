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

  const totalCount = inventory.length
  const enabledCount = inventory.filter(item => item.enabled_in_current_mode).length
  const deprecatedCount = inventory.filter(item => item.lifecycle === 'deprecated').length

  return html`
    <div class="py-2">
      <div class="tool-inventory-summary">
        <div class="flex flex-col gap-1.5 px-4 py-3.5 rounded-[14px] bg-[rgba(15,23,42,0.8)] border border-[rgba(148,163,184,0.16)]">
          <span class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${totalCount}</span>
          <span class="stat-label">전체 도구</span>
        </div>
        <div class="flex flex-col gap-1.5 px-4 py-3.5 rounded-[14px] bg-[rgba(15,23,42,0.8)] border border-[rgba(148,163,184,0.16)]">
          <span class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${enabledCount}</span>
          <span class="stat-label">활성화됨</span>
        </div>
        <div class="flex flex-col gap-1.5 px-4 py-3.5 rounded-[14px] bg-[rgba(15,23,42,0.8)] border border-[rgba(148,163,184,0.16)]">
          <span class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${deprecatedCount}</span>
          <span class="stat-label">폐기 예정</span>
        </div>
      </div>

      ${essential.length > 0 ? html`
        <div class="mt-5">
          <h4 class="text-[length:var(--fs-base)] font-semibold text-[color:var(--white-60)] mb-2.5 mt-0 uppercase tracking-[0.3px]">필수 도구 (상위 ${essential.length}개)</h4>
          <div class="flex flex-col gap-1.5">
            ${essential.map(item => html`
              <div class="flex items-center gap-2.5 px-3 py-2 bg-[var(--panel-dark-60)] border border-[var(--slate-gray-8)] rounded-lg" key=${item.name}>
                <span class="text-[length:var(--fs-base)] font-medium text-[color:var(--text-slate-light)] min-w-[180px] shrink-0">${item.name}</span>
                <span class="text-[length:var(--fs-sm)] text-[color:var(--white-40)] flex-1 overflow-hidden text-ellipsis whitespace-nowrap">${item.description?.slice(0, 60) ?? ''}</span>
                ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
              </div>
            `)}
          </div>
        </div>
      ` : null}

      ${neverUsed.length > 0 ? html`
        <div class="mt-5">
          <h4 class="text-[length:var(--fs-base)] font-semibold text-[color:var(--white-60)] mb-2.5 mt-0 uppercase tracking-[0.3px]">미사용 도구 (${neverUsed.length}개)</h4>
          <div class="flex flex-col gap-1.5">
            ${neverUsed.map(item => html`
              <div class="flex items-center gap-2.5 px-3 py-2 bg-[var(--panel-dark-60)] border border-[var(--slate-gray-8)] rounded-lg" key=${item.name}>
                <span class="text-[length:var(--fs-base)] font-medium text-[color:var(--text-slate-light)] min-w-[180px] shrink-0">${item.name}</span>
                <span class="text-[length:var(--fs-sm)] text-[color:var(--white-40)] flex-1 overflow-hidden text-ellipsis whitespace-nowrap">${item.description?.slice(0, 60) ?? ''}</span>
                ${toolBadge(item.category)}
              </div>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}
