// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { render } from "preact"
import { act } from "preact/test-utils"
import { html } from "htm/preact"

const { requestConfirmMock } = vi.hoisted(() => ({
  requestConfirmMock: vi.fn(async () => true),
}))

vi.mock("./common/confirm-dialog", () => ({
  requestConfirm: requestConfirmMock,
}))

beforeEach(() => {
  requestConfirmMock.mockClear()
})
import {
  filterCheckpointHistory,
  KeeperCheckpointPanel,
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
    makeRow({ snapshot_id: "abc-123", source_kind: "agent_core_current", latest_preview: "hello world" }),
    makeRow({ snapshot_id: "def-456", source_kind: "agent_core_history", latest_preview: "foo bar" }),
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
    expect(filterCheckpointHistory(rows, "agent_core_history")).toHaveLength(1)
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

describe("KeeperCheckpointPanel diagnostics", () => {
  it("renders typed current and history checkpoint failures separately", async () => {
    const originalFetch = globalThis.fetch
    globalThis.fetch = async () => new Response(JSON.stringify({
      keeper: "keeper-test",
      trace_id: "trace-test",
      session_dir: "/tmp/trace-test",
      current: null,
      current_status: "unavailable",
      current_error: {
        kind: "parse_error",
        detail: "invalid current checkpoint",
      },
      history: [],
      history_errors: [{
        snapshot_id: "history-broken.json",
        source_kind: "agent_core_history",
        is_current: false,
        path: "/tmp/trace-test/history-broken.json",
        file_stat: { size_bytes: 19 },
        status: "unavailable",
        error_kind: "io_error",
        error_detail: "permission denied",
      }],
    }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    })

    const container = document.createElement("div")
    document.body.appendChild(container)
    try {
      await act(async () => {
        render(
          html`<${KeeperCheckpointPanel}
            keeperName="keeper-test"
            refreshToken=${0}
          />`,
          container,
        )
      })

      await vi.waitFor(() => {
        expect(container.textContent).toContain("checkpoint 읽기 실패")
      })
      expect(container.textContent).toContain("parse_error")
      expect(container.textContent).toContain("invalid current checkpoint")
      expect(container.textContent).toContain("읽지 못한 checkpoint history")
      expect(container.textContent).toContain("history-broken.json")
      expect(container.textContent).toContain("io_error")
      expect(container.textContent).not.toContain("저장된 checkpoint 없음")
    } finally {
      render(null, container)
      document.body.removeChild(container)
      globalThis.fetch = originalFetch
    }
  })

  it("previews then applies checkpoint purge with exact report and backup evidence", async () => {
    const inventory = {
      keeper: "keeper-test",
      trace_id: "trace-test",
      session_dir: "/tmp/trace-test",
      current: {
        snapshot_id: "trace-test.json",
        source_kind: "agent_core_current",
        is_current: true,
        status: "available",
        path: "/tmp/trace-test/trace-test.json",
        created_at: 1700000000,
        generation: 1,
        message_count: 916,
        system_prompt_present: true,
        latest_preview: "latest",
        file_stat: { size_bytes: 2367244, mtime: 1700000000 },
      },
      current_status: "available",
      current_error: null,
      history: [],
      history_errors: [],
    }
    const purgeResponse = (action: "preview_purge" | "apply_purge") => ({
      schema: "masc.keeper_checkpoint_purge.v1",
      ok: true,
      action,
      keeper: "keeper-test",
      trace_id: "trace-test",
      apply_allowed: true,
      applied: action === "apply_purge",
      backup_path: action === "apply_purge" ? "/tmp/backups/trace-test.json" : null,
      report: {
        messages_before: 916,
        messages_after: 857,
        bytes_before: 2367244,
        bytes_after: 1129051,
        bytes_removed: 1238193,
        duplicates_dropped: 59,
        reasoning_blocks_stripped: 46,
        reasoning_messages_dropped: 0,
        tool_results_cleared: 437,
      },
      warnings: [],
      inventory,
    })
    const requests: Array<{ url: string; body: unknown }> = []
    const originalFetch = globalThis.fetch
    globalThis.fetch = async (input, init) => {
      const url = String(input)
      const body = init?.body ? JSON.parse(String(init.body)) : null
      requests.push({ url, body })
      const payload = body?.action === "preview_purge"
        ? purgeResponse("preview_purge")
        : body?.action === "apply_purge"
          ? purgeResponse("apply_purge")
          : inventory
      return new Response(JSON.stringify(payload), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    }

    const container = document.createElement("div")
    document.body.appendChild(container)
    try {
      await act(async () => {
        render(
          html`<${KeeperCheckpointPanel}
            keeperName="keeper-test"
            refreshToken=${0}
          />`,
          container,
        )
      })
      await vi.waitFor(() => {
        expect(container.querySelector('[data-testid="keeper-checkpoint-purge-preview"]')).toBeTruthy()
      })

      await act(async () => {
        ;(container.querySelector('[data-testid="keeper-checkpoint-purge-preview"]') as HTMLButtonElement).click()
      })
      await vi.waitFor(() => {
        expect(container.querySelector('[data-testid="keeper-checkpoint-purge-report"]')?.textContent).toContain("437")
      })

      await act(async () => {
        ;(container.querySelector('[data-testid="keeper-checkpoint-purge-apply"]') as HTMLButtonElement).click()
      })
      await vi.waitFor(() => {
        expect(container.querySelector('[data-testid="keeper-checkpoint-purge-backup"]')?.textContent).toContain("/tmp/backups/trace-test.json")
      })

      expect(requestConfirmMock).toHaveBeenCalledTimes(1)
      expect(requests.map(request => request.body)).toEqual([
        null,
        { action: "preview_purge" },
        { action: "apply_purge" },
      ])
    } finally {
      render(null, container)
      document.body.removeChild(container)
      globalThis.fetch = originalFetch
    }
  })
})
