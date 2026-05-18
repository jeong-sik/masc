import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

import type { KeeperCompositeSnapshot } from '../api/keeper'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { displayState } from './fsm-hub-types'
import {
  buildTurnFsmSpec,
  normalizeTurnFsmState,
} from './keeper-fsm-specs'
import { normalizeStopCause } from '../lib/stop-cause'

type TurnChipTone = 'accent' | 'neutral' | 'warn' | 'err' | 'ok'

export function turnFsmChipTone(tone: TurnChipTone): StatusChipTone {
  switch (tone) {
    case 'accent':
      return 'info'
    case 'warn':
      return 'warn'
    case 'err':
      return 'bad'
    case 'ok':
      return 'ok'
    case 'neutral':
    default:
      return 'neutral'
  }
}

// `execution.outcome` wire format on the composite snapshot is the
// TLA-prefix form emitted by `outcome_kind_to_tla_receipt`
// (lib/keeper/keeper_execution_receipt.ml:24-29):
//   `Ok        -> "receipt_done"
//   `Skipped   -> "receipt_skipped"
//   `Error     -> "receipt_failed"
//   `Cancelled -> "receipt_cancelled"
// The TLA ReceiptIsAuthoritative invariant fixes this canonical form
// (keeper_execution_receipt.ml:54-58). The prior branches used short
// forms the backend never emits on this field, so every receipt tone
// fell through to 'neutral' regardless of actual outcome.
export function terminalTone(outcome: string | null | undefined): 'neutral' | 'ok' | 'warn' | 'err' {
  switch (outcome) {
    case 'receipt_done':
    case 'receipt_skipped':
      return 'ok'
    case 'receipt_cancelled':
      return 'warn'
    case 'receipt_failed':
      return 'err'
    default:
      return 'neutral'
  }
}

export function TurnFsmDetailPanel({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const spec = useMemo(
    () => buildTurnFsmSpec(snapshot.turn_phase),
    [snapshot.turn_phase],
  )
  const projectedState = normalizeTurnFsmState(snapshot.turn_phase)
  const execution = snapshot.execution
  const stopCause = execution
    ? normalizeStopCause({
        terminal_reason_code: execution.terminal_reason_code,
        stop_reason: execution.stop_reason,
        error_kind: execution.error?.kind,
      })
    : null

  return html`
    <section
      class="grid gap-3"
      role="region"
      aria-labelledby="turn-fsm-detail-title"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <div id="turn-fsm-detail-title" class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
            Turn FSM detail
          </div>
          <div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">
            keeper_turn_fsm projection from current composite turn_phase
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-1.5 text-3xs">
          <${StatusChip} tone=${turnFsmChipTone(projectedState ? 'accent' : 'warn')} uppercase=${false} class="font-mono">${projectedState ? displayState(projectedState) : 'unmapped'}</${StatusChip}>
        </div>
      </div>

      <${CytoscapeFsm} spec=${spec} height="300px" />

      ${execution ? html`
        <div class="flex flex-wrap items-center gap-1.5 text-3xs" aria-label="latest turn receipt summary">
          <${StatusChip} tone=${turnFsmChipTone(terminalTone(execution.outcome))} uppercase=${false}>receipt ${execution.outcome ?? 'unknown'}</${StatusChip}>
          ${stopCause ? html`
            <${StatusChip} tone=${turnFsmChipTone(terminalTone(execution.outcome))} uppercase=${false} class="font-mono" title=${stopCause.source}>reason ${stopCause.code}</${StatusChip}>
          ` : null}
          ${execution.tool_contract_result ? html`
            <${StatusChip} tone=${turnFsmChipTone(execution.tool_contract_result === 'violated' ? 'err' : 'neutral')} uppercase=${false} class="font-mono">tool ${execution.tool_contract_result}</${StatusChip}>
          ` : null}
        </div>
      ` : null}
    </section>
  `
}
