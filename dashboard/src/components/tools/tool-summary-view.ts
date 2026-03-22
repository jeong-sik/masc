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
        <div class="tool-inventory-stat">
          <span class="stat-value">${totalCount}</span>
          <span class="stat-label">전체 도구</span>
        </div>
        <div class="tool-inventory-stat">
          <span class="stat-value">${enabledCount}</span>
          <span class="stat-label">활성화됨</span>
        </div>
        <div class="tool-inventory-stat">
          <span class="stat-value">${deprecatedCount}</span>
          <span class="stat-label">폐기 예정</span>
        </div>
      </div>

      ${essential.length > 0 ? html`
        <div class="mt-5">
          <h4 class="tool-summary-heading">필수 도구 (상위 ${essential.length}개)</h4>
          <div class="tool-summary-list">
            ${essential.map(item => html`
              <div class="tool-summary-row" key=${item.name}>
                <span class="tool-summary-name">${item.name}</span>
                <span class="tool-summary-desc">${item.description?.slice(0, 60) ?? ''}</span>
                ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
              </div>
            `)}
          </div>
        </div>
      ` : null}

      ${neverUsed.length > 0 ? html`
        <div class="mt-5">
          <h4 class="tool-summary-heading">미사용 도구 (${neverUsed.length}개)</h4>
          <div class="tool-summary-list">
            ${neverUsed.map(item => html`
              <div class="tool-summary-row" key=${item.name}>
                <span class="tool-summary-name">${item.name}</span>
                <span class="tool-summary-desc">${item.description?.slice(0, 60) ?? ''}</span>
                ${toolBadge(item.category)}
              </div>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}
