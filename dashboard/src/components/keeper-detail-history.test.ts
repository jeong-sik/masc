// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { render } from "preact"
import { html } from "htm/preact"
import {
  filterCheckpointHistory,
  lineageTransitionLabel,
  MonoBadge,
} from "./keeper-detail-history"
import type { KeeperCheckpointSummary } from "../api/keeper"

function makeRow(overrides: Partial<KeeperCheckpointSummary> = {}): KeeperCheckpointSummary {
  return {
    snapshot_id: "snap-001",
    generation: 1,
    message_count: 5,
    created_at: 1700000000,
    ...overrides,
  } as KeeperCheckpointSummary
}

describe("filterCheckpointHistory", () => {
  const rows = [
    makeRow({ snapshot_id: "abc-123", source_kind: "oas_current", latest_preview: "hello world" }),
    makeRow({ snapshot_id: "def-456", source_kind: "oas_history", latest_preview: "foo bar" }),
    makeRow({ snapshot_id: "ghi-789", source_kind: "manual", latest_preview: "baz qux" }),
  ]

  it("returns same reference for empty query", () => {
    expect(filterCheckpointHistory(rows, "  ")).toBe(rows)
  })

  it("filters by snapshot_id", () => {
    expect(filterCheckpointHistory(rows, "abc")).toHaveLength(1)
    expect(filterCheckpointHistory(rows, "ABC")).toHaveLength(1)
  })

  it("filters by source_kind", () => {
    expect(filterCheckpointHistory(rows, "oas_history")).toHaveLength(1)
  })

  it("filters by latest_preview", () => {
    expect(filterCheckpointHistory(rows, "world")).toHaveLength(1)
  })

  it("returns empty when no match", () => {
    expect(filterCheckpointHistory(rows, "zzz")).toHaveLength(0)
  })

  it("treats null fields defensively", () => {
    const sparse = [makeRow({ snapshot_id: "match", source_kind: null as any, latest_preview: null as any })]
    expect(filterCheckpointHistory(sparse, "match")).toHaveLength(1)
    expect(filterCheckpointHistory(sparse, "none")).toHaveLength(0)
  })
})

describe("MonoBadge", () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement("div")
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it("renders through the shared StatusChip primitive without uppercasing identifiers", () => {
    render(html`<${MonoBadge}>feature/CaseSensitive<//>`, container)

    const chip = container.querySelector("[data-status-chip]")
    expect(chip?.textContent).toBe("feature/CaseSensitive")
    expect(chip?.getAttribute("data-status-chip-tone")).toBe("info")
    expect(chip?.getAttribute("data-status-chip-uppercase")).toBe("false")
    expect(chip?.classList.contains("font-mono")).toBe(true)
  })
})

describe("lineageTransitionLabel", () => {
  it("shows root for null parent", () => {
    expect(lineageTransitionLabel(null, 1)).toBe("root -> gen 1")
  })

  it("shows root for undefined parent", () => {
    expect(lineageTransitionLabel(undefined, 2)).toBe("root -> gen 2")
  })

  it("shows parent generation when present", () => {
    expect(lineageTransitionLabel(3, 4)).toBe("gen 3 -> gen 4")
  })

  it("handles zero parent generation", () => {
    expect(lineageTransitionLabel(0, 1)).toBe("gen 0 -> gen 1")
  })
})
