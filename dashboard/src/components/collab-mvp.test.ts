// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import {
  toneForStackStatus,
  stateTone,
  graphElements,
  graphKey,
  graphStylesheet,
} from "./collab-mvp"
import type { CollabGitGraphSpec } from "../collab-mvp-contract"

type StyleBlock = { selector: string; style: Record<string, unknown> }

function styleBlock(blocks: ReturnType<typeof graphStylesheet>, selector: string): StyleBlock | undefined {
  return blocks.find((block): block is StyleBlock =>
    typeof (block as { selector?: unknown }).selector === "string" &&
    (block as { selector: string }).selector === selector &&
    "style" in block
  )
}

describe("toneForStackStatus", () => {
  it.each([
    ["installed", "border-ok/35 bg-ok/10 text-ok"],
    ["observed", "border-accent/25 bg-[var(--accent-10)] text-accent"],
    ["contract", "border-warn/30 bg-warn/10 text-warn"],
  ] as const)("maps %s to correct tone", (status, expected) => {
    expect(toneForStackStatus(status)).toBe(expected)
  })
})

describe("stateTone", () => {
  it.each([
    ["running", "border-ok/35 bg-ok/10 text-ok"],
    ["claimed", "border-ok/35 bg-ok/10 text-ok"],
    ["verification", "border-warn/30 bg-warn/10 text-warn"],
    ["waiting", "border-warn/30 bg-warn/10 text-warn"],
    ["unclaimed", "border-accent/25 bg-[var(--accent-10)] text-accent"],
    ["terminal", "border-card-border/50 bg-white/[0.04] text-text-muted"],
    ["", "border-card-border/50 bg-white/[0.04] text-text-muted"],
    ["unknown", "border-card-border/50 bg-white/[0.04] text-text-muted"],
  ])("maps %s to correct tone", (state, expected) => {
    expect(stateTone(state)).toBe(expected)
  })
})

describe("graphElements", () => {
  const spec: CollabGitGraphSpec = {
    source: "worktree",
    nodes: [
      { id: "repo", label: "repo", type: "repo", source: "worktree" },
      { id: "main", label: "main", type: "main", parent: "repo", source: "worktree" },
      { id: "feat", label: "feature", type: "branch", parent: "repo", source: "worktree" },
    ],
    edges: [
      { id: "e1", source: "main", target: "feat", label: "merged" },
    ],
  }

  it("transforms nodes to cytoscape format", () => {
    const elements = graphElements(spec)
    const nodes = elements.filter(el => !el.data.source || el.data.nodeType)
    expect(nodes).toHaveLength(3)
    expect(nodes[0].data).toMatchObject({ id: "repo", label: "repo", nodeType: "repo" })
    expect(nodes[1].data).toMatchObject({ id: "main", label: "main", nodeType: "main", parent: "repo" })
    expect(nodes[2].data).toMatchObject({ id: "feat", label: "feature", nodeType: "branch", parent: "repo" })
  })

  it("transforms edges to cytoscape format", () => {
    const elements = graphElements(spec)
    const edges = elements.filter(el => el.data.source && el.data.target && !el.data.nodeType)
    expect(edges).toHaveLength(1)
    expect(edges[0].data).toMatchObject({
      id: "e1",
      source: "main",
      target: "feat",
      label: "merged",
    })
  })

  it("uses empty string for undefined edge label", () => {
    const specNoLabel: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "main", source: "worktree" }],
      edges: [{ id: "e1", source: "a", target: "a" }],
    }
    const elements = graphElements(specNoLabel)
    const edge = elements.find(el => el.data.id === "e1")
    expect(edge?.data.label).toBe("")
  })

  it("returns empty array for empty graph", () => {
    const empty: CollabGitGraphSpec = { source: "worktree", nodes: [], edges: [] }
    expect(graphElements(empty)).toEqual([])
  })
})

