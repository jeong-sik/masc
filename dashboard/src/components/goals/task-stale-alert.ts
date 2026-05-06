// MASC Dashboard — G2 · Stale-claim alert variant
//
// Phase 2 spec (`design-system/preview/cb-group-d.jsx:TaskStaleAlert`)
// surfaces tasks whose claim has gone cold so the operator can nudge,
// force-release, or reassign. Backend `Task` does not expose
// `claim_age` directly, but the audit
// (`design-system/audits/2026-04-29-phase2-implementation-gap.md`)
// authorises a frontend derivation: any task in `claimed` or
// `in_progress` whose `updated_at` is older than the stale threshold.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { tasks } from '../../store'
import { navigate } from '../../router'
import type { Task } from '../../types'

// 30 minutes in seconds. Matches the spec's "claim_age ends in `h` or
// > 10 minutes" rule of thumb but lifted slightly to avoid noise on
// fast-iterating tasks. Keep this as a named constant — `feedback_no-hyperparameter-as-env-knob`.
const STALE_THRESHOLD_SECONDS = 30 * 60

interface StaleEntry {
  task: Task
  ageSeconds: number
  label: string
}

function ageSeconds(task: Task): number | null {
  const ref = task.updated_at ?? task.created_at
  if (!ref) return null
  const ts = Date.parse(ref)
  if (Number.isNaN(ts)) return null
  return Math.max(0, Math.floor((Date.now() - ts) / 1000))
}

function ageLabel(s: number): string {
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

const staleEntries = computed<StaleEntry[]>(() => {
  const acc: StaleEntry[] = []
  for (const t of tasks.value) {
    if (t.status !== 'claimed' && t.status !== 'in_progress') continue
    const age = ageSeconds(t)
    if (age == null || age < STALE_THRESHOLD_SECONDS) continue
    acc.push({ task: t, ageSeconds: age, label: ageLabel(age) })
  }
  acc.sort((a, b) => b.ageSeconds - a.ageSeconds)
  return acc
})

export function TaskStaleAlert() {
  const entries = staleEntries.value
  if (entries.length === 0) return null

  return html`
    <section
      class="rounded-[var(--r-1)] border border-warn/30 bg-warn/5 p-3"
      aria-label="오래된 태스크 점유"
      aria-live="polite"
    >
      <header class="mb-2 flex items-baseline justify-between gap-2">
        <h3 class="text-xs font-semibold uppercase tracking-[var(--track-caps)] text-warn">
          오래 점유 중인 태스크 (${entries.length})
        </h3>
        <span class="text-2xs text-text-muted">
          updated_at 이 ${Math.floor(STALE_THRESHOLD_SECONDS / 60)}분 이상 묶여 있는 claim
        </span>
      </header>
      <ul class="flex flex-col gap-1.5">
        ${entries.map(e => html`
          <li
            key=${e.task.id}
            class="flex flex-wrap items-center gap-2 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1.5 text-xs"
          >
            <button
              type="button"
              class="font-mono text-text-strong hover:underline"
              title=${e.task.id}
              aria-label=${`태스크 상세 열기: ${e.task.id} ${e.task.title}`}
              onClick=${() => navigate('workspace', { section: 'planning', task: e.task.id })}
            >
              ${e.task.id.slice(0, 12)}
            </button>
            <span class="grow truncate">${e.task.title}</span>
            ${e.task.assignee ? html`
              <span class="text-text-muted">@${e.task.assignee}</span>
            ` : null}
            <span class="rounded-[var(--r-1)] border border-warn/40 bg-warn/10 px-1.5 py-0.5 text-2xs text-warn">
              ${e.label}
            </span>
            <div class="flex gap-1">
              ${e.task.assignee ? html`
                <button
                  type="button"
                  class="rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-2xs text-accent-fg hover:bg-[var(--accent-15)]"
                  title="해당 키퍼 상세로 이동해 직접 nudge"
                  aria-label=${`${e.task.assignee} 키퍼 상세에서 ${e.task.id} nudge`}
                  onClick=${() => e.task.assignee && navigate('monitoring', { section: 'agents', view: 'keepers', keeper: e.task.assignee })}
                >
                  nudge
                </button>
              ` : null}
              <button
                type="button"
                class="rounded-[var(--r-1)] border border-text-muted/30 px-2 py-0.5 text-2xs text-text-muted hover:bg-[var(--color-bg-panel-alt)]"
                title="태스크 상세 패널 열기"
                aria-label=${`태스크 상세 패널 열기: ${e.task.id}`}
                onClick=${() => navigate('workspace', { section: 'planning', task: e.task.id })}
              >
                상세
              </button>
            </div>
          </li>
        `)}
      </ul>
    </section>
  `
}
