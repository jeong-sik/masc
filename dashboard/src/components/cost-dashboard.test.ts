// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { isCostView, formatTokens } from "./cost-dashboard"

describe("isCostView", () => {
  it.each([
    ["cost", true],
    ["heuristics", true],
    ["stress", true],
    ["audit", true],
    ["decisions", true],
  ])("returns true for %s", (v, expected) => {
    expect(isCostView(v)).toBe(expected)
  })

  it.each([
    ["unknown", false],
    ["", false],
    [undefined, false],
  ])("returns false for %s", (v, expected) => {
    expect(isCostView(v)).toBe(expected)
  })
})

describe("formatTokens", () => {
  it.each([
    [0, "0"],
    [999, "999"],
    [1000, "1.0k"],
    [1500, "1.5k"],
    [999999, "1000.0k"],
    [1_000_000, "1.00M"],
    [1_500_000, "1.50M"],
    [2_340_000, "2.34M"],
  ])("formats %d as %s", (n, expected) => {
    expect(formatTokens(n)).toBe(expected)
  })
})