describe("graphKey", () => {
  it("is deterministic for same graph", () => {
    const spec: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "main", source: "worktree" }],
      edges: [{ id: "e1", source: "a", target: "a" }],
    }
    expect(graphKey(spec)).toBe(graphKey(spec))
  })

  it("changes when source changes", () => {
    const base: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "main", source: "worktree" }],
      edges: [],
    }
    const other: CollabGitGraphSpec = { ...base, source: "coordination_fallback" }
    expect(graphKey(base)).not.toBe(graphKey(other))
  })

  it("changes when node is added", () => {
    const base: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "main", source: "worktree" }],
      edges: [],
    }
    const extended: CollabGitGraphSpec = {
      ...base,
      nodes: [...base.nodes, { id: "b", label: "B", type: "branch", source: "worktree" }],
    }
    expect(graphKey(base)).not.toBe(graphKey(extended))
  })

  it("changes when edge is added", () => {
    const base: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "main", source: "worktree" }],
      edges: [],
    }
    const extended: CollabGitGraphSpec = {
      ...base,
      edges: [{ id: "e1", source: "a", target: "a", label: "loop" }],
    }
    expect(graphKey(base)).not.toBe(graphKey(extended))
  })

  it("includes parent in key when present", () => {
    const withParent: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "branch", parent: "repo", source: "worktree" }],
      edges: [],
    }
    const withoutParent: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "branch", source: "worktree" }],
      edges: [],
    }
    expect(graphKey(withParent)).not.toBe(graphKey(withoutParent))
  })

  it("includes edge label in key when present", () => {
    const withLabel: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "main", source: "worktree" }],
      edges: [{ id: "e1", source: "a", target: "a", label: "x" }],
    }
    const withoutLabel: CollabGitGraphSpec = {
      source: "worktree",
      nodes: [{ id: "a", label: "A", type: "main", source: "worktree" }],
      edges: [{ id: "e1", source: "a", target: "a" }],
    }
    expect(graphKey(withLabel)).not.toBe(graphKey(withoutLabel))
  })
})

describe("graphStylesheet", () => {
  it("returns array of stylesheet blocks", () => {
    const ss = graphStylesheet()
    expect(Array.isArray(ss)).toBe(true)
    expect(ss.length).toBeGreaterThan(0)
  })

  it("has base node selector", () => {
    const ss = graphStylesheet()
    const node = styleBlock(ss, "node")
    expect(node).toBeDefined()
    expect(node?.style?.["background-color"]).toBe("#1e293b")
    expect(node?.style?.["font-size"]).toBe("10px")
  })

  it("has repo node style", () => {
    const ss = graphStylesheet()
    const repo = styleBlock(ss, 'node[nodeType="repo"]')
    expect(repo).toBeDefined()
    expect(repo?.style?.shape).toBe("roundrectangle")
    expect(repo?.style?.["border-style"]).toBe("dashed")
  })

  it("has main node style", () => {
    const ss = graphStylesheet()
    const main = styleBlock(ss, 'node[nodeType="main"]')
    expect(main).toBeDefined()
    expect(main?.style?.shape).toBe("ellipse")
    expect(main?.style?.["background-color"]).toBe("#1d4ed8")
  })

  it("has branch node style", () => {
    const ss = graphStylesheet()
    const branch = styleBlock(ss, 'node[nodeType="branch"]')
    expect(branch).toBeDefined()
    expect(branch?.style?.["background-color"]).toBe("#065f46")
  })

  it("has task node style", () => {
    const ss = graphStylesheet()
    const task = styleBlock(ss, 'node[nodeType="task"]')
    expect(task).toBeDefined()
    expect(task?.style?.shape).toBe("tag")
  })

  it("has coordination_fallback border style", () => {
    const ss = graphStylesheet()
    const fallback = styleBlock(ss, 'node[source="coordination_fallback"]')
    expect(fallback).toBeDefined()
    expect(fallback?.style?.["border-style"]).toBe("dotted")
  })

  it("has edge style", () => {
    const ss = graphStylesheet()
    const edge = styleBlock(ss, "edge")
    expect(edge).toBeDefined()
    expect(edge?.style?.["curve-style"]).toBe("bezier")
    expect(edge?.style?.["target-arrow-shape"]).toBe("triangle")
  })
})
