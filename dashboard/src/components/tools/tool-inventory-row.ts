// Single inventory row component

import { html } from 'htm/preact'
import { useId, useState } from 'preact/hooks'
import type { DashboardToolInventoryItem } from '../../api'
import { toolBadge } from './tool-state'

export function InventoryRow({ item }: { item: DashboardToolInventoryItem }) {
  const [descriptionExpanded, setDescriptionExpanded] = useState(false)
  const descriptionId = useId()
  const categoryLabel = item.category === 'uncategorized' ? '미분류' : item.category
  const categoryHint = item.category === 'uncategorized' ? ' (서버 미지정)' : ''

  return html`
    <article class="v2-lab-card p-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
      <div class="flex flex-col gap-2 sm:flex-row sm:justify-between sm:gap-3 sm:items-start">
        <div class="min-w-0 flex-1 break-words">
          <div class="text-md font-bold text-[var(--color-fg-secondary)]">${item.name}</div>
        </div>
        <div class="flex flex-wrap gap-1.5 sm:justify-end">
          ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
          ${toolBadge(item.visibility)}
          ${toolBadge(item.lifecycle, item.lifecycle === 'deprecated' ? 'warn' : 'default')}
          ${toolBadge(item.implementationStatus)}
        </div>
      </div>
      ${item.description !== '' ? html`
        <div id=${descriptionId}
          class=${`${descriptionExpanded ? 'whitespace-pre-wrap' : 'tool-inventory-desc'} break-words text-xs text-[var(--color-fg-muted)] mt-2`}>${item.description}</div>
        <button type="button"
          class="v2-lab-action min-h-11 mt-1 text-xs focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--color-accent)]"
          aria-expanded=${descriptionExpanded}
          aria-controls=${descriptionId}
          aria-label=${`${item.name} 설명 ${descriptionExpanded ? '접기' : '펼치기'}`}
          onClick=${() => setDescriptionExpanded(expanded => !expanded)}>
          ${descriptionExpanded ? '설명 접기' : '설명 전체 보기'}
        </button>
      ` : null}
      <div class="flex flex-wrap gap-3 text-xs text-[var(--color-fg-muted)] mt-2">
        <span>카테고리: <strong class="text-[var(--color-fg-primary)]">${categoryLabel}${categoryHint}</strong></span>
        <span>직접 호출: <strong class="text-[var(--color-fg-primary)]">${item.direct_call_allowed ? '허용' : '차단'}</strong></span>
        <span>권한: <strong class="text-[var(--color-fg-primary)]">${item.required_permission ?? '없음'}</strong></span>
      </div>
      ${item.reason
        ? html`<div class="tool-inventory-reason text-xs text-[var(--color-fg-muted)] mt-1.5">${item.reason}</div>`
        : null}
      <div class="flex flex-wrap gap-3 text-xs text-[var(--color-fg-muted)] mt-1.5">
        ${item.canonicalName ? html`<span>정식 이름: <strong class="text-[var(--color-fg-primary)]">${item.canonicalName}</strong></span>` : null}
        ${item.replacement ? html`<span>대체 도구: <strong class="text-[var(--color-fg-primary)]">${item.replacement}</strong></span>` : null}
        ${item.doc_refs.length > 0 ? html`<span>문서: <strong class="text-[var(--color-fg-primary)]">${item.doc_refs.join(', ')}</strong></span>` : null}
      </div>
    </article>
  `
}
