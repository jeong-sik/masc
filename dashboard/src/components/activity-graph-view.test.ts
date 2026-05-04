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
    ["debate", "active", "var(--color-orange-400)"],
    ["post", "active", "var(--color-pink-400)"],
    ["unknown", "active", "var(--color-fg-muted)"],
    ["keeper", "offline", "var(--color-fg-muted)"],
    ["keeper", "retired", "var(--color-fg-muted)"],
  ] as const)("nodeColor(%s, %s) → %s", (kind, status, expected) => {
    expect(nodeColor(kind, status)).toBe(expected)
  })
})

describe("edgeColor", () => {
  it("returns muted color when inactive", () => {
    expect(edgeColor("works_on", false)).toBe("var(--color-fg-disabled)")
    expect(edgeColor("unknown", false)).toBe("var(--color-fg-disabled)")
  })

  it.each([
    ["works_on", "var(--warn-border)"],
    ["creates", "var(--ok-border)"],
    ["broadcasts", "var(--info-border)"],
    ["mentions", "var(--info-fg)"],
    ["hands_off_to", "var(--purple-50)"],
    ["posts", "var(--stalled-border)"],
    ["comments_on", "var(--stalled-fg)"],
    ["votes_on", "var(--purple-50)"],
    ["opens", "var(--purple-50)"],
    ["governs", "var(--warn-fg)"],
    ["operates_on", "var(--ok-border)"],
    ["participates_in", "var(--warn-soft)"],
    ["belongs_to", "var(--color-border-default)"],
    ["unknown", "var(--color-border-default)"],
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
