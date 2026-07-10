// MASC Dashboard — G2 · Per-keeper task wall variant
//
// Phase 2 spec (`design-system/preview/cb-group-d.jsx:TaskWall`)
// renders an N-column grid keyed by keeper, with each cell holding the
// task chips for that keeper. Production has the data (`Task.assignee`)
// but no surface that flattens it into a wall view; per-keeper filtering
// today only surfaces inside `KeeperToolActivity` strips.
//
// `cancelled` and `done` tasks are excluded — the wall is meant to show
// what each keeper is *currently* responsible for, not historical load.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { tasks } from '../../store'
import { navigate } from '../../router'
import type { Task } from '../../types'
import { sortByPriority } from './goal-helpers'

interface KeeperColumn {
  keeper: string
  tasks: Task[]
}

const UNASSIGNED = '__unassigned__'

function statusGlyph(status: Task['status']): string {
  switch (status) {
    case 'todo': return '·'
    case 'claimed': return '◔'
    case 'in_progress': return '◑'
    case 'awaiting_verification': return '⋯'
    default: return '·'
  }
}

function keeperLabel(keeper: string): string {
  return keeper === UNASSIGNED ? '미할당' : keeper
}

const wallColumns = computed<KeeperColumn[]>(() => {
  const grouped = new Map<string, Task[]>()
  for (const t of tasks.value) {
    if (t.status === 'done' || t.status === 'cancelled') continue
    const key = t.assignee?.trim() || UNASSIGNED
    let bucket = grouped.get(key)
    if (!bucket) {
      bucket = []
      grouped.set(key, bucket)
    }
    bucket.push(t)
  }
  for (const list of grouped.values()) {
    list.sort(sortByPriority)
  }
  const cols: KeeperColumn[] = []
  for (const [keeper, list] of grouped.entries()) {
    cols.push({ keeper, tasks: list })
  }
  cols.sort((a, b) => {
    if (a.keeper === UNASSIGNED) return 1
    if (b.keeper === UNASSIGNED) return -1
    return b.tasks.length - a.tasks.length
  })
  return cols
})

export function TaskWall() {
  const cols = wallColumns.value
  if (cols.length === 0) return null

  return html`
    <section
      class="v2-workspace-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      aria-label="키퍼별 태스크 월"
    >
      <header class="v2-workspace-toolbar mb-2 flex items-baseline justify-between">
        <h3 class="text-xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">
          키퍼별 태스크 월
        </h3>
        <span class="text-2xs text-text-muted">
          ${cols.length} 키퍼 · 진행 중 ${cols.reduce((s, c) => s + c.tasks.length, 0)} 건
        </span>
      </header>
      <div class="grid gap-2 [grid-template-columns:repeat(auto-fit,minmax(180px,1fr))]">
        ${cols.map(col => html`
          <div
            key=${col.keeper}
            class="v2-workspace-card flex flex-col gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-2"
            aria-label=${`${keeperLabel(col.keeper)} 태스크 ${col.tasks.length}건`}
          >
            <div class="flex items-baseline justify-between gap-1 text-2xs">
              <span class="font-mono ${col.keeper === UNASSIGNED ? 'text-text-disabled' : 'text-text-strong'}">
                ${keeperLabel(col.keeper)}
              </span>
              <span class="text-text-muted">${col.tasks.length}</span>
            </div>
            <ul class="flex flex-col gap-0.5">
              ${col.tasks.map(t => html`
                <li key=${t.id} class="v2-workspace-row">
                  <button
                    type="button"
                    class="v2-workspace-action flex w-full items-center gap-1.5 rounded-[var(--r-0)] border border-[var(--color-border-default)]/50 bg-[var(--color-bg-surface)] px-1.5 py-0.5 text-left text-2xs hover:border-[var(--accent-40)] hover:bg-[var(--accent-10)]"
                    title=${`${t.id} · ${t.status ?? 'unknown'}`}
                    aria-label=${`태스크 ${t.id} 열기: ${t.title}`}
                    onClick=${() => navigate('workspace', { section: 'planning', task: t.id })}
                  >
                    <span aria-hidden="true" class="text-text-muted">${statusGlyph(t.status)}</span>
                    <span class="font-mono text-text-disabled">${t.id.slice(0, 6)}</span>
                    <span class="grow truncate">${t.title}</span>
                  </button>
                </li>
              `)}
            </ul>
          </div>
        `)}
      </div>
    </section>
  `
}
