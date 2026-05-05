// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import type { AuditEntry } from "../api/dashboard"
import {
  auditRouteParams,
  formatTokens,
  isAuditFocus,
  isCostFocus,
  isCostView,
  summarizeAuditActors,
  summarizeAuditKinds,
  viewModeForCostFocus,
} from "./cost-dashboard"

describe("isCostView", () => {
  it.each([
    ["cost", true],
    ["heuristics", true],
    ["stress", true],
    ["audit", true],
    ["decisions", true],
  ])("returns true for %s", (v, expected) => {
    expect(isCostView(v)).toBe(expected)
  })

  it.each([
    ["unknown", false],
    ["", false],
    [undefined, false],
  ])("returns false for %s", (v, expected) => {
    expect(isCostView(v)).toBe(expected)
  })
})

describe("isCostFocus", () => {
  it.each([
    ["agent", true],
    ["matrix", true],
    ["latency", true],
  ])("returns true for %s", (v, expected) => {
    expect(isCostFocus(v)).toBe(expected)
  })

  it.each([
    ["cost", false],
    ["unknown", false],
    ["", false],
    [undefined, false],
  ])("returns false for %s", (v, expected) => {
    expect(isCostFocus(v)).toBe(expected)
  })
})

describe("viewModeForCostFocus", () => {
  it("routes agent focus to keeper mode", () => {
    expect(viewModeForCostFocus("agent")).toBe("keeper")
  })

  it.each(["matrix", "latency", null] as const)("routes %s focus to model mode", focus => {
    expect(viewModeForCostFocus(focus)).toBe("model")
  })
})

describe("formatTokens", () => {
  it.each([
    [0, "0"],
    [999, "999"],
    [1000, "1.0k"],
    [1500, "1.5k"],
    [999999, "1000.0k"],
    [1_000_000, "1.00M"],
    [1_500_000, "1.50M"],
    [2_340_000, "2.34M"],
  ])("formats %d as %s", (n, expected) => {
    expect(formatTokens(n)).toBe(expected)
  })
})

describe("audit focus helpers", () => {
  it.each([
    ["actor", true],
    ["summary", true],
    ["ledger", false],
    ["", false],
    [undefined, false],
  ])("detects audit focus %s", (v, expected) => {
    expect(isAuditFocus(v)).toBe(expected)
  })

  it("builds route params for ledger and focused audit boards", () => {
    expect(auditRouteParams("ledger")).toEqual({ section: "runtime", view: "audit" })
    expect(auditRouteParams("actor")).toEqual({ section: "runtime", view: "audit", focus: "actor" })
    expect(auditRouteParams("summary")).toEqual({ section: "runtime", view: "audit", focus: "summary" })
  })
})

describe("audit summaries", () => {
  const entries: AuditEntry[] = [
    {
      id: "1",
      ts: "2026-05-06T00:00:01Z",
      actor: "keeper-alpha",
      kind: "tool_call",
      summary: "alpha called a tool",
      severity: "info",
    },
    {
      id: "2",
      ts: "2026-05-06T00:01:01Z",
      actor: "keeper-alpha",
      kind: "tool_call",
      summary: "alpha called another tool",
      severity: "warn",
    },
    {
      id: "3",
      ts: "2026-05-06T00:02:01Z",
      actor: "keeper-beta",
      kind: "auth_denied",
      summary: "beta auth failure",
      severity: "error",
    },
    {
      id: "4",
      ts: "2026-05-06T00:03:01Z",
      actor: "keeper-beta",
      kind: "tool_call",
      summary: "beta tool call",
      severity: "warn",
    },
    {
      id: "5",
      ts: "2026-05-06T00:04:01Z",
      actor: " ",
      kind: " ",
      summary: "missing actor and kind",
      severity: "info",
    },
  ]

  it("groups audit entries by actor with severity buckets and latest timestamp", () => {
    expect(summarizeAuditActors(entries)).toEqual([
      {
        actor: "keeper-alpha",
        count: 2,
        error: 0,
        warn: 1,
        info: 1,
        latest: "2026-05-06T00:01:01Z",
        topKind: "tool_call",
      },
      {
        actor: "keeper-beta",
        count: 2,
        error: 1,
        warn: 1,
        info: 0,
        latest: "2026-05-06T00:03:01Z",
        topKind: "auth_denied",
      },
      {
        actor: "(unknown)",
        count: 1,
        error: 0,
        warn: 0,
        info: 1,
        latest: "2026-05-06T00:04:01Z",
        topKind: "(unknown)",
      },
    ])
  })

  it("groups audit entries by kind with severity buckets and latest timestamp", () => {
    expect(summarizeAuditKinds(entries)).toEqual([
      {
        kind: "tool_call",
        count: 3,
        error: 0,
        warn: 2,
        info: 1,
        latest: "2026-05-06T00:03:01Z",
      },
      {
        kind: "(unknown)",
        count: 1,
        error: 0,
        warn: 0,
        info: 1,
        latest: "2026-05-06T00:04:01Z",
      },
      {
        kind: "auth_denied",
        count: 1,
        error: 1,
        warn: 0,
        info: 0,
        latest: "2026-05-06T00:02:01Z",
      },
    ])
  })
})
