// Single inventory row component

import { html } from 'htm/preact'
import type { DashboardToolInventoryItem } from '../../api'
import { toolBadge } from './tool-state'

export function InventoryRow({ item }: { item: DashboardToolInventoryItem }) {
  const categoryLabel = item.category === 'uncategorized' ? '미분류' : item.category
  const categoryHint = item.category === 'uncategorized' ? ' (서버 미지정)' : ''

  return html`
    <article class="p-4 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
      <div class="flex justify-between gap-3 items-start">
        <div>
          <div class="text-[15px] font-bold text-[var(--text-strong)]">${item.name}</div>
          <div class="tool-inventory-desc text-[12px] text-[var(--text-muted)] mt-0.5">${item.description}</div>
        </div>
        <div class="flex flex-wrap gap-1.5 justify-end">
          ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
          ${toolBadge(item.visibility)}
          ${toolBadge(item.lifecycle, item.lifecycle === 'deprecated' ? 'warn' : 'default')}
          ${toolBadge(item.implementationStatus)}
        </div>
      </div>
      <div class="flex flex-wrap gap-3 text-[12px] text-[var(--text-muted)] mt-2">
        <span>카테고리: <strong class="text-[var(--text-body)]">${categoryLabel}${categoryHint}</strong></span>
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
    </article>
  `
}
