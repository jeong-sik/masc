// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { normalizeStatusSection, sectionLabel, type StatusSection } from "./status"

describe("sectionLabel", () => {
  it.each([
    ["observatory", "Evidence Timeline"],
    ["journey", "Journey"],
    ["runtime", "Cascade & Runtime"],
    ["fleet-health", "Tool Monitor"],
    ["cognition", "Keeper Cognition"],
    ["agents", "Keeper Operations"],
  ] as [StatusSection, string][])("maps %s to %s", (section, expected) => {
    expect(sectionLabel(section)).toBe(expected)
  })
})

describe("normalizeStatusSection", () => {
  it("falls back to the monitoring default section", () => {
    expect(normalizeStatusSection("memory-subsystems")).toBe("agents")
    expect(normalizeStatusSection("unknown")).toBe("agents")
    expect(normalizeStatusSection(undefined)).toBe("agents")
  })
})
