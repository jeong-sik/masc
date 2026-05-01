// Repository management surface -- registered repos, credentials, keeper access.

import { html } from 'htm/preact'
import { RepoSidebar } from './repo-sidebar'
import { RepoDetailPanel } from './repo-detail-panel'
import { AddRepoDialog } from './add-repo-dialog'
import { CredentialSettings } from './credential-settings'
import { KeeperRepoMapping } from './keeper-repo-mapping'
import { GitBranch, GitFork, KeyRound, ShieldCheck } from 'lucide-preact'
import { replaceRoute, route } from '../router'
import { GitGraphPanel } from './git-graph-panel'

type RepositoryView = 'repos' | 'graph' | 'credentials' | 'mappings'

const REPOSITORY_VIEWS: RepositoryView[] = ['repos', 'graph', 'credentials', 'mappings']

function currentView(): RepositoryView {
  const view = route.value.params.view
  return view && (REPOSITORY_VIEWS as string[]).includes(view) ? view as RepositoryView : 'repos'
}

function updateViewParam(view: RepositoryView): void {
  replaceRoute(
    'workspace',
    view === 'repos'
      ? { section: 'repositories' }
      : { section: 'repositories', view },
  )
}

function viewButton(view: RepositoryView, label: string, icon: unknown) {
  const active = currentView() === view
  return html`
    <button
      type="button"
      class="inline-flex h-8 items-center gap-2 rounded border px-3 text-xs font-semibold transition-colors cursor-pointer ${active
        ? 'border-accent/40 bg-accent/15 text-accent'
        : 'border-[var(--white-10)] bg-[var(--white-4)] text-text-muted hover:bg-[var(--white-8)] hover:text-text-body'}"
      aria-pressed=${active}
      onClick=${() => { updateViewParam(view) }}
    >
      ${icon}
      ${label}
    </button>
  `
}

export function RepositoryManagement() {
  const view = currentView()

  return html`
    <div class="flex min-h-[calc(100vh-12rem)] flex-col gap-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="m-0 text-sm font-bold text-text-strong">저장소 운영</h2>
        </div>
        <div class="flex flex-wrap items-center gap-2" role="tablist" aria-label="저장소 운영 보기">
          ${viewButton('repos', '저장소', html`<${GitBranch} size=${14} aria-hidden="true" />`)}
          ${viewButton('graph', 'Git 그래프', html`<${GitFork} size=${14} aria-hidden="true" />`)}
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
      ` : view === 'graph' ? html`
        <${GitGraphPanel} />
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
