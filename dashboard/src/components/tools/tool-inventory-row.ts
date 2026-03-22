// Single inventory row component

import { html } from 'htm/preact'
import type { DashboardToolInventoryItem } from '../../api'
import { toolBadge } from './tool-state'

export function InventoryRow({ item }: { item: DashboardToolInventoryItem }) {
  return html`
    <article class="flex flex-col gap-2.5 p-4 rounded-2xl bg-[rgba(15,23,42,0.72)] border border-[rgba(148,163,184,0.16)]">
      <div class="flex justify-between gap-3 items-start">
        <div>
          <div class="text-[length:var(--fs-lg)] font-bold text-[color:var(--text-near-white)]">${item.name}</div>
          <div class="tool-inventory-desc">${item.description}</div>
        </div>
        <div class="flex flex-wrap gap-1.5 justify-end">
          ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
          ${toolBadge(item.tier, item.tier === 'essential' ? 'ok' : item.tier === 'standard' ? 'warn' : 'default')}
          ${toolBadge(item.visibility)}
          ${toolBadge(item.lifecycle, item.lifecycle === 'deprecated' ? 'warn' : 'default')}
          ${toolBadge(item.implementationStatus)}
        </div>
      </div>
      <div class="flex flex-wrap gap-3 text-[length:var(--fs-sm)] text-[color:var(--text-slate)]">
        <span>카테고리: <strong class="text-[color:var(--text-slate-light)]">${item.category}</strong></span>
        <span>모드: <strong class="text-[color:var(--text-slate-light)]">${item.enabled_in_current_mode ? '활성' : '비활성'}</strong></span>
        <span>직접 호출: <strong class="text-[color:var(--text-slate-light)]">${item.direct_call_allowed ? '허용' : '차단'}</strong></span>
        <span>권한: <strong class="text-[color:var(--text-slate-light)]">${item.required_permission ?? '없음'}</strong></span>
      </div>
      ${item.reason
        ? html`<div class="tool-inventory-reason">${item.reason}</div>`
        : null}
      <div class="flex flex-wrap gap-3 text-[length:var(--fs-sm)] text-[color:var(--text-slate)]">
        ${item.canonicalName ? html`<span>정식 이름: <strong class="text-[color:var(--text-slate-light)]">${item.canonicalName}</strong></span>` : null}
        ${item.replacement ? html`<span>대체 도구: <strong class="text-[color:var(--text-slate-light)]">${item.replacement}</strong></span>` : null}
        ${item.doc_refs.length > 0 ? html`<span>문서: <strong class="text-[color:var(--text-slate-light)]">${item.doc_refs.join(', ')}</strong></span>` : null}
      </div>
    </article>
  `
}
