/**
 * CompositeFsmFlowchart (LT-16e)
 *
 * Static Mermaid rendering of the 5 orthogonal keeper FSM axes from
 * KeeperCompositeLifecycle.tla, side by side. Each subgraph is one
 * region (Harel parallel region); the subgraphs do not share edges
 * because the axes are orthogonal by design — the invariants that
 * tie them together live in the matrix's top strip (LT-16b) and in
 * the masc_keeper_invariant_violations_total counter (LT-13).
 *
 * The transitions below are hand-extracted from
 * COMPOSITE_FSM_TLA_SPEC_PATHS.
 *
 * Only the common-case edges are rendered — a full enumeration of
 * every guarded transition would be unreadable and is what the TLA+
 * model-checker is for. Operators read this diagram to build a
 * mental model, not to exhaustively validate the state machine.
 */

import { html } from 'htm/preact'

import { MermaidGraph } from './common/mermaid-graph'

export const COMPOSITE_FSM_TLA_SPEC_PATHS = [
  'specs/keeper-state-machine/KeeperStateMachine.tla',
  'specs/keeper-state-machine/KeeperTurnCycle.tla',
  'specs/keeper-state-machine/KeeperDecisionPipeline.tla',
] as const

// Every node ID carries an axis prefix so Mermaid's global-id rule
// does not collapse e.g. two "idle" nodes (KTC and KCL both have one).
// Labels displayed to the operator stay bare for readability.
const MERMAID_COMPOSITE: string = `flowchart TB
  %% ─ KSM (Lifecycle) ─────────────────────────────────────
  subgraph KSM ["라이프사이클 · KSM"]
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
  subgraph KTC ["턴 · KTC"]
    direction LR
    ktc_idle["idle"] --> ktc_prompting["prompting"]
    ktc_prompting --> ktc_executing["executing"]
    ktc_executing --> ktc_compacting["compacting"]
    ktc_executing --> ktc_finalizing["finalizing"]
    ktc_compacting --> ktc_finalizing
    ktc_finalizing --> ktc_idle
  end

  %% ─ KDP (Decision pipeline, 3 states) ───────────────────
  subgraph KDP ["결정 · KDP"]
    direction LR
    kdp_undecided["undecided"] --> kdp_guard_ok["guard_ok"]
    kdp_guard_ok --> kdp_tool_policy["tool_policy_selected"]
  end

  %% ─ KCL (Runtime lifecycle, 5 states) ───────────────────
  subgraph KCL ["Runtime · KCL"]
    direction LR
    kcl_idle["idle"] --> kcl_selecting["selecting"]
    kcl_selecting --> kcl_trying["trying"]
    kcl_trying --> kcl_selecting
    kcl_trying --> kcl_done["done"]
    kcl_trying --> kcl_exhausted["exhausted"]
  end

  %% ─ KMC (Memory compaction, 3 states) ───────────────────
  subgraph KMC ["압축 · KMC"]
    direction LR
    kmc_accumulating["accumulating"] --> kmc_compacting["compacting"]
    kmc_compacting --> kmc_done["done"]
    kmc_done --> kmc_accumulating
  end

  %% Mermaid classDef parser does not support CSS var() — values must be
  %% literal CSS color tokens. Hex literals below mirror the design-system
  %% tokens 1:1 (--rose-light=#fb7185, --ok-fg=#8ebc8e, --amber-bright=#f59e0b).
  %% If those tokens change, sync this block and the snapshot test.
  classDef terminal fill:#1f0f0f,stroke:#7f1d1d,color:#fb7185
  classDef stable   fill:#0f1a0f,stroke:#166534,color:#8ebc8e
  classDef motion   fill:#1a1305,stroke:#a16207,color:#f59e0b
  classDef error    fill:#1e0a0a,stroke:#b91c1c,color:#fb7185

  class ksm_stopped,ksm_dead terminal
  class ksm_running,ksm_paused,ktc_idle,kcl_idle,kmc_accumulating stable
  class ksm_compacting,ksm_handingoff,ksm_overflowed,ksm_draining,ksm_restarting,ktc_prompting,ktc_executing,ktc_compacting,ktc_finalizing,kcl_selecting,kcl_trying,kmc_compacting motion
  class ksm_failing,ksm_crashed,kcl_exhausted error
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
      class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] contain-content ${props.class ?? ''}"
      aria-label="복합 FSM 플로우차트"
    >
      <header class="border-b border-[var(--color-border-default)] p-3">
        <h2 class="text-sm font-semibold text-[var(--color-fg-muted)]">
          복합 FSM 플로우차트 (TLA+ spec)
        </h2>
        <p class="mt-1 text-xs text-[var(--color-fg-muted)]">
          6 개의 직교 축을 Harel parallel region 으로 렌더링합니다. 출처:
          <code class="text-[var(--color-fg-muted)]">specs/keeper-state-machine/*.tla</code>.
          여기 표시된 transition 은 common-case edge 이고, exhaustive enumeration 은
          TLA+ model checker 가 담당합니다.
        </p>
      </header>
      <div class="p-3">
        <${MermaidGraph}
          source=${MERMAID_COMPOSITE}
          prefix="composite-fsm"
          minHeightClass="min-h-80"
          fallbackText="플로우차트 렌더 실패 — 브라우저 콘솔을 확인하세요."
        />
      </div>
    </section>
  `
}
