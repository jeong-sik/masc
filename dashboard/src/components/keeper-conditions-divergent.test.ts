// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { isOperating, isTerminated, computeDivergences } from "./keeper-conditions-divergent"
import type { KeeperConditions, KeeperPhase } from "../types"

const allHealthy: KeeperConditions = {
  launch_pending: false,
  fiber_alive: true,
  heartbeat_healthy: true,
  turn_healthy: true,
  context_within_budget: true,
  context_handoff_needed: false,
  compaction_active: false,
  handoff_active: false,
  operator_paused: false,
  stop_requested: false,
  dead_tombstone_latched: false,
  drain_complete: false,
  context_overflow: false,
}

describe("isOperating", () => {
  it.each([
    ["Running", true],
    ["Failing", true],
    ["Overflowed", true],
    ["Paused", false],
    ["Stopped", false],
    ["Dead", false],
    ["Offline", false],
    [null, false],
    [undefined, false],
  ] as [KeeperPhase | null | undefined, boolean][])("isOperating(%s) → %s", (phase, expected) => {
    expect(isOperating(phase)).toBe(expected)
  })
})

describe("isTerminated", () => {
  it.each([
    ["Stopped", true],
    ["Dead", true],
    ["Crashed", false],
    ["Running", false],
    ["Failing", false],
    ["Paused", false],
    ["Offline", false],
    [null, false],
    [undefined, false],
  ] as [KeeperPhase | null | undefined, boolean][])("isTerminated(%s) → %s", (phase, expected) => {
    expect(isTerminated(phase)).toBe(expected)
  })
})

describe("computeDivergences", () => {
  it("returns empty for healthy conditions in Running phase", () => {
    expect(computeDivergences(allHealthy, "Running")).toEqual([])
  })

  it("detects context_handoff_needed in Running", () => {
    const divs = computeDivergences({ ...allHealthy, context_handoff_needed: true }, "Running")
    expect(divs).toHaveLength(1)
    expect(divs[0].field).toBe("context_handoff_needed")
    expect(divs[0].value).toBe(true)
  })

  it("detects context_overflow when not Overflowed", () => {
    const divs = computeDivergences({ ...allHealthy, context_overflow: true }, "Running")
    expect(divs.some(d => d.field === "context_overflow")).toBe(true)
  })

  it("ignores context_overflow when phase is Overflowed", () => {
    const divs = computeDivergences({ ...allHealthy, context_overflow: true }, "Overflowed")
    expect(divs.some(d => d.field === "context_overflow")).toBe(false)
  })

  it("detects stop_requested when not Draining", () => {
    const divs = computeDivergences({ ...allHealthy, stop_requested: true }, "Running")
    expect(divs.some(d => d.field === "stop_requested")).toBe(true)
  })

  it("ignores stop_requested when phase is Draining", () => {
    const divs = computeDivergences({ ...allHealthy, stop_requested: true }, "Draining")
    expect(divs.some(d => d.field === "stop_requested")).toBe(false)
  })

  it("detects operator_paused when not Paused", () => {
    const divs = computeDivergences({ ...allHealthy, operator_paused: true }, "Running")
    expect(divs.some(d => d.field === "operator_paused")).toBe(true)
  })

  it("ignores operator_paused when phase is Paused", () => {
    const divs = computeDivergences({ ...allHealthy, operator_paused: true }, "Paused")
    expect(divs.some(d => d.field === "operator_paused")).toBe(false)
  })

  it("detects turn_healthy=false when not Failing", () => {
    const divs = computeDivergences({ ...allHealthy, turn_healthy: false }, "Running")
    expect(divs.some(d => d.field === "turn_healthy")).toBe(true)
  })

  it("ignores turn_healthy=false when phase is Failing", () => {
    const divs = computeDivergences({ ...allHealthy, turn_healthy: false }, "Failing")
    expect(divs.some(d => d.field === "turn_healthy")).toBe(false)
  })

  it("detects heartbeat_healthy=false in operating phase", () => {
    const divs = computeDivergences({ ...allHealthy, heartbeat_healthy: false }, "Running")
    expect(divs.some(d => d.field === "heartbeat_healthy")).toBe(true)
  })

  it("ignores heartbeat_healthy=false in non-operating phase", () => {
    const divs = computeDivergences({ ...allHealthy, heartbeat_healthy: false }, "Paused")
    expect(divs.some(d => d.field === "heartbeat_healthy")).toBe(false)
  })

  it("detects fiber_alive=false when not Offline", () => {
    const divs = computeDivergences({ ...allHealthy, fiber_alive: false }, "Running")
    expect(divs.some(d => d.field === "fiber_alive")).toBe(true)
  })

  it("ignores fiber_alive=false when phase is Offline", () => {
    const divs = computeDivergences({ ...allHealthy, fiber_alive: false }, "Offline")
    expect(divs.some(d => d.field === "fiber_alive")).toBe(false)
  })

  it("detects a durable Dead tombstone outside Dead phase", () => {
    const divs = computeDivergences({ ...allHealthy, dead_tombstone_latched: true }, "Running")
    expect(divs.some(d => d.field === "dead_tombstone_latched")).toBe(true)
  })

  it("ignores most conditions in terminated phase", () => {
    const divs = computeDivergences({
      ...allHealthy,
      context_handoff_needed: true,
      context_overflow: true,
      stop_requested: true,
      turn_healthy: false,
      heartbeat_healthy: false,
      fiber_alive: false,
      dead_tombstone_latched: false,
    }, "Dead")
    // operator_paused is the only rule that does NOT check isTerminated
    expect(divs.map(d => d.field)).toEqual([])
  })

  it("still detects operator_paused in terminated phase (rule lacks isTerminated guard)", () => {
    const divs = computeDivergences({ ...allHealthy, operator_paused: true }, "Dead")
    expect(divs).toHaveLength(1)
    expect(divs[0].field).toBe("operator_paused")
  })
})
