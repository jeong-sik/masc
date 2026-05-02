// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { truncateLabel, spanStyle } from "./activity-swimlane"

describe("truncateLabel", () => {
  it("returns short strings unchanged", () => {
    expect(truncateLabel("hello")).toBe("hello")
  })
  it("returns exact length unchanged", () => {
    expect(truncateLabel("a".repeat(20))).toBe("a".repeat(20))
  })
  it("truncates long strings", () => {
    expect(truncateLabel("a".repeat(21))).toBe("a".repeat(18) + "..")
  })
  it("uses custom max", () => {
    expect(truncateLabel("hello world", 8)).toBe("hello ..")
  })
})

describe("spanStyle", () => {
  it("returns style for task", () => {
    expect(spanStyle("task")).toEqual({ bg: "var(--color-status-warn)", text: "var(--panel-dark)" })
  })
  it("returns style for operation", () => {
    expect(spanStyle("operation")).toEqual({ bg: "var(--color-status-ok)", text: "var(--panel-dark)" })
  })
  it("returns style for autonomy", () => {
    expect(spanStyle("autonomy")).toEqual({ bg: "var(--cyan)", text: "var(--panel-dark)" })
  })
  it("returns style for presence", () => {
    expect(spanStyle("presence")).toEqual({ bg: "rgba(148, 163, 184, 0.25)", text: "var(--frost-100)" })
  })
  it("returns default for unknown kind", () => {
    expect(spanStyle("unknown")).toEqual({ bg: "var(--color-fg-muted)", text: "var(--panel-dark)" })
  })
})
