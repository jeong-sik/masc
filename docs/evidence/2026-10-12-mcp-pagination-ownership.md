# MCP tool pagination retains one credential owner

Parent: `578e12389c059ac5c7f8d49d6f636ee4ff51212d` (#42434).

Each tools/list page previously called ensureBinding independently. An external credential replacement between decoded pages let the aggregate combine results belonging to different credentials.

The actual core/dev-token/MCP fixture schedules a credential replacement in a microtask after decoding the first actual JSON response. Only the scheduler is instrumented through a temporary JSON.parse spy; response parsing is performed by the original parser, and the spy is restored in finally. The failed parent run issued two HTTP requests instead of one (`/tmp/mcp-pagination-owner-red-20261012.log`). This is controlled client interleaving evidence, not a live network race measurement.

The aggregate now acquires one binding before pagination and passes it into every page request. It checks that binding before adding each decoded page and before returning the final aggregate. Replacement after either a nonfinal or final page decode rejects the operation. No replacement credential is admitted into a continued cursor request. Existing repeated-cursor detection, server-driven termination, distinct request IDs and long legitimate pagination remain unchanged.

Focused validation: `npx vitest run src/api/mcp-admission-ownership.test.ts src/api/mcp.test.ts` passed two suites / 42 tests, retained at `/tmp/mcp-pagination-owner-focused-20261012.log`. `npx tsc --noEmit` completed with exit 0. No CI, installation, live provider/server, browser screenshot, TUI runtime or formal approval is claimed. Other HTTP preflight consumers, shared operator-action effects and full chat continuity remain outstanding.
