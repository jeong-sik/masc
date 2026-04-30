// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { sectionLabel, type StatusSection } from "./status"

describe("sectionLabel", () => {
  it.each([
    ["live", "라이브 협업"],
    ["observatory", "관찰소"],
    ["journey", "여정"],
    ["git-graph", "Git 그래프"],
    ["runtime", "런타임"],
    ["fleet-health", "플릿 상태"],
    ["safe-autonomy", "안전 자율성"],
    ["memory-subsystems", "메모리 서브시스템"],
    ["attribution", "기여 분석"],
    ["agents", "에이전트 상태"],
    ["cost", "비용 / 지연"],
    ["cascade-inspector", "Cascade 검사기"],
  ] as [StatusSection, string][])("maps %s to %s", (section, expected) => {
    expect(sectionLabel(section)).toBe(expected)
  })
})
