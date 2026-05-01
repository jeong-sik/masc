import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

import type { KeeperCompositeSnapshot } from '../api/keeper'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import {
  buildTurnFsmSpec,
  normalizeTurnFsmState,
  turnFsmTlaSymbol,
} from './keeper-fsm-specs'

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

export function terminalTone(outcome: string | null | undefined): 'neutral' | 'ok' | 'warn' | 'err' {
  switch (outcome) {
    case 'done':
    case 'skipped':
      return 'ok'
    case 'cancelled':
      return 'warn'
    case 'failed':
    case 'error':
      return 'err'
    default:
      return 'neutral'
  }
}

export function isExactTurnProjection(rawTurnPhase: string, projected: string | null): boolean {
  const normalized = rawTurnPhase.trim().toLowerCase()
  return normalized === projected || (normalized === 'awaiting_tool' && projected === 'awaiting_tool_result')
}

export function TurnFsmDetailPanel({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const spec = useMemo(
    () => buildTurnFsmSpec(snapshot.turn_phase),
    [snapshot.turn_phase],
  )
  const projectedState = normalizeTurnFsmState(snapshot.turn_phase)
  const tlaSymbol = projectedState ? turnFsmTlaSymbol(projectedState) : null
  const isCoarse = projectedState ? !isExactTurnProjection(snapshot.turn_phase, projectedState) : false
  const execution = snapshot.execution
  const terminalReason =
    execution?.terminal_reason_code
    ?? execution?.stop_reason
    ?? execution?.error?.kind
    ?? null

  return html`
    <section
      class="grid gap-3"
      role="region"
      aria-labelledby="turn-fsm-detail-title"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <div id="turn-fsm-detail-title" class="text-3xs font-semibold uppercase tracking-1 text-[var(--color-fg-muted)]">
            Turn FSM detail
          </div>
          <div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">
            keeper_turn_fsm projection from current composite turn_phase
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-1.5 text-3xs">
          <${StatusChip} tone=${turnFsmChipTone(projectedState ? 'accent' : 'warn')} uppercase=${false} class="font-mono">${projectedState ?? 'unmapped'}</${StatusChip}>
          <${StatusChip} tone="neutral" uppercase=${false} class="font-mono">KTC ${snapshot.turn_phase}</${StatusChip}>
          ${isCoarse ? html`
            <${StatusChip} tone="warn" uppercase=${false}>coarse legacy map</${StatusChip}>
          ` : null}
          ${tlaSymbol ? html`
            <${StatusChip} tone="neutral" uppercase=${false} class="font-mono">TLA ${tlaSymbol}</${StatusChip}>
          ` : null}
        </div>
      </div>

      <${CytoscapeFsm} spec=${spec} height="300px" />

      ${execution ? html`
        <div class="flex flex-wrap items-center gap-1.5 text-3xs" aria-label="latest turn receipt summary">
          <${StatusChip} tone=${turnFsmChipTone(terminalTone(execution.outcome))} uppercase=${false}>receipt ${execution.outcome ?? 'unknown'}</${StatusChip}>
          ${terminalReason ? html`
            <${StatusChip} tone=${turnFsmChipTone(terminalTone(execution.outcome))} uppercase=${false} class="font-mono">reason ${terminalReason}</${StatusChip}>
          ` : null}
          ${execution.tool_contract_result ? html`
            <${StatusChip} tone=${turnFsmChipTone(execution.tool_contract_result === 'violated' ? 'err' : 'neutral')} uppercase=${false} class="font-mono">tool ${execution.tool_contract_result}</${StatusChip}>
          ` : null}
          ${execution.model_used ? html`
            <${StatusChip} tone="neutral" uppercase=${false} class="font-mono">model ${execution.model_used}</${StatusChip}>
          ` : null}
        </div>
      ` : null}
    </section>
  `
}
