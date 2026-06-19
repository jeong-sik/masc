import { html } from 'htm/preact'
import { useCallback, useEffect, useState } from 'preact/hooks'
import { ArrowLeft, RefreshCw, Sparkles } from 'lucide-preact'
import { fetchBoardCuration } from '../../api/board'
import type { BoardCurationSnapshot } from '../../types'
import { ActionButton } from '../common/button'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { SurfaceCard } from '../common/card'
import { TimeAgo } from '../common/time-ago'
import { MISSING_DATA_DASH } from '../../lib/format-string'
import { navigateBoard } from './board-route'

function percent(value: number | null | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return MISSING_DATA_DASH
  return `${Math.round(Math.max(0, Math.min(1, value)) * 100)}%`
}

function postIdList(ids: readonly string[]) {
  if (ids.length === 0) return null
  return html`
    <div class="flex flex-wrap gap-1.5">
      ${ids.map(id => html`
        <span key=${id} class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 font-mono text-2xs text-[var(--color-fg-secondary)]">${id}</span>
      `)}
    </div>
  `
}

function CurationSnapshot({ snapshot }: { snapshot: BoardCurationSnapshot }) {
  return html`
    <div class="grid gap-3">
      <${SurfaceCard} variant="compact">
        <div class="grid gap-3 lg:grid-cols-[1fr_auto] lg:items-start">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-secondary)]">
              <span class="font-mono">${snapshot.id}</span>
              <span>submitted by ${snapshot.submitted_by}</span>
              ${snapshot.model ? html`<span>${snapshot.model}</span>` : null}
            </div>
            ${snapshot.summary ? html`
              <p class="mt-2 text-sm leading-relaxed text-[var(--color-fg-primary)]">${snapshot.summary}</p>
            ` : null}
            ${snapshot.rationale ? html`
              <p class="mt-2 text-xs leading-relaxed text-[var(--color-fg-secondary)]">${snapshot.rationale}</p>
            ` : null}
          </div>
          <div class="grid gap-1 text-right text-2xs text-[var(--color-fg-secondary)]">
            <span class="text-lg font-bold tabular-nums text-[var(--color-fg-primary)]">${percent(snapshot.health_score)}</span>
            <span>health</span>
            <${TimeAgo} timestamp=${snapshot.generated_at} />
          </div>
        </div>
      <//>

      <div class="grid gap-3 lg:grid-cols-2">
        <${SurfaceCard} variant="compact">
          <h3 class="mb-2 text-xs font-bold uppercase text-[var(--color-fg-secondary)]">Recommended order</h3>
          ${snapshot.ordering.length > 0 ? postIdList(snapshot.ordering) : html`<span class="text-xs text-[var(--color-fg-disabled)]">No ordering</span>`}
        <//>
        <${SurfaceCard} variant="compact">
          <h3 class="mb-2 text-xs font-bold uppercase text-[var(--color-fg-secondary)]">Highlights</h3>
          ${snapshot.highlights.length > 0 ? postIdList(snapshot.highlights) : html`<span class="text-xs text-[var(--color-fg-disabled)]">No highlights</span>`}
        <//>
      </div>

      ${snapshot.tag_suggestions.length > 0 ? html`
        <${SurfaceCard} variant="compact">
          <h3 class="mb-2 text-xs font-bold uppercase text-[var(--color-fg-secondary)]">Tag suggestions</h3>
          <div class="grid gap-2">
            ${snapshot.tag_suggestions.map(item => html`
              <div key=${item.post_id} class="grid gap-1 border-b border-[var(--color-border-subtle)] pb-2 last:border-b-0 last:pb-0 v2-workspace-row">
                <div class="font-mono text-2xs text-[var(--color-fg-secondary)]">${item.post_id}</div>
                <div class="flex flex-wrap gap-1">${item.tags.map(tag => html`<span key=${tag} class="rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-2xs text-[var(--color-fg-primary)]">${tag}</span>`)}</div>
                ${item.rationale ? html`<p class="text-xs text-[var(--color-fg-secondary)]">${item.rationale}</p>` : null}
              </div>
            `)}
          </div>
        <//>
      ` : null}

      ${snapshot.answer_matches.length > 0 ? html`
        <${SurfaceCard} variant="compact">
          <h3 class="mb-2 text-xs font-bold uppercase text-[var(--color-fg-secondary)]">Answer matches</h3>
          <div class="grid gap-2">
            ${snapshot.answer_matches.map(item => html`
              <div key=${`${item.question_post_id}:${item.answer_post_id}`} class="grid gap-1 border-b border-[var(--color-border-subtle)] pb-2 last:border-b-0 last:pb-0 v2-workspace-row">
                <div class="flex flex-wrap items-center gap-2 font-mono text-2xs text-[var(--color-fg-secondary)]">
                  <span>${item.question_post_id}</span>
                  <span aria-hidden="true">-></span>
                  <span>${item.answer_post_id}</span>
                  <span class="tabular-nums">${percent(item.score)}</span>
                </div>
                ${item.rationale ? html`<p class="text-xs text-[var(--color-fg-secondary)]">${item.rationale}</p>` : null}
              </div>
            `)}
          </div>
        <//>
      ` : null}

      ${snapshot.health_components.length > 0 ? html`
        <${SurfaceCard} variant="compact">
          <h3 class="mb-2 text-xs font-bold uppercase text-[var(--color-fg-secondary)]">Health components</h3>
          <div class="grid gap-2">
            ${snapshot.health_components.map(item => html`
              <div key=${item.name} class="v2-workspace-row grid gap-1 border-b border-[var(--color-border-subtle)] pb-2 last:border-b-0 last:pb-0">
                <div class="flex items-center justify-between gap-2 text-xs">
                  <span class="font-bold text-[var(--color-fg-primary)]">${item.name}</span>
                  <span class="font-mono tabular-nums text-[var(--color-fg-secondary)]">${percent(item.score)} / weight ${item.weight}</span>
                </div>
                ${item.rationale ? html`<p class="text-xs text-[var(--color-fg-secondary)]">${item.rationale}</p>` : null}
              </div>
            `)}
          </div>
        <//>
      ` : null}
    </div>
  `
}

