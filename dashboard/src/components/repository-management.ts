// Repository management surface -- registered repos, credentials, keeper access.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { RepoSidebar } from './repo-sidebar'
import { RepoDetailPanel } from './repo-detail-panel'
import { AddRepoDialog } from './add-repo-dialog'
import { CredentialSettings } from './credential-settings'
import { KeeperRepoMapping } from './keeper-repo-mapping'
import { GitBranch, KeyRound, ShieldCheck } from 'lucide-preact'

type RepositoryView = 'repos' | 'credentials' | 'mappings'

const activeView = signal<RepositoryView>('repos')

function viewButton(view: RepositoryView, label: string, icon: unknown) {
  const active = activeView.value === view
  return html`
    <button
      type="button"
      class="inline-flex h-8 items-center gap-2 rounded border px-3 text-xs font-semibold transition-colors cursor-pointer ${active
        ? 'border-accent/40 bg-accent/15 text-accent'
        : 'border-[var(--white-10)] bg-[var(--white-4)] text-text-muted hover:bg-[var(--white-8)] hover:text-text-body'}"
      aria-pressed=${active}
      onClick=${() => { activeView.value = view }}
    >
      ${icon}
      ${label}
    </button>
  `
}

export function RepositoryManagement() {
  const view = activeView.value

  return html`
    <div class="flex min-h-[calc(100vh-12rem)] flex-col gap-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="m-0 text-sm font-bold text-text-strong">저장소 운영</h2>
        </div>
        <div class="flex flex-wrap items-center gap-2" role="tablist" aria-label="저장소 운영 보기">
          ${viewButton('repos', '저장소', html`<${GitBranch} size=${14} aria-hidden="true" />`)}
          ${viewButton('credentials', 'Credentials', html`<${KeyRound} size=${14} aria-hidden="true" />`)}
          ${viewButton('mappings', 'Keeper 접근', html`<${ShieldCheck} size=${14} aria-hidden="true" />`)}
        </div>
      </div>

      ${view === 'repos' ? html`
        <div class="grid min-h-0 flex-1 grid-cols-[18rem_minmax(0,1fr)] overflow-hidden rounded border border-[var(--white-8)] bg-[var(--white-3)] max-[900px]:grid-cols-1">
          <div class="min-h-0 border-r border-[var(--white-8)] max-[900px]:border-r-0 max-[900px]:border-b">
            <${RepoSidebar} />
          </div>
          <div class="min-h-0 overflow-y-auto p-4">
            <${RepoDetailPanel} />
          </div>
        </div>
        <${AddRepoDialog} />
      ` : view === 'credentials' ? html`
        <div class="rounded border border-[var(--white-8)] bg-[var(--white-3)] p-4">
          <${CredentialSettings} />
        </div>
      ` : html`
        <div class="rounded border border-[var(--white-8)] bg-[var(--white-3)] p-4">
          <${KeeperRepoMapping} />
        </div>
      `}
    </div>
  `
}
