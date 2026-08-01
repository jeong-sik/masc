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

// ── Repository Checkouts Panel ──────────────────────────

type CatalogState = 'registered' | 'unregistered' | 'ambiguous' | 'unavailable' | 'origin_unavailable'
type FreshnessState = 'current' | 'ahead' | 'behind' | 'diverged' | 'unavailable'

interface CatalogProjection {
  state: CatalogState | 'unsupported'
  rawState: string | null
  repositoryId: string | null
}

interface FreshnessProjection {
  state: FreshnessState | 'unsupported'
  rawState: string | null
  behind: number | null
  ahead: number | null
}

interface RepositoryCheckout {
  checkout_name: string
  path: string
  branch: string | null
  head: string | null
  dirty: boolean | null
  inspection_state: string
  catalog: CatalogProjection
  freshness: FreshnessProjection
}

const CATALOG_STATES = new Set<CatalogState>([
  'registered', 'unregistered', 'ambiguous', 'unavailable', 'origin_unavailable',
])
const FRESHNESS_STATES = new Set<FreshnessState>([
  'current', 'ahead', 'behind', 'diverged', 'unavailable',
])

function parseCatalogProjection(value: unknown): CatalogProjection {
  const rawState = isRecord(value) && typeof value.state === 'string' ? value.state : null
  return {
    state: rawState !== null && CATALOG_STATES.has(rawState as CatalogState)
      ? rawState as CatalogState
      : 'unsupported',
    rawState,
    repositoryId: isRecord(value) && typeof value.repository_id === 'string'
      ? value.repository_id
      : null,
  }
}

function parseFreshnessProjection(value: unknown): FreshnessProjection {
  const rawState = isRecord(value) && typeof value.state === 'string' ? value.state : null
  return {
    state: rawState !== null && FRESHNESS_STATES.has(rawState as FreshnessState)
      ? rawState as FreshnessState
      : 'unsupported',
    rawState,
    behind: isRecord(value) && typeof value.behind === 'number' ? value.behind : null,
    ahead: isRecord(value) && typeof value.ahead === 'number' ? value.ahead : null,
  }
}

function parseRepositoryCheckout(r: unknown): RepositoryCheckout | null {
  if (!isRecord(r)) return null
  if (!(typeof r.checkout_name === 'string'
    && typeof r.path === 'string'
    && (r.branch === null || typeof r.branch === 'string')
    && (r.head === null || typeof r.head === 'string')
    && (r.dirty === null || typeof r.dirty === 'boolean')
    && typeof r.inspection_state === 'string'
    && isRecord(r.catalog)
    && isRecord(r.freshness))) return null
  return {
    checkout_name: r.checkout_name,
    path: r.path,
    branch: r.branch,
    head: r.head,
    dirty: r.dirty,
    inspection_state: r.inspection_state,
    catalog: parseCatalogProjection(r.catalog),
    freshness: parseFreshnessProjection(r.freshness),
  }
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

export function RepositoryCheckoutsPanel({ keeperName }: { keeperName: string }) {
  const detail = keeperStatusDetails.value[keeperName]
  if (!detail?.rawStatus) return null
  const raw = detail.rawStatus
  if (!isRecord(raw)) return null
  const execCtx = raw.execution_context
  if (!isRecord(execCtx)) return null

  const checkoutProjection = execCtx.repository_checkouts
  const checkouts = isRecord(checkoutProjection) && Array.isArray(checkoutProjection.entries)
    ? checkoutProjection.entries
      .map(parseRepositoryCheckout)
      .filter((checkout): checkout is RepositoryCheckout => checkout !== null)
    : []
  const prs = (Array.isArray(execCtx.pr_history) ? execCtx.pr_history : []).filter(isPlaygroundPR)
  const worktrees = (Array.isArray(execCtx.active_worktrees) ? execCtx.active_worktrees : []).filter(isPlaygroundWorktree)

  if (checkouts.length === 0 && prs.length === 0 && worktrees.length === 0) return null

  return html`
    <${PanelCard} title="저장소 작업">
      <div class="flex flex-col gap-3">
        ${checkouts.length > 0 ? html`
          <div>
            <${SectionHeader} size="xs" class="mb-1.5">체크아웃 (${checkouts.length})</${SectionHeader}>
            <div class="flex flex-col gap-1.5">
              ${checkouts.map(checkout => {
                const freshnessState = checkout.freshness.state === 'unsupported'
                  ? `unsupported:${checkout.freshness.rawState ?? 'malformed'}`
                  : checkout.freshness.state
                const catalogState = checkout.catalog.state === 'unsupported'
                  ? `unsupported:${checkout.catalog.rawState ?? 'malformed'}`
                  : checkout.catalog.state
                const behind = checkout.freshness.behind
                const ahead = checkout.freshness.ahead
                const repositoryId = checkout.catalog.repositoryId
                return html`
                <div class="flex items-center gap-3 px-3 py-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-row">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="text-xs font-medium text-[var(--color-fg-secondary)] truncate">${checkout.checkout_name}</span>
                      <${MonoBadge}>${checkout.branch?.trim() || 'branch unavailable'}</${MonoBadge}>
                      ${checkout.dirty === true ? html`<span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] bg-[var(--warn-10)] text-[var(--color-status-warn)] border border-[var(--warn-20)]">dirty</span>` : null}
                      <span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] border border-[var(--color-border-default)]">${catalogState}</span>
                      <span class="text-3xs px-1 py-0.5 rounded-[var(--r-1)] border border-[var(--color-border-default)]">${freshnessState}</span>
                    </div>
                    <div class="text-3xs text-[var(--color-fg-muted)] font-mono mt-0.5 truncate">${checkout.head?.trim() || 'Git metadata unavailable'}</div>
                    <div class="text-3xs text-[var(--color-fg-disabled)] font-mono mt-0.5 truncate">${checkout.path}${repositoryId ? ` · ${repositoryId}` : ''}</div>
                  </div>
                  <span class="text-3xs text-[var(--color-fg-disabled)] flex-shrink-0">${behind === null || ahead === null ? checkout.inspection_state : `behind ${behind} · ahead ${ahead}`}</span>
                </div>
              `})}
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
