// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { chipClass, terminalTone, isExactTurnProjection } from "./turn-fsm-detail-panel"

describe("chipClass", () => {
  it.each([
    ["accent", "border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--color-accent-fg)]"],
    ["neutral", "border-[var(--white-8)] bg-[var(--white-4)] text-[var(--color-fg-muted)]"],
    ["warn", "border-[var(--warn-24)] bg-[var(--warn-8)] text-[var(--color-status-warn)]"],
    ["err", "border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--color-status-err)]"],
    ["ok", "border-[rgba(34,197,94,0.24)] bg-[var(--emerald-8)] text-[var(--color-status-ok)]"],
  ] as const)("returns correct classes for %s tone", (tone, expected) => {
    expect(chipClass(tone)).toBe(expected)
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