export function BoardCurationPanel() {
  const [snapshot, setSnapshot] = useState<BoardCurationSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setSnapshot(await fetchBoardCuration())
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load board curation')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  return html`
    <section class="v2-workspace-surface grid gap-4" aria-labelledby="board-curation-heading">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <div class="flex items-center gap-2 text-2xs uppercase text-[var(--color-fg-secondary)]">
            <${Sparkles} size=${13} aria-hidden="true" />
            Board curation
          </div>
          <h2 id="board-curation-heading" class="mt-1 text-xl font-bold text-[var(--color-fg-primary)]">AI curation snapshot</h2>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <${ActionButton} variant="ghost" size="sm" onClick=${() => navigateBoard()} ariaLabel="Back to board">
            <span class="inline-flex items-center gap-1.5"><${ArrowLeft} size=${14} aria-hidden="true" />Board<//>
          <//>
          <${ActionButton} variant="ghost" size="sm" onClick=${() => { void load() }} disabled=${loading} ariaLabel="Refresh board curation">
            <span class="inline-flex items-center gap-1.5"><${RefreshCw} size=${14} aria-hidden="true" />Refresh<//>
          <//>
        </div>
      </div>

      ${error && snapshot ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-status-err)]/40 bg-[var(--color-status-err)]/10 px-3 py-2 text-xs text-[var(--color-status-err)]" role="alert">${error}</div>
      ` : null}
      ${loading
        ? html`<${LoadingState}>Loading board curation...<//>`
        : error && !snapshot
          ? html`<${ErrorState} message=${error} />`
          : snapshot
            ? html`<${CurationSnapshot} snapshot=${snapshot} />`
            : html`<${EmptyState} message="No curation snapshot yet." compact />`}
    </section>
  `
}
