// keeper-v2 design FSM lifeline molecule — FsmLifeline from
// prototypes/keeper-v2/molecules.jsx: the keeper machine as a vertical
// lifeline of done/current/upcoming pips.
//
// Live wiring: turnFsmLifelineSteps derives the step states from the backend
// turn phase via the canonical TURN_FSM_STATES order + normalizeTurnFsmState
// (keeper-fsm-specs.ts), so "done" only marks phases the turn already passed
// in the canonical order.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { TURN_FSM_STATES, normalizeTurnFsmState } from '../keeper-fsm-specs'

export interface FsmLifelineStep {
  label: string
  state: 'done' | 'cur' | ''
}

export function MoleculeFsmLifeline({ steps }: { steps: FsmLifelineStep[] }): VNode {
  return html`
    <div class="fsm">
      ${steps.map((s, i) => html`
        <div key=${i} class="fsm-step ${s.state}"><span class="pip"></span>${s.label}</div>
      `)}
    </div>
  `
}

/** Derive lifeline steps from a raw backend turn phase. Returns null when the
 *  phase is unknown/absent — the host should render the not_observed treatment
 *  instead of an all-upcoming lifeline that claims nothing has run. */
export function turnFsmLifelineSteps(turnPhase: string | null | undefined): FsmLifelineStep[] | null {
  const cur = normalizeTurnFsmState(turnPhase)
  if (!cur) return null
  const curIdx = TURN_FSM_STATES.indexOf(cur)
  return TURN_FSM_STATES.map((state, i) => ({
    label: state,
    state: i < curIdx ? 'done' : i === curIdx ? 'cur' : '',
  }))
}
