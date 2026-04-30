import { html } from 'htm/preact'

import {
  asBoolean,
  asInt,
  asRecordArray,
  asString,
  isRecord,
} from './common/normalize'

export interface PhaseConditionRow {
  key: string
  label: string
  priority: number
  value: boolean
  phase: string
  determining: boolean
}

export interface PhaseDiagnosis {
  currentPhase: string | null
  derivedPhase: string | null
  canExecuteTurn: boolean | null
  determiningCondition: string | null
  rows: PhaseConditionRow[]
}

export function normalizePhaseDiagnosis(input: unknown): PhaseDiagnosis | null {
  if (!isRecord(input)) return null
  const rowRecords = asRecordArray(input.rows)
  if (rowRecords.length === 0) return null

  const determiningCondition = asString(input.determining_condition) ?? null
  const rows = rowRecords
    .map((row, index): PhaseConditionRow => {
      const key = asString(row.key) ?? `condition_${index + 1}`
      const priority = asInt(row.priority) ?? index + 1
      const determining = asBoolean(row.determining) ?? key === determiningCondition
      return {
        key,
        label: asString(row.label) ?? key,
        priority,
        value: asBoolean(row.value, false),
        phase: asString(row.phase) ?? 'unknown',
        determining,
      }
    })
    .sort((left, right) => left.priority - right.priority)

  return {
    currentPhase: asString(input.current_phase) ?? null,
    derivedPhase: asString(input.derived_phase) ?? null,
    canExecuteTurn: asBoolean(input.can_execute_turn) ?? null,
    determiningCondition,
    rows,
  }
}

function rowClass(row: PhaseConditionRow): string {
  if (row.determining) {
    return 'border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-fg-primary)]'
  }
  if (row.value) {
    return 'border-[rgba(34,197,94,0.24)] bg-[var(--emerald-8)] text-[var(--color-fg-primary)]'
  }
  return 'border-[var(--white-8)] bg-[var(--white-3)] text-[var(--color-fg-disabled)]'
}

function chipClass(tone: 'accent' | 'neutral' | 'ok' | 'warn'): string {
  switch (tone) {
    case 'accent':
      return 'border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)]'
    case 'ok':
      return 'border-[rgba(34,197,94,0.24)] bg-[var(--emerald-8)] text-[var(--color-status-ok)]'
    case 'warn':
      return 'border-[var(--warn-24)] bg-[var(--warn-8)] text-[var(--color-status-warn)]'
    case 'neutral':
    default:
      return 'border-[var(--white-8)] bg-[var(--white-4)] text-[var(--color-fg-muted)]'
  }
}

export function PhaseConditionsPanel({ diagnosis }: { diagnosis: PhaseDiagnosis }) {
  const executableTone = diagnosis.canExecuteTurn === true
    ? 'ok'
    : diagnosis.canExecuteTurn === false
      ? 'warn'
      : 'neutral'

  return html`
    <section
      class="grid gap-3"
      role="region"
      aria-labelledby="phase-conditions-title"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <div id="phase-conditions-title" class="text-3xs font-semibold uppercase tracking-1 text-[var(--color-fg-muted)]">
            Phase conditions
          </div>
          <div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">
            derive_phase priority order; first true condition determines the phase
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-1.5 text-3xs">
          ${diagnosis.currentPhase ? html`
            <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 font-mono ${chipClass('neutral')}`}>
              current ${diagnosis.currentPhase}
            </span>
          ` : null}
          ${diagnosis.derivedPhase ? html`
            <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 font-mono ${chipClass('accent')}`}>
              derived ${diagnosis.derivedPhase}
            </span>
          ` : null}
          <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 ${chipClass(executableTone)}`}>
            turn ${diagnosis.canExecuteTurn === null ? 'unknown' : diagnosis.canExecuteTurn ? 'executable' : 'blocked'}
          </span>
        </div>
      </div>

      <ol class="grid gap-1.5" role="list" aria-label="phase condition priority order">
        ${diagnosis.rows.map(row => html`
          <li
            key=${row.key}
            class=${`rounded border px-3 py-2 text-2xs leading-normal ${rowClass(row)}`}
            aria-current=${row.determining ? 'step' : undefined}
          >
            <div class="flex flex-wrap items-center gap-2">
              <span class="inline-flex min-w-7 items-center justify-center rounded-sm border border-[var(--white-8)] bg-[var(--white-4)] px-1.5 py-0.5 font-mono text-3xs tabular-nums">
                P${row.priority}
              </span>
              <span class="font-semibold">${row.label}</span>
              <span class="font-mono text-[var(--color-fg-muted)]">→ ${row.phase}</span>
              <span class=${`rounded-sm border px-1.5 py-0.5 font-mono text-3xs ${chipClass(row.value ? 'ok' : 'neutral')}`}>
                ${row.value ? 'true' : 'false'}
              </span>
              ${row.determining ? html`
                <span class=${`rounded-sm border px-1.5 py-0.5 text-3xs ${chipClass('accent')}`}>
                  determining
                </span>
              ` : null}
            </div>
          </li>
        `)}
      </ol>
    </section>
  `
}
