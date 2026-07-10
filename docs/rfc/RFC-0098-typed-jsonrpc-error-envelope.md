---
rfc: "0098"
title: "Typed JSON-RPC error envelope & production-code silent-failure lint"
status: Implemented
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0077", "0088", "0089", "0090"]
implementation_prs: [15759, 15776, 15784, 15789, 15793, 15826]
---

# RFC-0098 — Typed JSON-RPC error envelope & production-code silent-failure lint

Status: Implemented (PR-1 #15759 · PR-2 #15776 · PR-2/PR-3 sync #15784 #15789 · PR-3 #15793 · PR-4 #15826)
Author: jeong-sik (vincent)
Date: 2026-05-17
Scope: transport boundary (server response envelope) + lib/-wide silent-failure lint
Out of scope: persistence write failures (covered by [[RFC-0077]]), counter→Result umbrella ([[RFC-0088]]), string→variant ([[RFC-0089]]), N-of-M migration closure ([[RFC-0090]])

## 1. Problem

Two distinct silent-failure surfaces remain after [[RFC-0077]], [[RFC-0088]], [[RFC-0089]], [[RFC-0090]] address the *internal* keeper persistence and *write-side success-model attribution* gaps:

### 1.1 JSON-RPC response factories are hand-rolled (transport boundary)

`lib/server/server_mcp_transport_http_respond.ml` writes four JSON-RPC error responses with **literal numeric codes copy-pasted**, not derived from a typed variant:

```
lib/server/server_mcp_transport_http_respond.ml:51   ("code", `Int (-32001))  respond_mcp_auth_error
lib/server/server_mcp_transport_http_respond.ml:74   ("code", `Int (-32603))  respond_mcp_internal_error
lib/server/server_mcp_transport_http_respond.ml:95   ("code", `Int (-32002))  respond_not_ready
lib/server/server_mcp_transport_http_respond.ml:144  ("code", `Int (-32603))  mcp_internal_error_json
```

Two consequences observable today:

- **`-32603` is overloaded.** The `.mli` itself documents `respond_mcp_internal_error` as "catch-all for runtime failures the transport cannot classify more precisely." Provider timeouts, tool dispatch failures, backpressure-induced rejections, and JSON serialization bugs all collapse to the same code. Clients (CLI-Tool-A, Cursor, Provider-D-compat) cannot programmatically distinguish a transient provider stall from an internal serialization bug — both surface as `-32603 Internal error`.
- **There is no place to add a new well-typed code.** Adding `-32004 Provider_timeout` or `-32005 Backpressure_shed` today requires editing four sites and grepping for any other literal user. A future SDK contract change ("emit `data.code` for machine routing") has no chokepoint.

This is the **transport-boundary** analog of [[RFC-0089]]'s string-classifier problem: the response envelope is an *output* surface, and untyped output is the same anti-pattern as untyped input. Reviewers cannot enforce exhaustiveness on integer literals.

### 1.2 Production code silent-failure scan is absent

`scripts/anti-fake-audit.sh` scans **only `test/`** (`find test -name "test_*.ml"`) for fake assertions. Production code (`lib/`) has no lint gate against the silent-failure shapes that [[RFC-0088]] §1 lists as merge-reject:

Baseline measurements (worktree HEAD `f484c728ca`, ripgrep against `lib/`):

```
ignore (Error _)             0 sites   ← good baseline, keep at 0
try ... with _ -> ()        15 sites   ← needs case-by-case audit
| Error _ -> ()             13 sites   ← typed silent-skip; some legitimate (best-effort), some not
```

Zero `ignore (Error _)` is a fortunate baseline. Without a lint gate the count can grow by one PR; the same dynamic that produced the read-side telemetry pile-up ([[RFC-0044]], 12 PRs over ~6 weeks) applies here.

The two surfaces are coupled at the **boundary contract**: an internal silent failure that should have produced a typed error (covered by [[RFC-0077]] / [[RFC-0088]]) becomes a *response* failure only if the transport layer has a typed envelope to encode it (this RFC). Without §3.1, a propagated `Error _` from a fixed [[RFC-0077]] write reaches `server_mcp_transport_http_respond.ml` and collapses to `-32603 "internal error"` — the typing work upstream is invisible to the client.

## 2. Non-goals

- **Re-typing existing persistence writes.** [[RFC-0077]] owns that. This RFC will *consume* `Write_failure_reason.t` once it lands; it does not redefine it.
- **Counter removal.** [[RFC-0088]] is the umbrella for telemetry-as-fix migration; this RFC adds a new emission shape (typed JSON-RPC error envelope) without removing existing legacy metrics backend counters.
- **OAS / `agent_sdk` API change.** A separate RFC (forthcoming in the IMPROVE-series, see §9) covers `oas/lib/api_common.ml` `Error_type.t`. RFC-0098 stops at the masc boundary.
- **`failure_envelope.ml` redesign.** That module is operator-visible **tool-host attachment** (severity / recoverability / operator action) and is orthogonal. The new envelope produced here may *embed* a `failure_envelope.t` in `data.evidence_ref`, but does not replace it.
- **JSON-RPC error code spec change.** The set of well-known codes (`-32700`, `-32600`, `-32601`, `-32602`, `-32603`) is fixed by the spec. This RFC introduces **server-defined codes in `-32000` to `-32099`** per JSON-RPC 2.0 §5.1 ("reserved for implementation-defined server-errors").
- **Replacing `with _ -> ()` everywhere.** Some of the 15 sites are legitimate (e.g., best-effort log writes during shutdown). Audit is per-cohort, not bulk rewrite.

## 3. Design

### 3.1 `Mcp_error_code.t` (closed sum, server-side SSOT)

New module `lib/server/mcp_error_code.ml` + `.mli`:

```ocaml
(** JSON-RPC 2.0 error code variant for MCP server responses.

    Wire codes follow JSON-RPC 2.0 §5.1:
    - Well-known: -32700, -32600, -32601, -32602, -32603
    - Implementation-defined: -32000 to -32099 (server) *)

type t =
  (* JSON-RPC 2.0 well-known *)
  | Parse_error           (** -32700 *)
  | Invalid_request       (** -32600 *)
  | Method_not_found      (** -32601 *)
  | Invalid_params        (** -32602 *)
  | Internal_error        (** -32603 — last-resort catch-all; PRs MUST justify
                              why no specific variant fits *)

  (* MCP server-defined (-32000 to -32099) *)
  | Auth_error            (** -32001  unauthenticated / token rejected *)
  | Not_ready             (** -32002  server is starting up; Retry-After hinted *)
  | Provider_timeout      (** -32003  upstream provider stalled past budget *)
  | Tool_dispatch_failure (** -32004  tool exists but execution failed at runtime *)
  | Backpressure_shed     (** -32005  mailbox / pool capacity exceeded; client should resume *)
  | Session_evicted       (** -32006  session lifecycle terminated by server policy *)
  | Quiet of { reason : string ; recovered : bool }
        (** -32099  last-resort silent-skip annotation.
            "Skipping is OK here" must be DECLARED — never inferred.
            Lint (§3.4) requires every [Quiet] construction to carry a
            non-empty [reason] and a [recovered:bool] discriminating
            self-healed from data-loss. *)

val to_wire_code : t -> int
val of_wire_code : int -> t option
val to_wire_message : t -> string  (** stable English string for body.message *)
val to_http_status : t -> int      (** 200/4xx/5xx — kept here so transport
                                       cannot drift from envelope semantics *)
```

The variant is **closed**. Adding a new code requires (a) RFC-level discussion or (b) an `Other of { code : int ; message : string }` extension — explicitly **not** added in v1 to force the choice to surface.

### 3.2 Single `respond_mcp_error` SSOT

`server_mcp_transport_http_respond.ml(i)` gains:

```ocaml
val respond_mcp_error :
  ?extra_headers:(string * string) list ->
  ?data:Yojson.Safe.t ->
  deps:Server_mcp_transport_http_types.deps ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  session_id:string ->
  protocol_version:string ->
  code:Mcp_error_code.t ->
  string ->
  unit
```

Existing `respond_mcp_auth_error`, `respond_mcp_internal_error`, `respond_not_ready`, `mcp_internal_error_json` become **thin delegations** to `respond_mcp_error ~code:Auth_error`, etc. — kept for caller stability for one release cycle, then deprecated via `[@deprecated]` attribute, removed in a follow-up cleanup PR.

The `data` argument is the JSON-RPC 2.0 §5.1 *"primitive or structured value that contains additional information about the error"* slot. This is where `failure_envelope.t` is embedded (`?data:(Failure_envelope.to_yojson f)`) and where `Quiet { reason ; recovered }` payload travels.

### 3.3 Migration plan

| PR | Scope | Acceptance |
|----|-------|-----------|
| PR-1 (this RFC + Phase-0) | RFC body + `Mcp_error_code` module (inert) + `respond_mcp_error` SSOT + thin delegations from existing 4 respond functions. Behavior-preserving. | `dune build @runtest` green; `verify_truth.sh` shows identical wire output at the 4 existing sites. |
| PR-2 | Migrate 4 existing call sites to use `~code:` form directly. Mark old respond functions `[@deprecated]`. | `git grep "(-32603)" lib/server/` returns 0. |
| PR-3 | Wire `Provider_timeout` (`-32003`) at LLM call boundary. Audit site: the retired proactive exec call site that used `Llm_orchestration.run_prompt_runtime`. | First non-`-32603` server-defined code in client traces; benchmark documents distinction. |
| PR-4 | Wire `Tool_dispatch_failure` (`-32004`) at tool execution boundary. | Tool-failure response carries `data.tool` + `data.phase`. |
| PR-5 | Wire `Backpressure_shed` (`-32005`) — depends on the FD/pool work in the upcoming WS-C RFC (workspace collaboration required with in-flight #15727). | Co-sequenced with that RFC / PR. |

PR-1 is **inert at the wire**: identical bytes go out, only the construction path is refactored. This isolates the typed-introduction risk from the semantic-change risk.

### 3.4 Lint gate (`scripts/anti-fake-audit.sh` extension)

The script currently iterates only `test/`. Extend to **production scan mode**:

```
# new flag: --production-scan
# scans lib/ for the merge-reject patterns from RFC-0088 §1
```

Patterns and policy:

| Pattern | Today | Policy |
|---------|-------|--------|
| `ignore (Error _)` | 0 sites | hard fail on any new occurrence |
| `\| Error _ -> ()` | 13 sites | grandfather list in `scripts/lint/silent-skip-grandfather.txt`; new occurrence outside list = fail; PR adding to list requires `Quiet { reason ; recovered }` justification in code comment |
| `try ... with _ -> ()` | 15 sites | same grandfather mechanism; comment must specify what exceptions are intentionally swallowed |
| `let _ = ... \|> Result.bind` | 0 sites (not measured here; baseline at PR-1) | hard fail on any new occurrence |
| `Microlog.warn ... failed` without nearby `Error _` or `raise` in the same `match` arm | not enforced | reviewer-block (manual); structural lint deferred to follow-up RFC |

The grandfather list mirrors [[RFC-0077]]'s `RFC-0077-inventory.csv` device — it makes the existing debt visible and *bounded* without forcing a flag-day migration.

CI integration: a new `.github/workflows/lint-production-silent-failure.yml` job runs `scripts/anti-fake-audit.sh --production-scan` and gates merge. Existing `anti-fake-audit` (test-only) remains unchanged.

### 3.5 Audit priority sites (ordered)

PR-3+ targets, ordered by blast radius:

1. Retired proactive exec call site — `Llm_orchestration.run_prompt_runtime` swallowed provider failure into a default response. Map to `Provider_timeout` / `Provider_error`.
2. `lib/keeper/keeper_autonomy.ml:248` — `Llm_orchestration.complete` same shape.
3. `lib/operator/operator_pending_confirm.ml:33-37` — unknown actor → "dashboard" string collapse. This is a [[RFC-0089]] string-classifier instance; cross-reference in PR.
4. `lib/keeper/keeper_context_core.ml` — `Tool_result.json` breakage area; orchestrate with [[RFC-0062]].
5. `lib/inference_utils.ml`, `lib/context_compact_oas.ml` — same family.

Each PR-3+ cites both RFC-0098 (envelope code) and the relevant upstream RFC (0077 for write, 0089 for string-class, 0062 for tool result).

## 4. Stable behavior guarantee

PR-1 is **byte-equal** at the wire. Same 4 codes (`-32001`, `-32002`, `-32603`, `-32603`), same message strings, same `mcp-session-id` + `mcp-protocol-version` headers, same `retry-after` for `Not_ready`.

`respond_sse_rate_limited` is **out of scope for PR-1**: its 429 response shape is contractually different (literal error code string `sse_connection_rate_limited` in body, asymmetric float/int retry-after). PR-2 considers whether `Backpressure_shed` subsumes it; if not, it stays as a sibling.

PR-3 onward introduces *new* wire codes (`-32003`, `-32004`, …). Clients that switch on the integer code see new values for the first time. **Documentation update**: `docs/spec/09-server-transport.md` (or equivalent) lists every code in the closed variant at PR-1 merge time, so clients can negotiate up front.

## 5. Drift guards

- **`Mcp_error_code` is closed.** Adding a variant without an `Other` escape hatch forces RFC discussion. `ppx_deriving` `[@@deriving show]` is added so test failures pretty-print the variant name.
- **Code-uniqueness test** (`test/test_mcp_error_code_unique.ml`): asserts every variant maps to a unique wire integer and that integers are within JSON-RPC 2.0 reserved ranges.
- **Literal-code lint**: a `git grep` check in CI fails any PR adding `("code", \`Int (-3[0-9]+))` outside `mcp_error_code.ml`. (Similar to the existing pattern in `scripts/check-doc-truth.sh`.)
- **Grandfather inventory stability**: `silent-skip-grandfather.txt` is line-stable; CI diff fails if a line moves without a corresponding source-line change.

## 6. Trade-offs

| For | Against |
|-----|---------|
| Single chokepoint for transport envelope semantics. Future SDK contract changes touch one file. | Migration cost: every caller of the four old respond functions must convert to `~code:`. PR-2 cost = 4 sites + tests. |
| Closed variant forces RFC-level discussion when adding codes. | "Escape hatch absent" can frustrate one-off internal experiments — caller must either re-purpose `Internal_error` (and accept the lint comment requirement) or RFC the new code. |
| Lint baseline at 0/15/13 lets us hold the line on `ignore (Error _)`. | Grandfather list adds maintenance overhead; movement / refactor of a grandfathered line will require list edit. |
| Composes cleanly with [[RFC-0077]] / [[RFC-0088]] / [[RFC-0089]]: the typed Result they propagate has a typed JSON-RPC code to wrap it. | Separate lint gate (`--production-scan`) is yet another CI job; latency on PR feedback. |
| `Quiet { reason ; recovered }` makes "deliberate silent skip" *visible* in the response envelope itself. | If overused, `-32099 Quiet` becomes the new `-32603 Internal_error` — variant choice still has reviewer responsibility. |

## 7. Open questions

- **Q1**: Should `Mcp_error_code` live in `lib/server/` (transport-only) or `lib/mcp/` (shared with consumer/SDK)? **Decision (default)**: `lib/server/` for PR-1 to bound the change; if/when OAS `Error_type.t` lands, consider promotion to `lib/mcp/` with phantom-type `server | client` discriminator.
- **Q2**: Embed `failure_envelope.t` in `data` automatically, or always opt-in? **Decision**: opt-in via `?data:` argument. Auto-embed risks leaking operator-action hints to untrusted clients.
- **Q3**: Should `Quiet` carry a *required* `surface : string` (which call site declared the skip) for grep traceability? **Open** — PR-1 introduces without `surface`, PR-2/3 considers based on real call sites.
- **Q4**: `respond_sse_rate_limited` migration timing. **Open** — depends on whether WS-C RFC unifies SSE 429 into `Backpressure_shed`.

## 8. Acceptance

- [x] **PR-1** (#15759): `Mcp_error_code` variant + `respond_mcp_error` SSOT introduced; legacy four respond functions kept; `error_body` extracted for SSE batch reuse; `--production-scan` lint mode added with 13 E1/E2 + 3 T1 grandfather sites.
- [x] **PR-2** (#15776 + #15784 + #15789 sync): legacy `respond_mcp_auth_error` / `respond_mcp_internal_error` / `mcp_internal_error_json` migrated to thin delegations of the SSOT; functions marked `[@@deprecated]` in `.mli`. JSON-RPC 2.0 §5.1 `id:null` regression guard test pinned.
- [x] **PR-3** (#15793): 10 transport call sites migrated to `~code:Mcp_error_code.<variant>` form; `git grep "(-326[0-9][0-9])" lib/server/` returns 0 outside `mcp_error_code.ml`.
- [x] **PR-4** (#15826): legacy three delegations + `[@@@alert "-deprecated"]` test suppression removed (−160 LoC); `error_body` SSOT shape contract is the sole surface remaining.
- [~] **Originally-planned PR-3/4/5 wirings** (`Provider_timeout` at the retired proactive exec call site, `Tool_dispatch_failure` at tool dispatch boundary, `Backpressure_shed` after WS-C) — **reframed**: original cite sites no longer exist in `main` (callee `keeper_agent_run.ml` already returns typed `Agent_sdk.Error.t`; `Llm_orchestration.run_prompt_runtime` was removed); see `project_rfc_0097_pr3_audit_findings.md` memory. The typed-envelope half is complete (PR-3 #15793 migrates the *response surface*); the typed-Error-source half is now an `Agent_sdk.Error.t → Mcp_error_code.t` mapping decision at the HTTP transport boundary (`server_mcp_transport_http.ml`). Tracked as a follow-up audit (low priority — no current call site emits a literal numeric code).
- [x] **Status promotion**: `Implemented` at PR-4 merge (this closeout commit).

## 9. Related RFCs, prior art, and in-flight workspace collaboration

- **[[RFC-0077]]** (Draft): Write-side silent failure — typed propagation. This RFC *consumes* `Write_failure_reason.t` once it lands; their migration cohorts overlap at the LLM call boundary.
- **[[RFC-0088]]** (Draft): Counter-as-Fix → Result Propagation umbrella. This RFC's lint extension implements the *production-scan* the umbrella calls for.
- **[[RFC-0089]]** (Draft): String classifier → typed variant. `operator_pending_confirm.ml` unknown→"dashboard" is a cross-cited site.
- **[[RFC-0090]]** (Draft): Write-side success-model attribution. Migration cadence shares cohorts with this RFC's PR-3.
- **[[RFC-0062]]** (Active): Typed `Tool_result.t`. The `Tool_dispatch_failure` variant maps to that boundary.
- **[[RFC-0042]]** (Active): Closed sum for keeper turn terminal code — same "introduce inert typed module first, migrate callers" pattern.

**In-flight PR workspace collaboration (2026-05-17)**: this RFC is *IMPROVE-01* of a five-part improvement series (silent-failure / streaming / TTFT / FD / stability). Parallel in-flight work on the same repo overlaps the later parts:

- PR #15722 / #15725 — "[RFC-0095] Provider-D-compat streaming wire-up / diagnostic" overlaps IMPROVE-02 (Streamable HTTP default) and IMPROVE-04 (TTFT). IMPROVE-02 RFC will be drafted *after* reading these PRs to decide stack vs absorb.
- PR #15727 — "fix(fd): docker spawn throttle bounds host FD pressure" overlaps IMPROVE-03 (FD Accountant). IMPROVE-03 RFC will likewise be drafted after reading this PR.

## 10. References (evidence, external)

- [JSON-RPC 2.0 §5.1 — Error Object](https://www.jsonrpc.org/specification#error_object) — defines server-defined code range `-32000` to `-32099`.
- [MCP Transports (2025-03-26)](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports) — Streamable HTTP envelope conventions.
- [Real World OCaml — Error Handling](https://dev.realworldocaml.org/error-handling.html) — Option vs Result discipline; underpins §1.2 baseline.
- `instructions/software-development.md §워크어라운드 거부 기준 #1` (telemetry-as-fix) and `#2` (string classifier) — internal SSOT this RFC enforces at the transport boundary.
