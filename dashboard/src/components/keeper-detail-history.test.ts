import { describe, expect, it, vi } from "vitest";
import { render } from "preact";
import { act } from "preact/test-utils";
import { html } from "htm/preact";
import { KeeperCheckpointPanel } from "./keeper-detail-history";

describe("KeeperCheckpointPanel diagnostics", () => {
  it("renders typed current and history checkpoint failures separately", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async () =>
      new Response(
        JSON.stringify({
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
          history_errors: [
            {
              snapshot_id: "history-broken.json",
              source_kind: "oas_history",
              is_current: false,
              path: "/tmp/trace-test/history-broken.json",
              file_stat: { size_bytes: 19 },
              status: "unavailable",
              error_kind: "io_error",
              error_detail: "permission denied",
            },
          ],
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      );

    try {
      const host = document.createElement("div");
      document.body.append(host);
      await act(async () => {
        render(
          html`<${KeeperCheckpointPanel}
            keeperName="keeper-test"
            refreshToken=${0}
          />`,
          host,
        );
      });

      await vi.waitFor(() => {
        expect(host.textContent).toContain("checkpoint 읽기 실패");
      });
      expect(host.textContent).toContain("parse_error");
      expect(host.textContent).toContain("invalid current checkpoint");
      expect(host.textContent).toContain("읽지 못한 checkpoint history");
      expect(host.textContent).toContain("history-broken.json");
      expect(host.textContent).toContain("io_error");
      expect(host.textContent).not.toContain("저장된 checkpoint 없음");
      host.remove();
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
