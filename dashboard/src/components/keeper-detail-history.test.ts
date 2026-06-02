// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { render } from "preact"
import { html } from "htm/preact"
import {
  filterCheckpointHistory,
  lineageVerdictMeta,
  lineageTransitionLabel,
  lineageVerdictTone,
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
    makeRow({ snapshot_id: "abc-123", source_kind: "oas_current", latest_preview: "hello world", continuity_summary: "summary one" }),
    makeRow({ snapshot_id: "def-456", source_kind: "oas_history", latest_preview: "foo bar", continuity_summary: "summary two" }),
    makeRow({ snapshot_id: "ghi-789", source_kind: "manual", latest_preview: "baz qux", continuity_summary: "summary three" }),
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

  it("filters by continuity_summary", () => {
    expect(filterCheckpointHistory(rows, "two")).toHaveLength(1)
  })

  it("returns empty when no match", () => {
    expect(filterCheckpointHistory(rows, "zzz")).toHaveLength(0)
  })

  it("treats null fields defensively", () => {
    const sparse = [makeRow({ snapshot_id: "match", source_kind: null as any, latest_preview: null as any, continuity_summary: null as any })]
    expect(filterCheckpointHistory(sparse, "match")).toHaveLength(1)
    expect(filterCheckpointHistory(sparse, "none")).toHaveLength(0)
  })
})

describe("lineageVerdictMeta", () => {
  it("returns verified meta", () => {
    expect(lineageVerdictMeta("verified")).toEqual({
      badgeLabel: "상태 보존",
      detail: "keeper 목표, 지침, 저장된 상태 요약이 핸드오프를 통해 전달됐는지 continuity 가 검사합니다.",
    })
  })

  it("returns drift_detected meta", () => {
    expect(lineageVerdictMeta("drift_detected")).toEqual({
      badgeLabel: "드리프트 검토",
      detail: "핸드오프는 완료됐지만 저장된 continuity 요약이 충분히 변경되어 operator 의 검토가 필요합니다.",
    })
  })

  it("returns unavailable meta", () => {
    expect(lineageVerdictMeta("unavailable")).toEqual({
      badgeLabel: "증거 필요",
      detail: "핸드오프는 완료됐지만 generation 비교에 필요한 continuity 데이터가 충분하지 않습니다.",
    })
  })

  it("returns default for unknown verdict", () => {
    expect(lineageVerdictMeta("unknown")).toEqual({
      badgeLabel: "알 수 없음",
      detail: "continuity 신호는 존재하지만 본 판정이 아직 operator-facing 설명에 매핑되지 않았습니다.",
    })
  })

  it("returns default for undefined", () => {
    expect(lineageVerdictMeta(undefined)).toEqual({
      badgeLabel: "알 수 없음",
      detail: "continuity 신호는 존재하지만 본 판정이 아직 operator-facing 설명에 매핑되지 않았습니다.",
    })
  })
})

describe("lineageVerdictTone", () => {
  it("maps lineage verdicts to shared StatusChip tones", () => {
    expect(lineageVerdictTone("verified")).toBe("ok")
    expect(lineageVerdictTone("drift_detected")).toBe("warn")
    expect(lineageVerdictTone("unavailable")).toBe("neutral")
    expect(lineageVerdictTone("future_verdict")).toBe("neutral")
    expect(lineageVerdictTone(undefined)).toBe("neutral")
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
