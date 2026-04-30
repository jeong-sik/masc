// Branch tree -- visual tree/list of branches for a repository.
// Used inside repo-detail-panel.

import { html } from 'htm/preact'

export interface BranchTreeProps {
  repository_id: string
  branches: readonly string[]
  default_branch?: string
}

function BranchIcon({ isDefault }: { isDefault: boolean }) {
  if (isDefault) {
    return html`
      <svg class="w-3.5 h-3.5 text-ok shrink-0" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
        <path d="M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0zm3.5 6.5L7 11l-2.5-2.5 1-1L7 9l3.5-3.5 1 1z"/>
      </svg>
    `
  }
  return html`
    <svg class="w-3.5 h-3.5 text-text-muted shrink-0" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
      <path d="M11 5.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zm0 1a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7zM5 5.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zm0 1a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7zM5 9a1 1 0 0 1 1-1h.5a1 1 0 0 1 .9.6l.5 1.2.5-1.2a1 1 0 0 1 .9-.6h.5a1 1 0 0 1 1 1v4.5a.5.5 0 0 1-1 0V10h-.3l-.7 1.7a.5.5 0 0 1-.9 0L7.3 10H7v3.5a.5.5 0 0 1-1 0V9z"/>
    </svg>
  `
}

export function BranchTree({ repository_id, branches, default_branch }: BranchTreeProps) {
  if (branches.length === 0) {
    return html`
      <div class="py-4 text-center text-2xs text-text-muted" role="status">
        브랜치가 없습니다.
      </div>
    `
  }

  const sorted = [...branches].sort((a, b) => {
    // Default branch first, then alphabetical
    if (a === default_branch) return -1
    if (b === default_branch) return 1
    return a.localeCompare(b)
  })

  return html`
    <div class="rounded border border-card-border/50 bg-card/20 backdrop-blur-sm overflow-hidden" data-repo-id="${repository_id}">
      <div class="px-3 py-2 border-b border-card-border/30 bg-card/40">
        <div class="flex items-center justify-between">
          <span class="text-2xs font-semibold uppercase tracking-wider text-text-muted">브랜치</span>
          <span class="text-3xs text-text-dim">${branches.length}개</span>
        </div>
      </div>
      <ul class="divide-y divide-card-border/20" role="list">
        ${sorted.map(branch => {
          const isDefault = branch === default_branch
          return html`
            <li
              class="flex items-center gap-2.5 py-2 px-3 hover:bg-card/40 transition-colors"
              role="listitem"
            >
              <${BranchIcon} isDefault=${isDefault} />
              <span class="text-xs font-medium ${isDefault ? 'text-ok' : 'text-text-body'} truncate">
                ${branch}
              </span>
              ${isDefault
                ? html`<span class="text-3xs font-bold px-1.5 py-0.5 rounded bg-ok/10 text-ok border border-ok/20 shrink-0">기본</span>`
                : null}
            </li>
          `
        })}
      </ul>
    </div>
  `
}
