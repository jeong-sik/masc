import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

import type { KeeperCompositeSnapshot } from '../api/keeper'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import {
  buildTurnFsmSpec,
  normalizeTurnFsmState,
  turnFsmTlaSymbol,
} from './keeper-fsm-specs'

function chipClass(tone: 'accent' | 'neutral' | 'warn' | 'err' | 'ok'): string {
  switch (tone) {
    case 'accent':
      return 'border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)]'
    case 'warn':
      return 'border-[var(--warn-24)] bg-[var(--warn-8)] text-[var(--color-status-warn)]'
    case 'err':
      return 'border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--color-status-err)]'
    case 'ok':
      return 'border-[rgba(34,197,94,0.24)] bg-[var(--emerald-8)] text-[var(--color-status-ok)]'
    case 'neutral':
    default:
      return 'border-[var(--white-8)] bg-[var(--white-4)] text-[var(--color-fg-muted)]'
  }
}

function terminalTone(outcome: string | null | undefined): 'neutral' | 'ok' | 'warn' | 'err' {
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

function isExactTurnProjection(rawTurnPhase: string, projected: string | null): boolean {
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
          <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 font-mono ${chipClass(projectedState ? 'accent' : 'warn')}`}>
            ${projectedState ?? 'unmapped'}
          </span>
          <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 font-mono ${chipClass('neutral')}`}>
            KTC ${snapshot.turn_phase}
          </span>
          ${isCoarse ? html`
            <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 ${chipClass('warn')}`}>
              coarse legacy map
            </span>
          ` : null}
          ${tlaSymbol ? html`
            <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 font-mono ${chipClass('neutral')}`}>
              TLA ${tlaSymbol}
            </span>
          ` : null}
        </div>
      </div>

      <${CytoscapeFsm} spec=${spec} height="300px" />

      ${execution ? html`
        <div class="flex flex-wrap items-center gap-1.5 text-3xs" aria-label="latest turn receipt summary">
          <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 ${chipClass(terminalTone(execution.outcome))}`}>
            receipt ${execution.outcome ?? 'unknown'}
          </span>
          ${terminalReason ? html`
            <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 font-mono ${chipClass(terminalTone(execution.outcome))}`}>
              reason ${terminalReason}
            </span>
          ` : null}
          ${execution.tool_contract_result ? html`
            <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 font-mono ${chipClass(execution.tool_contract_result === 'violated' ? 'err' : 'neutral')}`}>
              tool ${execution.tool_contract_result}
            </span>
          ` : null}
          ${execution.model_used ? html`
            <span class=${`inline-flex items-center rounded-sm border px-2 py-0.5 font-mono ${chipClass('neutral')}`}>
              model ${execution.model_used}
            </span>
          ` : null}
        </div>
      ` : null}
    </section>
  `
}
