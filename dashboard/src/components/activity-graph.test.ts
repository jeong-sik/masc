// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { filterActionGroups, visibleNamespaceLabel } from "./activity-graph"
import type { ActionTimelineGroup } from "../types"

function makeGroup(overrides: Partial<ActionTimelineGroup> = {}): ActionTimelineGroup {
  return {
    id: "1",
    title: "Title",
    summary: "Summary",
    actor: null,
    subjectId: null,
    category: "task",
    rawCount: 1,
    latestTs: "",
    kinds: [],
    rawEvents: [],
    ...overrides,
  }
}

describe("filterActionGroups", () => {
  const groups = [
    makeGroup({ id: "1", title: "Alpha", summary: "summary one", actor: "user1", subjectId: "sub1" }),
    makeGroup({ id: "2", title: "Beta", summary: "summary two", actor: "user2", subjectId: "sub2" }),
  ]

  it("returns same reference for empty query", () => {
    expect(filterActionGroups(groups, "  ")).toBe(groups)
  })
  it("filters by title", () => {
    expect(filterActionGroups(groups, "alpha")).toHaveLength(1)
  })
  it("filters by summary", () => {
    expect(filterActionGroups(groups, "two")).toHaveLength(1)
  })
  it("filters by actor", () => {
    expect(filterActionGroups(groups, "USER1")).toHaveLength(1)
  })
  it("filters by subjectId", () => {
    expect(filterActionGroups(groups, "sub2")).toHaveLength(1)
  })
  it("returns empty when no match", () => {
    expect(filterActionGroups(groups, "zzz")).toHaveLength(0)
  })
})

describe("visibleNamespaceLabel", () => {
  it("returns null for null", () => expect(visibleNamespaceLabel(null)).toBeNull())
  it("returns null for undefined", () => expect(visibleNamespaceLabel(undefined)).toBeNull())
  it("returns null for empty string", () => expect(visibleNamespaceLabel("")).toBeNull())
  it("returns null for default", () => expect(visibleNamespaceLabel("default")).toBeNull())
  it("returns null for whitespace default", () => expect(visibleNamespaceLabel("  default  ")).toBeNull())
  it("returns trimmed value otherwise", () => expect(visibleNamespaceLabel("ns1")).toBe("ns1"))
})
