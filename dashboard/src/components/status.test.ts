// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { sectionLabel, type StatusSection } from "./status"

describe("sectionLabel", () => {
  it.each([
    ["observatory", "관찰소"],
    ["journey", "여정"],
    ["runtime", "런타임"],
    ["fleet-health", "플릿 상태"],
    ["memory-subsystems", "메모리 서브시스템"],
    ["agents", "에이전트 상태"],
  ] as [StatusSection, string][])("maps %s to %s", (section, expected) => {
    expect(sectionLabel(section)).toBe(expected)
  })
})
