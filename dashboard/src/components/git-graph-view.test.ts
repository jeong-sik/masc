// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { borderForStatus, buildElements, stylesheet } from "./git-graph-view"
import type { GitGraphResponse } from "../api/git-graph"

describe("borderForStatus", () => {
  it.each([
    ["conflict", "#ef4444"],
    ["dirty", "#f59e0b"],
    ["current", "#22c55e"],
    ["unknown", "#475569"],
    ["", "#475569"],
  ] as const)("borderForStatus(%s) → %s", (status, expected) => {
    expect(borderForStatus(status)).toBe(expected)
  })
})

describe("buildElements", () => {
  const baseGraph: GitGraphResponse = {
    agents: [{ id: "a1", label: "Agent 1", color: "#ff0000" }],
    nodes: [
      {
        id: "n1",
        label: "main",
        kind: "branch",
        status: "current",
        agent_id: "a1",
        color: "#00ff00",
        branch: "main",
        sha: "abc123",
      },
      {
        id: "n2",
        label: "feat",
        kind: "commit",
        status: "dirty",
        conflict: true,
      },
    ],
    edges: [
      { source: "n1", target: "n2", label: "merged", kind: "points_to" },
      { source: "n2", target: "n1" },
    ],
    generated_at: "2024-01-01",
  }

  it("creates agent parent nodes", () => {
    const elements = buildElements(baseGraph)
    const agentNode = elements.find(el => el.data.id === "agent:a1")
    expect(agentNode).toBeDefined()
    expect(agentNode!.data).toMatchObject({
      id: "agent:a1",
      label: "Agent 1",
      kind: "agent",
      color: "#ff0000",
      borderColor: "#ff0000",
    })
  })

  it("creates nodes with agent parent when agent_id is set", () => {
    const elements = buildElements(baseGraph)
    const node = elements.find(el => el.data.id === "n1")
    expect(node).toBeDefined()
    expect(node!.data.parent).toBe("agent:a1")
  })

  it("creates nodes without parent when agent_id is absent", () => {
    const elements = buildElements(baseGraph)
    const node = elements.find(el => el.data.id === "n2")
    expect(node).toBeDefined()
    expect(node!.data.parent).toBeUndefined()
  })

  it("uses provided node color or falls back to default", () => {
    const elements = buildElements(baseGraph)
    const n1 = elements.find(el => el.data.id === "n1")
    const n2 = elements.find(el => el.data.id === "n2")
    expect(n1!.data.color).toBe("#00ff00")
    expect(n2!.data.color).toBe("#64748b")
  })

  it("sets borderColor from node status via borderForStatus", () => {
    const elements = buildElements(baseGraph)
    const n1 = elements.find(el => el.data.id === "n1")
    const n2 = elements.find(el => el.data.id === "n2")
    expect(n1!.data.borderColor).toBe("#22c55e")
    expect(n2!.data.borderColor).toBe("#f59e0b")
  })

  it("sets title from detail > branch > sha > label", () => {
    const elements = buildElements(baseGraph)
    const n1 = elements.find(el => el.data.id === "n1")
    expect(n1!.data.title).toBe("main")
    // n1 has branch "main" but no detail, so title = branch
  })

  it("sets title from detail when present", () => {
    const graph: GitGraphResponse = {
      ...baseGraph,
      nodes: [
        { id: "n3", label: "x", kind: "commit", status: "current", detail: "detailed info" },
      ],
      edges: [],
    }
    const elements = buildElements(graph)
    const n3 = elements.find(el => el.data.id === "n3")
    expect(n3!.data.title).toBe("detailed info")
  })

  it("builds classes from kind, status, and conflict", () => {
    const elements = buildElements(baseGraph)
    const n1 = elements.find(el => el.data.id === "n1")
    const n2 = elements.find(el => el.data.id === "n2")
    expect(n1!.classes).toBe("branch current")
    expect(n2!.classes).toBe("commit dirty conflict")
  })

  it("filters edges whose source or target is missing from nodes", () => {
    const graph: GitGraphResponse = {
      ...baseGraph,
      edges: [
        { source: "n1", target: "n2" },
        { source: "n1", target: "missing" },
        { source: "missing", target: "n2" },
      ],
    }
    const elements = buildElements(graph)
    const edges = elements.filter(el => el.data.source && el.data.target)
    expect(edges).toHaveLength(1)
    expect(edges[0].data.source).toBe("n1")
    expect(edges[0].data.target).toBe("n2")
  })

  it("sets edge label default to empty string", () => {
    const graph: GitGraphResponse = {
      ...baseGraph,
      edges: [{ source: "n1", target: "n2" }],
    }
    const elements = buildElements(graph)
    const edge = elements.find(el => el.data.source === "n1")
    expect(edge!.data.label).toBe("")
  })

  it("preserves edge label when provided", () => {
    const elements = buildElements(baseGraph)
    const edge = elements.find(el => el.data.source === "n1" && el.data.target === "n2")
    expect(edge!.data.label).toBe("merged")
  })

  it("preserves edge kind as classes", () => {
    const elements = buildElements(baseGraph)
    const edge = elements.find(el => el.data.source === "n1" && el.data.target === "n2")
    expect(edge!.classes).toBe("points_to")
  })

  it("returns empty array for empty graph", () => {
    const empty: GitGraphResponse = {
      agents: [],
      nodes: [],
      edges: [],
    }
    expect(buildElements(empty)).toEqual([])
  })
})

