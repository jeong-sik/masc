// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { sectionItemsForTab } from "../config/navigation"
import { isHiddenDiagnostic, isMonitorLane, normalizeStatusSection, sectionLabel, type StatusSection } from "./status"

describe("sectionLabel", () => {
  it("uses monitoring navigation labels as the SSOT", () => {
    for (const item of sectionItemsForTab("monitoring")) {
      expect(sectionLabel(item.params.section as StatusSection)).toBe(item.label)
    }
  })
})

describe("monitor lane visibility", () => {
  it("uses monitoring navigation hidden flags as the SSOT", () => {
    for (const item of sectionItemsForTab("monitoring")) {
      const section = item.params.section as StatusSection
      expect(isMonitorLane(section)).toBe(item.hidden !== true)
      expect(isHiddenDiagnostic(section)).toBe(item.hidden === true)
    }
  })
})

describe("normalizeStatusSection", () => {
  it("accepts every monitoring navigation section", () => {
    for (const item of sectionItemsForTab("monitoring")) {
      expect(normalizeStatusSection(item.params.section)).toBe(item.params.section)
    }
  })

  it("falls back to the monitoring default section", () => {
    expect(normalizeStatusSection("memory-subsystems")).toBe("agents")
    expect(normalizeStatusSection("unknown")).toBe("agents")
    expect(normalizeStatusSection(undefined)).toBe("agents")
  })
})
