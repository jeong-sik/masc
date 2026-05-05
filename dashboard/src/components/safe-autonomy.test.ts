// @ts-nocheck
// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import {
  statusTone,
  statusLabel,
  normalizeSummary,
  normalizeKeeper,
  normalizeTimelineItem,
  normalizePayload,
} from "./safe-autonomy"

describe("statusTone", () => {
  it.each([
    ["pass", "border-[var(--ok-30)]"],
    ["warn", "border-[var(--warn-30)]"],
    ["fail", "border-[var(--bad-30)]"],
  ] as [DomainStatus, string][])("returns class containing %s tone", (status, expected) => {
    expect(statusTone(status)).toContain(expected)
  })
})

describe("statusLabel", () => {
  it.each([
    ["pass", "PASS"],
    ["warn", "WARN"],
    ["fail", "FAIL"],
  ] as [DomainStatus, string][])('returns "%s" for %s', (status, expected) => {
    expect(statusLabel(status)).toBe(expected)
  })
})

describe("normalizeSummary", () => {
  it("returns defaults for null", () => {
    const s = normalizeSummary(null)
    expect(s.global_score).toBe(0)
    expect(s.status).toBe("warn")
    expect(s.keeper_count).toBe(0)
    expect(s.active_goal_count).toBe(0)
    expect(s.keepers_with_current_task).toBe(0)
    expect(s.findings_total).toBe(0)
    expect(s.human_action_required_count).toBe(0)
    expect(s.approval_queue_depth).toBe(0)
  })

  it("preserves all fields", () => {
    const s = normalizeSummary({
      global_score: 82.5,
      status: "pass",
      keeper_count: 3,
      active_goal_count: 5,
      keepers_with_current_task: 2,
      findings_total: 1,
      human_action_required_count: 0,
      approval_queue_depth: 0,
    })
    expect(s.global_score).toBe(82.5)
    expect(s.status).toBe("pass")
    expect(s.keeper_count).toBe(3)
    expect(s.active_goal_count).toBe(5)
    expect(s.keepers_with_current_task).toBe(2)
    expect(s.findings_total).toBe(1)
    expect(s.human_action_required_count).toBe(0)
    expect(s.approval_queue_depth).toBe(0)
  })
})


describe("normalizeKeeper", () => {
  it("returns defaults for empty input", () => {
    const k = normalizeKeeper({})
    expect(k.name).toBe("keeper")
    expect(k.agent_name).toBe("")
    expect(k.status).toBe("warn")
    expect(k.score).toBe(0)
    expect(k.sandbox_profile).toBe("unknown")
    expect(k.sandbox_backend).toBe("unknown")
    expect(k.network_mode).toBe("unknown")
    expect(k.approval_pending_count).toBe(0)
    expect(k.trace_history_count).toBe(0)
    expect(k.recent_activity_count).toBe(0)
    expect(k.total_turns).toBe(0)
    expect(k.goal).toBe("")
    expect(k.active_goal_ids).toEqual([])
    expect(k.current_task_id).toBeNull()
    expect(k.last_blocker).toBeNull()
  })

  it("preserves provided fields", () => {
    const k = normalizeKeeper({
      name: "k1",
      agent_name: "a1",
      status: "pass",
      score: 88,
      sandbox_profile: "restricted",
      sandbox_backend: "docker",
      network_mode: "bridge",
      approval_pending_count: 2,
      trace_history_count: 10,
      recent_activity_count: 3,
      total_turns: 50,
      goal: "ship",
      active_goal_ids: ["g1", "g2"],
      current_task_id: "t1",
      last_blocker: "none",
    })
    expect(k.name).toBe("k1")
    expect(k.agent_name).toBe("a1")
    expect(k.status).toBe("pass")
    expect(k.score).toBe(88)
    expect(k.sandbox_profile).toBe("restricted")
    expect(k.sandbox_backend).toBe("docker")
    expect(k.network_mode).toBe("bridge")
    expect(k.approval_pending_count).toBe(2)
    expect(k.trace_history_count).toBe(10)
    expect(k.recent_activity_count).toBe(3)
    expect(k.total_turns).toBe(50)
    expect(k.goal).toBe("ship")
    expect(k.active_goal_ids).toEqual(["g1", "g2"])
    expect(k.current_task_id).toBe("t1")
    expect(k.last_blocker).toBe("none")
  })
})


describe("normalizeTimelineItem", () => {
  it("returns defaults for empty input", () => {
    const t = normalizeTimelineItem({})
    expect(t.ts_iso).toBe("")
    expect(t.kind).toBe("event")
    expect(t.keeper_name).toBeNull()
    expect(t.summary).toBe("")
  })

  it("preserves provided fields", () => {
    const t = normalizeTimelineItem({
      ts_iso: "2024-01-01T00:00:00Z",
      kind: "action",
      keeper_name: "k1",
      summary: "started",
    })
    expect(t.ts_iso).toBe("2024-01-01T00:00:00Z")
    expect(t.kind).toBe("action")
    expect(t.keeper_name).toBe("k1")
    expect(t.summary).toBe("started")
  })
})

describe("normalizePayload", () => {
  it("returns defaults for null", () => {
    const p = normalizePayload(null)
    expect(p.generated_at).toBe("")
    expect(p.summary.global_score).toBe(0)
    expect(p.domains).toEqual([])
    expect(p.per_keeper).toEqual([])
    expect(p.findings).toEqual([])
    expect(p.timeline).toEqual([])
    expect(p.artifacts).toEqual({})
    expect(p.history).toEqual([])
  })

  it("filters non-numbers from history", () => {
    const p = normalizePayload({ history: [1, "x", 2, null, 3] })
    expect(p.history).toEqual([1, 2, 3])
  })

  it("normalizes nested structures", () => {
    const p = normalizePayload({
      generated_at: "2024-01-01",
      summary: { global_score: 90, status: "pass" },
      domains: [{ id: "d1", label: "Tests" }],
      per_keeper: [{ name: "k1" }],
      findings: [{ reason_code: "F1" }],
      timeline: [{ kind: "start" }],
      artifacts: { key: "value" },
      history: [80, 85, 90],
    })
    expect(p.generated_at).toBe("2024-01-01")
    expect(p.summary.global_score).toBe(90)
    expect(p.domains).toHaveLength(1)
    expect(p.domains[0].id).toBe("d1")
    expect(p.per_keeper).toHaveLength(1)
    expect(p.per_keeper[0].name).toBe("k1")
    expect(p.findings).toHaveLength(1)
    expect(p.findings[0].reason_code).toBe("F1")
    expect(p.timeline).toHaveLength(1)
    expect(p.timeline[0].kind).toBe("start")
    expect(p.artifacts).toEqual({ key: "value" })
    expect(p.history).toEqual([80, 85, 90])
  })
})
