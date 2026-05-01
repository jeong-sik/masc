// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { sectionLabel, type StatusSection } from "./status"

describe("sectionLabel", () => {
  it.each([
    ["observatory", "Observatory"],
    ["journey", "Journey"],
    ["runtime", "Runtime"],
    ["fleet-health", "Fleet Health"],
    ["memory-subsystems", "Memory Subsystems"],
    ["cognition", "Cognition"],
    ["agents", "Agents"],
  ] as [StatusSection, string][])("maps %s to %s", (section, expected) => {
    expect(sectionLabel(section)).toBe(expected)
  })
})
