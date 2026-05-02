import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { GitBranch, RefreshCw } from 'lucide-preact'
import { EmptyState, ErrorRecoverable, LoadingState } from './common/feedback-state'
import { ActionButton } from './common/button'
import { TimeAgo } from './common/time-ago'
import { GitGraphView } from './git-graph-view'
import {
  cancelGitGraphRefresh,
  gitGraphResource,
  refreshGitGraph,
} from './git-graph-store'

function StatCell({ label, value }: { label: string; value: number }) {
  return html`
    <div class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-3)] px-3 py-2">
      <div class="text-2xs font-medium uppercase tracking-[0.16em] text-[var(--color-fg-muted)]">${label}</div>
      <div class="mt-1 text-xl font-semibold tabular-nums text-[var(--color-fg-primary)]">${value}</div>
    </div>
  `
}

export function GitGraphPanel() {
  const state = gitGraphResource.state.value
  const graph = state.data

  useEffect(() => {
    void refreshGitGraph()
    const timer = window.setInterval(() => {
      void refreshGitGraph()
    }, 10000)
    return () => {
      window.clearInterval(timer)
      cancelGitGraphRefresh()
    }
  }, [])

  if (!graph && state.loading) {
    return html`<${LoadingState}>Git graph 불러오는 중...<//>`
  }

  if (!graph && state.error) {
    return html`
      <${ErrorRecoverable}
        title="Git graph snapshot을 불러오지 못했습니다."
        detail=${state.error}
        onRetry=${() => { void refreshGitGraph() }}
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
          <div class="mb-1 flex items-center gap-2 text-2xs font-semibold uppercase tracking-[0.16em] text-[var(--color-fg-muted)]">
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
        <div class="flex shrink-0 items-center gap-3">
          <span class="text-2xs text-[var(--color-fg-muted)]">
            갱신 <${TimeAgo} timestamp=${graph.generated_at} />
          </span>
          <${ActionButton}
            variant="ghost"
            size="sm"
            disabled=${state.loading}
            ariaBusy=${state.loading}
            onClick=${() => { void refreshGitGraph() }}
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
          onRetry=${() => { void refreshGitGraph() }}
        />
      ` : null}

      <div class="grid gap-2 sm:grid-cols-3 lg:grid-cols-6">
        <${StatCell} label="Repos" value=${graph.stats.repo_count} />
        <${StatCell} label="Worktrees" value=${graph.stats.agent_count} />
        <${StatCell} label="Branches" value=${graph.stats.branch_count} />
        <${StatCell} label="Commits" value=${graph.stats.commit_count} />
        <${StatCell} label="Dirty" value=${graph.stats.dirty_count} />
        <${StatCell} label="Conflicts" value=${graph.stats.conflict_count} />
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
