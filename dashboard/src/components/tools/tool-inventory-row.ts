// Single inventory row component

import { html } from 'htm/preact'
import type { DashboardToolInventoryItem } from '../../api'
import { toolBadge } from './tool-state'

export function InventoryRow({ item }: { item: DashboardToolInventoryItem }) {
  return html`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${item.name}</div>
          <div class="tool-inventory-desc">${item.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
          ${toolBadge(item.tier, item.tier === 'essential' ? 'ok' : item.tier === 'standard' ? 'warn' : 'default')}
          ${toolBadge(item.visibility)}
          ${toolBadge(item.lifecycle, item.lifecycle === 'deprecated' ? 'warn' : 'default')}
          ${toolBadge(item.implementationStatus)}
        </div>
      </div>
      <div class="tool-inventory-meta">
        <span>카테고리: <strong>${item.category}</strong></span>
        <span>모드: <strong>${item.enabled_in_current_mode ? '활성' : '비활성'}</strong></span>
        <span>직접 호출: <strong>${item.direct_call_allowed ? '허용' : '차단'}</strong></span>
        <span>권한: <strong>${item.required_permission ?? '없음'}</strong></span>
      </div>
      ${item.reason
        ? html`<div class="tool-inventory-reason">${item.reason}</div>`
        : null}
      <div class="tool-inventory-links">
        ${item.canonicalName ? html`<span>정식 이름: <strong>${item.canonicalName}</strong></span>` : null}
        ${item.replacement ? html`<span>대체 도구: <strong>${item.replacement}</strong></span>` : null}
        ${item.doc_refs.length > 0 ? html`<span>문서: <strong>${item.doc_refs.join(', ')}</strong></span>` : null}
      </div>
    </article>
  `
}
