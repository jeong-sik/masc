// Single inventory row component

import { html } from 'htm/preact'
import type { DashboardToolInventoryItem } from '../../api'
import { SurfaceCard } from '../common/card'
import { toolBadge } from './tool-state'

export function InventoryRow({ item }: { item: DashboardToolInventoryItem }) {
  return html`
    <${SurfaceCard} variant="light">
      <div class="flex justify-between gap-3 items-start">
        <div>
          <div class="text-[15px] font-bold text-[var(--text-strong)]">${item.name}</div>
          <div class="tool-inventory-desc text-[12px] text-[var(--text-muted)] mt-0.5">${item.description}</div>
        </div>
        <div class="flex flex-wrap gap-1.5 justify-end">
          ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
          ${toolBadge(item.tier, item.tier === 'essential' ? 'ok' : item.tier === 'standard' ? 'warn' : 'default')}
          ${toolBadge(item.visibility)}
          ${toolBadge(item.lifecycle, item.lifecycle === 'deprecated' ? 'warn' : 'default')}
          ${toolBadge(item.implementationStatus)}
        </div>
      </div>
      <div class="flex flex-wrap gap-3 text-[12px] text-[var(--text-muted)] mt-2">
        <span>카테고리: <strong class="text-[var(--text-body)]">${item.category}</strong></span>
        <span>모드: <strong class="text-[var(--text-body)]">${item.enabled_in_current_mode ? '활성' : '비활성'}</strong></span>
        <span>직접 호출: <strong class="text-[var(--text-body)]">${item.direct_call_allowed ? '허용' : '차단'}</strong></span>
        <span>권한: <strong class="text-[var(--text-body)]">${item.required_permission ?? '없음'}</strong></span>
      </div>
      ${item.reason
        ? html`<div class="tool-inventory-reason text-[12px] text-[var(--text-muted)] mt-1.5">${item.reason}</div>`
        : null}
      <div class="flex flex-wrap gap-3 text-[12px] text-[var(--text-muted)] mt-1.5">
        ${item.canonicalName ? html`<span>정식 이름: <strong class="text-[var(--text-body)]">${item.canonicalName}</strong></span>` : null}
        ${item.replacement ? html`<span>대체 도구: <strong class="text-[var(--text-body)]">${item.replacement}</strong></span>` : null}
        ${item.doc_refs.length > 0 ? html`<span>문서: <strong class="text-[var(--text-body)]">${item.doc_refs.join(', ')}</strong></span>` : null}
      </div>
    <//>
  `
}
