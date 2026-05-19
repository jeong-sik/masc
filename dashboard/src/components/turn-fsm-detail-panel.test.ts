// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { render } from "preact"
import { html } from "htm/preact"
import {
  terminalTone,
  TurnFsmDetailPanel,
  turnFsmChipTone,
} from "./turn-fsm-detail-panel"
import type { KeeperCompositeSnapshot } from "../api/keeper"

vi.mock("./common/cytoscape-fsm", () => ({
  CytoscapeFsm: () => html`<div data-testid="fsm-graph"></div>`,
}))

function keeperCompositeSnapshot(
  overrides: Partial<KeeperCompositeSnapshot> = {},
): KeeperCompositeSnapshot {
  const base: KeeperCompositeSnapshot = {
    correlation_id: "keeper-1:run-1",
    run_id: "run-1",
    ts: 0,
    phase: "Running",
    turn_phase: "idle",
    decision: { stage: "undecided" },
    cascade: { state: "idle" },
    compaction: { stage: "accumulating" },
    measurement: { captured: false },
    invariants: {
      phase_turn_alignment: true,
      no_cascade_before_measurement: true,
      compaction_atomicity: true,
      event_priority_monotone: true,
      phase_derivation_agreement: true,
    },
    fsm_guard_violations: 0,
    is_live: false,
    last_outcome: null,
    recommended_actions: [],
  }

  return {
    ...base,
    ...overrides,
    decision: { ...base.decision, ...(overrides.decision ?? {}) },
    cascade: { ...base.cascade, ...(overrides.cascade ?? {}) },
    compaction: { ...base.compaction, ...(overrides.compaction ?? {}) },
    measurement: { ...base.measurement, ...(overrides.measurement ?? {}) },
    invariants: { ...base.invariants, ...(overrides.invariants ?? {}) },
  }
}

describe("turnFsmChipTone", () => {
  it.each([
    ["accent", "info"],
    ["neutral", "neutral"],
    ["warn", "warn"],
    ["err", "bad"],
    ["ok", "ok"],
  ] as const)("maps %s to StatusChip tone %s", (tone, expected) => {
    expect(turnFsmChipTone(tone)).toBe(expected)
  })
})

// `execution.outcome` wire format is the TLA-prefix form
// (`receipt_done` | `receipt_skipped` | `receipt_failed` |
//  `receipt_cancelled`) emitted by `outcome_kind_to_tla_receipt`
// (lib/keeper/keeper_execution_receipt.ml:24-29). Short forms
// ('done' / 'skipped' / 'failed' / 'error') never appear here in
// production — prior fixtures asserting them was a mock↔mock loophole
// that hid five dead branches.
describe("terminalTone", () => {
  it.each([
    ["receipt_done", "ok"],
    ["receipt_skipped", "ok"],
    ["receipt_cancelled", "warn"],
    ["receipt_failed", "err"],
    ["unknown", "neutral"],
    ["", "neutral"],
    [null, "neutral"],
    [undefined, "neutral"],
  ])("maps %s to %s", (outcome, expected) => {
    expect(terminalTone(outcome)).toBe(expected)
  })
})

describe("TurnFsmDetailPanel", () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement("div")
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it("renders turn state and receipt badges through StatusChip", () => {
    const snapshot = keeperCompositeSnapshot({
      turn_phase: "executing",
      execution: {
        latest_receipt_present: true,
        recorded_at: "2026-05-01T16:00:00Z",
        outcome: "failed",
        terminal_reason_code: "tool_contract",
        operator_disposition: null,
        operator_disposition_reason: null,
        tool_contract_result: "violated",
        model_used: "glm-4.5",
        stop_reason: null,
        duration_ms: null,
        error: null,
        cascade: null,
        tool_surface: null,
      },
    })

    render(html`<${TurnFsmDetailPanel} snapshot=${snapshot} />`, container)

    const chips = [...container.querySelectorAll("[data-status-chip]")]
    expect(chips.map(chip => chip.textContent?.trim())).toEqual(expect.arrayContaining([
      "실행 중",
      "receipt failed",
      "reason tool_contract",
      "tool 도구 계약 위반",
    ]))
    expect(chips.map(chip => chip.getAttribute("data-status-chip-tone"))).toEqual(expect.arrayContaining([
      "info",
      "bad",
    ]))
    expect(chips.every(chip => chip.getAttribute("data-status-chip-uppercase") === "false")).toBe(true)
  })
})
