// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { normalizeStatusSection, sectionLabel, type StatusSection } from "./status"

describe("sectionLabel", () => {
  it.each([
    ["observatory", "Observatory"],
    ["journey", "Journey"],
    ["runtime", "Runtime"],
    ["fleet-health", "Fleet Health"],
    ["cognition", "Cognition"],
    ["agents", "Agents"],
  ] as [StatusSection, string][])("maps %s to %s", (section, expected) => {
    expect(sectionLabel(section)).toBe(expected)
  })
})

describe("normalizeStatusSection", () => {
  it("maps retired memory-subsystems links to cognition", () => {
    expect(normalizeStatusSection("memory-subsystems")).toBe("cognition")
  })

  it("falls back to the monitoring default section", () => {
    expect(normalizeStatusSection("unknown")).toBe("runtime")
    expect(normalizeStatusSection(undefined)).toBe("runtime")
  })
})