describe("stylesheet", () => {
  it("returns array of stylesheet blocks", () => {
    const ss = stylesheet()
    expect(Array.isArray(ss)).toBe(true)
    expect(ss.length).toBeGreaterThan(0)
  })

  it("has base node selector", () => {
    const ss = stylesheet()
    const node = ss.find((s: any) => s.selector === "node")
    expect(node).toBeDefined()
    expect(node?.style?.["background-color"]).toBe("data(color)")
    expect(node?.style?.["border-color"]).toBe("data(borderColor)")
    expect(node?.style?.shape).toBe("roundrectangle")
  })

  it("has commit node style", () => {
    const ss = stylesheet()
    const commit = ss.find((s: any) => s.selector === "node.commit")
    expect(commit).toBeDefined()
    expect(commit?.style?.shape).toBe("ellipse")
    expect(commit?.style?.label).toBe("")
  })

  it("has branch node style", () => {
    const ss = stylesheet()
    const branch = ss.find((s: any) => s.selector === "node.branch")
    expect(branch).toBeDefined()
    expect(branch?.style?.shape).toBe("round-tag")
  })

  it("has conflict node style", () => {
    const ss = stylesheet()
    const conflict = ss.find((s: any) => s.selector === "node.conflict")
    expect(conflict).toBeDefined()
    expect(conflict?.style?.["border-width"]).toBe(4)
  })

  it("has parent node style", () => {
    const ss = stylesheet()
    const parent = ss.find((s: any) => s.selector === ":parent")
    expect(parent).toBeDefined()
    expect(parent?.style?.["background-color"]).toBe("#0f172a")
    expect(parent?.style?.["border-style"]).toBe("dashed")
  })

  it("has base edge selector", () => {
    const ss = stylesheet()
    const edge = ss.find((s: any) => s.selector === "edge")
    expect(edge).toBeDefined()
    expect(edge?.style?.["curve-style"]).toBe("bezier")
    expect(edge?.style?.["target-arrow-shape"]).toBe("triangle")
  })

  it("has checked_out edge style", () => {
    const ss = stylesheet()
    const checked = ss.find((s: any) => s.selector === "edge.checked_out")
    expect(checked).toBeDefined()
    expect(checked?.style?.["line-style"]).toBe("dashed")
  })

  it("has points_to edge style", () => {
    const ss = stylesheet()
    const pt = ss.find((s: any) => s.selector === "edge.points_to")
    expect(pt).toBeDefined()
    expect(pt?.style?.["line-color"]).toBe("#a78bfa")
  })
})
