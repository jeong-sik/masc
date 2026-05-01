// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { render } from "preact"
import { html } from "htm/preact"
import {
  isExactTurnProjection,
  terminalTone,
  TurnFsmDetailPanel,
  turnFsmChipTone,
} from "./turn-fsm-detail-panel"
import type { KeeperCompositeSnapshot } from "../api/keeper"

vi.mock("./common/cytoscape-fsm", () => ({
  CytoscapeFsm: () => html`<div data-testid="fsm-graph"></div>`,
}))

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

describe("terminalTone", () => {
  it.each([
    ["done", "ok"],
    ["skipped", "ok"],
    ["cancelled", "warn"],
    ["failed", "err"],
    ["error", "err"],
    ["unknown", "neutral"],
    ["", "neutral"],
    [null, "neutral"],
    [undefined, "neutral"],
  ])("maps %s to %s", (outcome, expected) => {
    expect(terminalTone(outcome)).toBe(expected)
  })
})

describe("isExactTurnProjection", () => {
  it.each([
    ["idle", "idle", true],
    ["AWAITING_TOOL", "awaiting_tool", true],
    ["awaiting_tool", "awaiting_tool_result", true],
    ["  awaiting_tool  ", "awaiting_tool_result", true],
    ["done", "done", true],
    ["done", "idle", false],
    ["awaiting_tool", "awaiting_tool", true],
    ["unknown", null, false],
    ["", "idle", false],
  ])("isExactTurnProjection(%s, %s) → %s", (raw, projected, expected) => {
    expect(isExactTurnProjection(raw, projected)).toBe(expected)
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
    const snapshot = {
      turn_phase: "awaiting_tool",
      execution: {
        outcome: "failed",
        terminal_reason_code: "tool_contract",
        tool_contract_result: "violated",
        model_used: "glm-4.5",
      },
    } as KeeperCompositeSnapshot

    render(html`<${TurnFsmDetailPanel} snapshot=${snapshot} />`, container)

    const chips = [...container.querySelectorAll("[data-status-chip]")]
    expect(chips.map(chip => chip.textContent?.trim())).toEqual(expect.arrayContaining([
      "awaiting_tool_result",
      "KTC awaiting_tool",
      "TLA awaiting_tool",
      "receipt failed",
      "reason tool_contract",
      "tool violated",
      "model glm-4.5",
    ]))
    expect(chips.map(chip => chip.getAttribute("data-status-chip-tone"))).toEqual(expect.arrayContaining([
      "info",
      "neutral",
      "bad",
    ]))
    expect(chips.every(chip => chip.getAttribute("data-status-chip-uppercase") === "false")).toBe(true)
  })
})
