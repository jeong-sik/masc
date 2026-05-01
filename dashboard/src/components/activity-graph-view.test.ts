// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { nodeColor, edgeColor, kindLabel, edgeKindLabel } from "./activity-graph-view"

describe("nodeColor", () => {
  it.each([
    ["keeper", "active", "var(--color-status-ok)"],
    ["agent", "active", "var(--cyan)"],
    ["task", "active", "var(--color-status-warn)"],
    ["decision", "active", "var(--purple)"],
    ["operation", "active", "var(--color-status-ok)"],
    ["debate", "active", "#fb923c"],
    ["post", "active", "#f472b6"],
    ["unknown", "active", "var(--slate-400)"],
    ["keeper", "offline", "var(--slate-500)"],
    ["keeper", "retired", "var(--slate-500)"],
  ] as const)("nodeColor(%s, %s) → %s", (kind, status, expected) => {
    expect(nodeColor(kind, status)).toBe(expected)
  })
})

describe("edgeColor", () => {
  it("returns muted color when inactive", () => {
    expect(edgeColor("works_on", false)).toBe("rgba(100, 116, 139, 0.15)")
    expect(edgeColor("unknown", false)).toBe("rgba(100, 116, 139, 0.15)")
  })

  it.each([
    ["works_on", "rgba(251, 191, 36, 0.5)"],
    ["creates", "rgba(74, 222, 128, 0.4)"],
    ["broadcasts", "rgba(34, 211, 238, 0.35)"],
    ["mentions", "rgba(34, 211, 238, 0.55)"],
    ["hands_off_to", "var(--purple-50)"],
    ["posts", "rgba(244, 114, 182, 0.4)"],
    ["comments_on", "rgba(244, 114, 182, 0.3)"],
    ["votes_on", "rgba(167, 139, 250, 0.35)"],
    ["opens", "rgba(167, 139, 250, 0.4)"],
    ["governs", "rgba(251, 146, 60, 0.4)"],
    ["operates_on", "rgba(74, 222, 128, 0.45)"],
    ["participates_in", "rgba(251, 191, 36, 0.35)"],
    ["belongs_to", "var(--slate-gray-12)"],
    ["unknown", "rgba(148, 163, 184, 0.25)"],
  ] as const)("edgeColor(%s, true) → %s", (kind, expected) => {
    expect(edgeColor(kind, true)).toBe(expected)
  })
})

describe("kindLabel", () => {
  it.each([
    ["keeper", "키퍼"],
    ["agent", "에이전트"],
    ["task", "작업"],
    ["decision", "결정"],
    ["operation", "작전"],
    ["debate", "토론"],
    ["post", "게시글"],
    ["room", "프로젝트"],
    ["unknown", "unknown"],
  ] as const)("kindLabel(%s) → %s", (kind, expected) => {
    expect(kindLabel(kind)).toBe(expected)
  })
})

describe("edgeKindLabel", () => {
  it.each([
    ["works_on", "작업 중"],
    ["creates", "생성"],
    ["broadcasts", "브로드캐스트"],
    ["mentions", "멘션"],
    ["hands_off_to", "핸드오프"],
    ["posts", "게시"],
    ["comments_on", "댓글"],
    ["votes_on", "투표"],
    ["belongs_to", "소속"],
    ["opens", "열기"],
    ["governs", "거버넌스"],
    ["operates_on", "운영"],
    ["participates_in", "참여"],
    ["unknown", "unknown"],
  ] as const)("edgeKindLabel(%s) → %s", (kind, expected) => {
    expect(edgeKindLabel(kind)).toBe(expected)
  })
})
