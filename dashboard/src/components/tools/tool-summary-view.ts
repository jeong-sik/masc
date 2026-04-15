// Summary view: top essential tools + never-used tools

import { html } from 'htm/preact'
import type { DashboardToolInventoryItem } from '../../api'
import { hasSurface, toolBadge } from './tool-state'

export function ToolSummaryView({ inventory }: { inventory: DashboardToolInventoryItem[] }) {
  const publicTools = inventory
    .filter(item => hasSurface(item, 'public_mcp'))
    .slice(0, 10)

  const hiddenDirectCall = inventory
    .filter(item => item.visibility === 'hidden' && item.direct_call_allowed)
    .slice(-5)
    .reverse()

  const visible = inventory.filter(item => item.visibility !== 'hidden')
  const hiddenCount = inventory.length - visible.length
  const visibleCount = visible.length
  const publicCount = inventory.filter(item => hasSurface(item, 'public_mcp')).length
  const directCallCount = inventory.filter(item => item.direct_call_allowed).length
  const deprecatedCount = visible.filter(item => item.lifecycle === 'deprecated').length

  return html`
    <div class="py-2">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3 my-4">
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${visibleCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">공개 도구</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${publicCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">MCP 공개</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${hiddenCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">내부 전용</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${directCallCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">직접 호출</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${deprecatedCount}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">폐기 예정</span>
        </div>
      </div>

      <div class="text-[12px] text-[var(--text-muted)] mb-4">
        숫자는 서로 다른 축을 본다. MCP 공개는 surface, 내부 전용은 visibility, 직접 호출은 direct-call 정책 기준이다.
      </div>

      ${publicTools.length > 0 ? html`
        <div class="mt-5">
          <h4 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-3">대표 MCP 공개 도구 (${publicTools.length}개)</h4>
          <div class="flex flex-col">
            ${publicTools.map(item => html`
              <div class="flex items-center gap-3 py-2.5 border-b border-[var(--white-4)] hover:bg-[var(--white-3)] transition-colors px-2 rounded" key=${item.name}>
                <span class="text-[13px] font-medium text-[var(--text-strong)] min-w-[180px] shrink-0">${item.name}</span>
                <span class="text-[12px] text-[var(--text-muted)] flex-1 overflow-hidden text-ellipsis whitespace-nowrap">${item.description?.slice(0, 60) ?? ''}</span>
                ${(item.surfaces ?? []).map(s => toolBadge(s, 'surface'))}
              </div>
            `)}
          </div>
        </div>
      ` : null}

      ${hiddenDirectCall.length > 0 ? html`
        <div class="mt-5">
          <h4 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-3">숨김이지만 직접 호출 가능한 도구 (${hiddenDirectCall.length}개)</h4>
          <div class="flex flex-col">
            ${hiddenDirectCall.map(item => html`
              <div class="flex items-center gap-3 py-2.5 border-b border-[var(--white-4)] hover:bg-[var(--white-3)] transition-colors px-2 rounded" key=${item.name}>
                <span class="text-[13px] font-medium text-[var(--text-strong)] min-w-[180px] shrink-0">${item.name}</span>
                <span class="text-[12px] text-[var(--text-muted)] flex-1 overflow-hidden text-ellipsis whitespace-nowrap">${item.description?.slice(0, 60) ?? ''}</span>
                ${toolBadge(item.visibility)}
              </div>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}
