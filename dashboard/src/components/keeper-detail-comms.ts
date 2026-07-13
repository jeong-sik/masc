import { html } from 'htm/preact'
import { isKeeperOffline } from '../lib/keeper-predicates'
import { KeeperConversationPanel } from './keeper-shared'
import { PanelCard } from './common/panel-card'
import { SectionHeader } from './common/section-header'
import { MonoBadge } from './keeper-detail-history'
import { keeperStatusDetails } from '../keeper-state'
import { isRecord } from './common/normalize'
import type { Keeper } from '../types'

export function KeeperCommsPanel({ keeper }: { keeper: Keeper }) {
  // RFC-0139 PR-2: SSOT-routed offline check — see
  // keeper-store-normalize.ts for the parallel migration.
  const isOffline = isKeeperOffline(keeper)

  // The conversation panel stays mounted even while the keeper is
  // offline: a transient offline flip during a status poll used to
  // unmount the panel and drop the draft text and scroll position.
  // Past transcript stays readable; only new sends need a live keeper.
  return html`
    <div class="flex flex-col gap-3 v2-monitoring-surface">
      ${isOffline ? html`
        <div class="px-4 py-3 rounded-[var(--r-2)] border border-[var(--warn-20)] bg-[var(--warn-10)] text-sm text-[var(--color-status-warn)] v2-monitoring-panel">
          이 키퍼는 현재 비활동 상태입니다. 지난 대화는 그대로 볼 수 있으며, 새 메시지는 기동 후 전달됩니다.
        </div>
      ` : null}
      <div class="w-full">
        <${KeeperConversationPanel}
          keeperName=${keeper.name}
          placeholder=${'이 키퍼에게 직접 프롬프트 전송'}
          layout="primary"
        />
      </div>
    </div>
  `
}

// ── Playground Repos Panel ──────────────────────────────

interface PlaygroundRepo {
  name: string
  path?: string
  source?: string
  branch?: string
  latest_commit?: string
  shallow?: boolean
  last_action?: string
}

function isPlaygroundRepo(r: unknown): r is PlaygroundRepo {
  if (!isRecord(r)) return false
  const optionalString = (key: string) => r[key] === undefined || typeof r[key] === 'string'
  return typeof r.name === 'string'
    && optionalString('path')
    && optionalString('source')
    && optionalString('branch')
    && optionalString('latest_commit')
    && (r.shallow === undefined || typeof r.shallow === 'boolean')
    && optionalString('last_action')
}

interface PlaygroundPR {
  pr_url: string
  branch: string
  title: string
  draft: boolean
}

function isPlaygroundPR(r: unknown): r is PlaygroundPR {
  if (!isRecord(r)) return false
  return typeof r.pr_url === 'string'
    && typeof r.branch === 'string'
    && typeof r.title === 'string'
    && typeof r.draft === 'boolean'
}

interface PlaygroundWorktree {
  name: string
  path: string
}

function isPlaygroundWorktree(r: unknown): r is PlaygroundWorktree {
  if (!isRecord(r)) return false
  return typeof r.name === 'string' && typeof r.path === 'string'
}

export function PlaygroundReposPanel({ keeperName }: { keeperName: string }) {
  const detail = keeperStatusDetails.value[keeperName]
  if (!detail?.rawStatus) return null
  const raw = detail.rawStatus
  if (!isRecord(raw)) return null
  const execCtx = raw.execution_context
  if (!isRecord(execCtx)) return null

  const repos = (Array.isArray(execCtx.playground_repos) ? execCtx.playground_repos : []).filter(isPlaygroundRepo)
  const prs = (Array.isArray(execCtx.pr_history) ? execCtx.pr_history : []).filter(isPlaygroundPR)
  const worktrees = (Array.isArray(execCtx.active_worktrees) ? execCtx.active_worktrees : []).filter(isPlaygroundWorktree)

  if (repos.length === 0 && prs.length === 0 && worktrees.length === 0) return null

  return html`
    <${PanelCard} title="플레이그라운드">
      <div class="flex flex-col gap-3">
        ${repos.length > 0 ? html`
          <div>
            <${SectionHeader} size="xs" class="mb-1.5">저장소 (${repos.length})</${SectionHeader}>
            <div class="flex flex-col gap-1.5">
              ${repos.map(r => html`
                <div class="flex items-center gap-3 px-3 py-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-row">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="text-xs font-medium text-[var(--color-fg-secondary)] truncate">${r.name}</span>
                      <${MonoBadge}>${r.branch?.trim() || 'branch unavailable'}</${MonoBadge}>
                      ${r.shallow === true ? html`<span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] bg-[var(--warn-10)] text-[var(--color-status-warn)] border border-[var(--warn-20)]">shallow</span>` : null}
                    </div>
                    <div class="text-3xs text-[var(--color-fg-muted)] font-mono mt-0.5 truncate">${r.latest_commit?.trim() || 'Git metadata unavailable'}</div>
                    ${r.path ? html`<div class="text-3xs text-[var(--color-fg-disabled)] font-mono mt-0.5 truncate">${r.path}</div>` : null}
                  </div>
                  <span class="text-3xs text-[var(--color-fg-disabled)] flex-shrink-0">${r.last_action?.trim() || r.source?.trim() || 'observed'}</span>
                </div>
              `)}
            </div>
          </div>
        ` : null}

        ${prs.length > 0 ? html`
          <div>
            <${SectionHeader} size="xs" class="mb-1.5">PRs (${prs.length})</${SectionHeader}>
            <div class="flex flex-col gap-1.5">
              ${prs.map(pr => html`
                <div class="flex items-center gap-2 px-3 py-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-row">
                  <span class="text-xs text-[var(--color-fg-secondary)] truncate flex-1">${pr.title}</span>
                  <${MonoBadge}>${pr.branch}</${MonoBadge}>
                  ${pr.draft ? html`<span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] bg-[var(--warn-10)] text-[var(--color-status-warn)] border border-[var(--warn-20)]">draft</span>` : null}
                  <a href=${pr.pr_url} target="_blank" rel="noopener" class="v2-mobile-operator-target inline-flex items-center text-3xs text-[var(--color-accent-fg)] hover:underline flex-shrink-0">PR</a>
                </div>
              `)}
            </div>
          </div>
        ` : null}

        ${worktrees.length > 0 ? html`
          <div>
            <${SectionHeader} size="xs" class="mb-1.5">워크트리 (${worktrees.length})</${SectionHeader}>
            <div class="flex flex-wrap gap-1.5">
              ${worktrees.map(w => html`
                <span class="text-3xs font-mono px-2 py-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]" title=${w.path}>${w.name}</span>
              `)}
            </div>
          </div>
        ` : null}
      </div>
    <//>
  `
}
