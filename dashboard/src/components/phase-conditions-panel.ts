import { html } from 'htm/preact'

import {
  asBoolean,
  asInt,
  asRecordArray,
  asString,
  isRecord,
} from './common/normalize'
import { StatusChip } from './common/status-chip'

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
    return 'border-[var(--ok-border)] bg-[var(--ok-soft)] text-[var(--color-fg-primary)]'
  }
  return 'border-[var(--color-border-default)] bg-[var(--white-3)] text-[var(--color-fg-disabled)]'
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
          <div id="phase-conditions-title" class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
            Phase conditions
          </div>
          <div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">
            derive_phase priority order; first true condition determines the phase
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-1.5 text-3xs">
          ${diagnosis.currentPhase ? html`
            <${StatusChip} tone="neutral" uppercase=${false} class="font-mono">current ${diagnosis.currentPhase}</${StatusChip}>
          ` : null}
          ${diagnosis.derivedPhase ? html`
            <${StatusChip} tone="info" uppercase=${false} class="font-mono">derived ${diagnosis.derivedPhase}</${StatusChip}>
          ` : null}
          <${StatusChip} tone=${executableTone} uppercase=${false}>
            turn ${diagnosis.canExecuteTurn === null ? 'unknown' : diagnosis.canExecuteTurn ? 'executable' : 'blocked'}
          </${StatusChip}>
        </div>
      </div>

      <ol class="grid gap-1.5" role="list" aria-label="phase condition priority order">
        ${diagnosis.rows.map(row => html`
          <li
            key=${row.key}
            class=${`rounded-[var(--r-1)] border px-3 py-2 text-2xs leading-normal ${rowClass(row)}`}
            aria-current=${row.determining ? 'step' : undefined}
          >
            <div class="flex flex-wrap items-center gap-2">
              <${StatusChip} tone="neutral" uppercase=${false} class="min-w-7 justify-center font-mono tabular-nums">P${row.priority}</${StatusChip}>
              <span class="font-semibold">${row.label}</span>
              <span class="font-mono text-[var(--color-fg-muted)]">→ ${row.phase}</span>
              <${StatusChip} tone=${row.value ? 'ok' : 'neutral'} uppercase=${false} class="font-mono">${row.value ? 'true' : 'false'}</${StatusChip}>
              ${row.determining ? html`
                <${StatusChip} tone="info" uppercase=${false}>determining</${StatusChip}>
              ` : null}
            </div>
          </li>
        `)}
      </ol>
    </section>
  `
}
