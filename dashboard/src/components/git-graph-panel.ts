import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { GitBranch, RefreshCw } from 'lucide-preact'
import { EmptyState, ErrorRecoverable, LoadingState } from './common/feedback-state'
import { ActionButton } from './common/button'
import { TimeAgo } from './common/time-ago'
import { GitGraphView } from './git-graph-view'
import { StatTile } from './common/stat-tile'
import { fetchRepositoriesList, type Repository } from '../api/repositories'
import {
  cancelGitGraphRefresh,
  gitGraphResource,
  refreshGitGraph,
} from './git-graph-store'

export function GitGraphPanel() {
  const state = gitGraphResource.state.value
  const graph = state.data
  const [repositories, setRepositories] = useState<ReadonlyArray<Repository>>([])
  const [selectedRepoId, setSelectedRepoId] = useState<string | null>(null)
  const [repositoryError, setRepositoryError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    fetchRepositoriesList()
      .then(repos => {
        if (cancelled) return
        setRepositories(repos)
        setRepositoryError(null)
        setSelectedRepoId(current => current ?? repos[0]?.id ?? null)
      })
      .catch(err => {
        if (cancelled) return
        setRepositoryError(err instanceof Error ? err.message : 'repository list failed')
      })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    void refreshGitGraph(selectedRepoId)
    const timer = window.setInterval(() => {
      void refreshGitGraph(selectedRepoId)
    }, 10000)
    return () => {
      window.clearInterval(timer)
      cancelGitGraphRefresh()
    }
  }, [selectedRepoId])

  if (!graph && state.loading) {
    return html`<${LoadingState}>Git graph 불러오는 중...<//>`
  }

  if (!graph && state.error) {
    return html`
      <${ErrorRecoverable}
        title="Git graph snapshot을 불러오지 못했습니다."
        detail=${state.error}
        onRetry=${() => { void refreshGitGraph(selectedRepoId) }}
      />
    `
  }

  if (!graph || graph.repos.length === 0) {
    return html`
      <${EmptyState}
        icon="⑂"
        message=${graph?.warnings[0] ?? 'Git repository snapshot이 없습니다.'}
      />
    `
  }

  const repo = graph.repos[0]

  return html`
    <section class="grid gap-4" data-testid="git-graph-panel">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="mb-1 flex items-center gap-2 text-2xs font-semibold uppercase tracking-[var(--track-section)] text-[var(--color-fg-muted)]">
            <${GitBranch} size=${14} aria-hidden="true" />
            Track 4
          </div>
          <h2 class="m-0 text-xl font-semibold tracking-normal text-[var(--color-fg-primary)]">
            ${repo?.label ?? 'Git graph'}
          </h2>
          <p class="mt-1 max-w-3xl text-sm leading-relaxed text-[var(--color-fg-muted)]">
            ${repo?.root ?? ''}
          </p>
        </div>
        <div class="flex shrink-0 flex-wrap items-center justify-end gap-3">
          ${repositories.length > 0 ? html`
            <label class="flex items-center gap-2 text-2xs font-semibold uppercase tracking-[var(--track-section)] text-[var(--color-fg-muted)]">
              Repo
              <select
                aria-label="Git graph repository"
                class="h-8 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 text-xs font-semibold normal-case tracking-normal text-[var(--color-fg-primary)]"
                value=${selectedRepoId ?? repositories[0]?.id ?? ''}
                onChange=${(event: Event) => {
                  const next = (event.currentTarget as HTMLSelectElement).value
                  setSelectedRepoId(next || null)
                }}
              >
                ${repositories.map(repository => html`
                  <option key=${repository.id} value=${repository.id}>
                    ${repository.name} · ${repository.local_path}
                  </option>
                `)}
              </select>
            </label>
          ` : null}
          <span class="text-2xs text-[var(--color-fg-muted)]">
            갱신 <${TimeAgo} timestamp=${graph.generated_at} />
          </span>
          <${ActionButton}
            variant="ghost"
            size="sm"
            disabled=${state.loading}
            ariaBusy=${state.loading}
            onClick=${() => { void refreshGitGraph(selectedRepoId) }}
          >
            <span class="inline-flex items-center gap-1">
              <${RefreshCw} size=${13} aria-hidden="true" />
              새로고침
            </span>
          <//>
        </div>
      </div>

      ${state.error ? html`
        <${ErrorRecoverable}
          title="마지막 자동 갱신이 실패했습니다. 현재 화면은 직전 snapshot입니다."
          detail=${state.error}
          onRetry=${() => { void refreshGitGraph(selectedRepoId) }}
        />
      ` : null}

      ${repositoryError ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-soft)] px-3 py-2 text-sm text-[var(--warn-bright)]">
          Repository 설정을 불러오지 못해 base path graph로 fallback: ${repositoryError}
        </div>
      ` : null}

      <div class="grid gap-2 sm:grid-cols-3 lg:grid-cols-6">
        <${StatTile} label="Repos" value=${String(graph.stats.repo_count)} />
        <${StatTile} label="Worktrees" value=${String(graph.stats.agent_count)} />
        <${StatTile} label="Branches" value=${String(graph.stats.branch_count)} />
        <${StatTile} label="Commits" value=${String(graph.stats.commit_count)} />
        <${StatTile}
          label="Dirty"
          value=${String(graph.stats.dirty_count)}
          status=${graph.stats.dirty_count > 0 ? 'warn' : undefined}
          delta=${graph.stats.dirty_count > 0 ? { direction: 'flat' as const, text: '미커밋' } : undefined}
        />
        <${StatTile}
          label="Conflicts"
          value=${String(graph.stats.conflict_count)}
          status=${graph.stats.conflict_count > 0 ? 'crit' : undefined}
          delta=${graph.stats.conflict_count > 0 ? { direction: 'down' as const, text: '해결 필요' } : undefined}
        />
      </div>

      ${graph.warnings.length > 0 ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-soft)] px-3 py-2 text-sm text-[var(--warn-bright)]">
          ${graph.warnings[0]}
        </div>
      ` : null}

      <${GitGraphView} graph=${graph} />
    </section>
  `
}
