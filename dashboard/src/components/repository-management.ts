// Repository management surface -- registered repos.

import { html } from 'htm/preact'
import { RepoSidebar } from './repo-sidebar'
import { RepoDetailPanel } from './repo-detail-panel'
import { AddRepoDialog } from './add-repo-dialog'

// The "Keeper 접근" tab is gone with keeper_repo_mappings: it let an operator
// save which repositories a keeper may use, and nothing read the answer.
// Provisioning discovers checkouts by walking the playground
// (Keeper_playground_checkouts.discover) and never consulted the mapping, so
// the screen described an access control that did not exist.

export function RepositoryManagement() {
  return html`
    <div class="v2-workspace-surface flex min-h-[calc(100vh-12rem)] flex-col gap-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="m-0 text-sm font-bold text-text-strong">저장소 운영</h2>
        </div>
      </div>

      <div class="v2-workspace-panel grid min-h-0 flex-1 grid-cols-[18rem_minmax(0,1fr)] overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] max-[900px]:grid-cols-1">
        <div class="min-h-0 border-r border-[var(--color-border-default)] max-[900px]:border-r-0 max-[900px]:border-b">
          <${RepoSidebar} />
        </div>
        <div class="min-h-0 overflow-y-auto p-4">
          <${RepoDetailPanel} />
        </div>
      </div>
      <${AddRepoDialog} />
    </div>
  `
}
