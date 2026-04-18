/**
 * CompositeFsmFlowchart (LT-16e + LT-16-KCB Phase 3)
 *
 * Static Mermaid rendering of the 6 orthogonal keeper FSM axes from
 * KeeperCompositeLifecycle.tla, side by side. Each subgraph is one
 * region (Harel parallel region); the subgraphs do not share edges
 * because the axes are orthogonal by design — the invariants that
 * tie them together live in the matrix's top strip (LT-16b) and in
 * the masc_keeper_invariant_violations_total counter (LT-13).
 *
 * Design: docs/observability/composite-fsm-matrix-design.md (LT-12)
 * covers the "순서도까지 맵핑" ("map the flowcharts") portion of the
 * user's brief — this panel is the flowchart companion to the matrix.
 *
 * The transitions below are hand-extracted from:
 *   specs/keeper-state-machine/KeeperStateMachine.tla
 *   specs/keeper-state-machine/KeeperTurnCycle.tla
 *   specs/keeper-state-machine/KeeperDecisionPipeline.tla
 *   specs/keeper-state-machine/KeeperCascadeLifecycle.tla
 *   specs/keeper-state-machine/KeeperCompactionLifecycle.tla
 *
 * Only the common-case edges are rendered — a full enumeration of
 * every guarded transition would be unreadable and is what the TLA+
 * model-checker is for. Operators read this diagram to build a
 * mental model, not to exhaustively validate the state machine.
 */

import { html } from 'htm/preact'

import { MermaidGraph } from './common/mermaid-graph'

// Every node ID carries an axis prefix so Mermaid's global-id rule
// does not collapse e.g. two "idle" nodes (KTC and KCL both have one).
// Labels displayed to the operator stay bare for readability.
const MERMAID_COMPOSITE: string = `flowchart TB
  %% ─ KSM (Lifecycle, 12 states) ──────────────────────────
  subgraph KSM ["Lifecycle · KSM"]
    direction LR
    ksm_offline["Offline"] --> ksm_running["Running"]
    ksm_running --> ksm_failing["Failing"]
    ksm_failing --> ksm_running
    ksm_running --> ksm_overflowed["Overflowed"]
    ksm_overflowed --> ksm_compacting["Compacting"]
    ksm_compacting --> ksm_running
    ksm_running --> ksm_handingoff["HandingOff"]
    ksm_handingoff --> ksm_running
    ksm_running --> ksm_paused["Paused"]
    ksm_paused --> ksm_running
    ksm_running --> ksm_draining["Draining"]
    ksm_draining --> ksm_stopped["Stopped"]
    ksm_stopped --> ksm_dead["Dead"]
    ksm_running --> ksm_crashed["Crashed"]
    ksm_crashed --> ksm_restarting["Restarting"]
    ksm_restarting --> ksm_running
    ksm_restarting --> ksm_dead
  end

  %% ─ KTC (Turn cycle, 5 states) ──────────────────────────
  subgraph KTC ["Turn · KTC"]
    direction LR
    ktc_idle["idle"] --> ktc_prompting["prompting"]
    ktc_prompting --> ktc_executing["executing"]
    ktc_executing --> ktc_compacting["compacting"]
    ktc_executing --> ktc_finalizing["finalizing"]
    ktc_compacting --> ktc_finalizing
    ktc_finalizing --> ktc_idle
  end

  %% ─ KDP (Decision pipeline, 4 states) ───────────────────
  subgraph KDP ["Decision · KDP"]
    direction LR
    kdp_undecided["undecided"] --> kdp_guard_ok["guard_ok"]
    kdp_undecided --> kdp_gate_rejected["gate_rejected"]
    kdp_guard_ok --> kdp_tool_policy["tool_policy_selected"]
  end

  %% ─ KCL (Cascade lifecycle, 5 states) ───────────────────
  subgraph KCL ["Cascade · KCL"]
    direction LR
    kcl_idle["idle"] --> kcl_selecting["selecting"]
    kcl_selecting --> kcl_trying["trying"]
    kcl_trying --> kcl_selecting
    kcl_trying --> kcl_done["done"]
    kcl_trying --> kcl_exhausted["exhausted"]
  end

  %% ─ KMC (Memory compaction, 3 states) ───────────────────
  subgraph KMC ["Compaction · KMC"]
    direction LR
    kmc_accumulating["accumulating"] --> kmc_compacting["compacting"]
    kmc_compacting --> kmc_done["done"]
    kmc_done --> kmc_accumulating
  end

  %% ─ KCB (Circuit breaker, 3 observable states) ──────────
  %% Tripped is deliberately absent — see display_state.mli: the
  %% mutator resets consecutive_count on trip, so no snapshot taken
  %% between tool calls can observe Tripped. The dashed arrow is a
  %% reminder that the unobservable transition exists inside the
  %% counter's read-modify-write, not that it's a state we render.
  subgraph KCB ["Circuit breaker · KCB"]
    direction LR
    kcb_clean["clean"] --> kcb_warning["warning"]
    kcb_warning --> kcb_clean
    kcb_warning -.-> kcb_cooling["cooling"]
    kcb_cooling --> kcb_warning
    kcb_cooling --> kcb_clean
  end

  classDef terminal fill:#1f0f0f,stroke:#7f1d1d,color:#fca5a5
  classDef stable   fill:#0f1a0f,stroke:#166534,color:#86efac
  classDef motion   fill:#1a1305,stroke:#a16207,color:var(--yellow-100)
  classDef error    fill:#1e0a0a,stroke:#b91c1c,color:#fca5a5

  class ksm_stopped,ksm_dead terminal
  class ksm_running,ksm_paused,ktc_idle,kcl_idle,kmc_accumulating,kcb_clean stable
  class ksm_compacting,ksm_handingoff,ksm_overflowed,ksm_draining,ksm_restarting,ktc_prompting,ktc_executing,ktc_compacting,ktc_finalizing,kcl_selecting,kcl_trying,kmc_compacting,kcb_warning motion
  class ksm_failing,ksm_crashed,kdp_gate_rejected,kcl_exhausted error
  class kcb_cooling motion
`

/**
 * Return the Mermaid source for the composite FSM panel. Exposed as a
 * pure function so a test can regex-check invariants (every axis
 * present, every axis has a subgraph header, no bare-id collisions)
 * without mounting a renderer.
 */
export function buildCompositeFsmMermaid(): string {
  return MERMAID_COMPOSITE
}

interface CompositeFsmFlowchartProps {
  class?: string
}

export function CompositeFsmFlowchart(props: CompositeFsmFlowchartProps = {}) {
  return html`
    <section
      data-testid="composite-fsm-flowchart"
      class="rounded border border-[var(--white-10)] bg-[var(--white-5)] ${props.class ?? ''}"
    >
      <header class="border-b border-[var(--white-10)] p-3">
        <h2 class="text-sm font-semibold text-[var(--text-muted)]">
          Composite FSM flowchart (TLA+ spec)
        </h2>
        <p class="mt-1 text-xs text-[var(--text-muted)]">
          6 orthogonal axes rendered as Harel parallel regions. Source:
          <code class="text-[var(--text-muted)]">specs/keeper-state-machine/*.tla</code>.
          Transitions here are the common-case edges; the TLA+
          model-checker owns the exhaustive enumeration.
        </p>
      </header>
      <div class="p-3">
        <${MermaidGraph}
          source=${MERMAID_COMPOSITE}
          prefix="composite-fsm"
          minHeightClass="min-h-[320px]"
          fallbackText="Flowchart render failed — see browser console."
        />
      </div>
    </section>
  `
}
