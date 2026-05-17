---
rfc: "0105"
title: "OpenAI-compat boundary: Agent_sdk.Error.t → HTTP status + typed envelope"
status: Active
created: 2026-05-17
updated: 2026-05-17
author: jeong-sik
supersedes: []
superseded_by: null
related: ["0098", "0095"]
implementation_prs: [15899]
---

# RFC-0105 — OpenAI-compat boundary typed error mapping

## 1. Summary

RFC-0098 (typed JSON-RPC error envelope, Implemented 2026-05-17) closed
IMPROVE-01 for the `server_mcp_transport_http` surface — that file now
emits `Mcp_error_code` typed values at 9 call sites and 0 literal numeric
codes. The closeout body explicitly reframed the original §8 PR-3/4/5
plan and pointed at a remaining boundary:

> "the callees moved to typed `Agent_sdk.Error.t`; the remaining work is
> an `Agent_sdk.Error.t → Mcp_error_code.t` mapping decision at
> `server_mcp_transport_http.ml`, tracked as a low-priority follow-up
> audit (no current call site emits a literal numeric code)."

Audit (this RFC, 2026-05-17) shows the surface where `Agent_sdk.Error.t`
actually crosses into HTTP today is **not** `server_mcp_transport_http`
but `server_openai_compat.ml` (OpenAI-compat surface). The transport_http
audit confirms the closeout — that file is clean. This RFC scopes the
follow-up to the one remaining lossful boundary and proposes a typed
mapping there, independent of RFC-0098's already-completed work.

## 2. Evidence (measured 2026-05-17, masc-mcp main @ `f2f3963165`)

### 2.1 transport_http confirmation (no work needed)

```
$ rg -n "(-326[0-9][0-9])" lib/server/server_mcp_transport_http.ml
(no matches)

$ rg -n "Mcp_error_code\." lib/server/server_mcp_transport_http.ml | wc -l
9
```

Typed sites: `Auth_error` × 5 (lines 321, 616, 751, 787, 837),
`Internal_error` × 4 (lines 388, 549, 558, 793). RFC-0098 PR-3 (#15793)
+ PR-4 (#15826) closure verified.

### 2.2 server/ inventory of `Agent_sdk.Error.t` ingress

```
$ rg -n "Agent_sdk.Error" lib/server/
lib/server/server_openai_compat.ml:125:    Error (Agent_sdk.Error.to_string err)
```

`server_openai_compat.ml:125` is the *sole* site in `lib/server/` that
consumes `Agent_sdk.Error.sdk_error` and converts it for HTTP delivery.
Conversion is lossful: typed kind collapses to `string` via
`Agent_sdk.Error.to_string`, dropping the discrimination required for
correct HTTP status selection.

### 2.3 Downstream amplification

The lossful string then propagates through two further layers, each
adding more flattening:

**`route_cascade` signature** (`server_openai_compat.ml:101-125`):

```ocaml
let route_cascade ~message ~system_prompt ~max_tokens ~temperature
  : (string, string) result =
  ...
  | Error err ->
    Error (Agent_sdk.Error.to_string err)
```

The `(string, string) result` shape erases the typed kind at the
function boundary, not just at the conversion call.

**`handle_chat_completions` Error arm** (`server_openai_compat.ml:185-190`):

```ocaml
match route_cascade ... with
| Ok reply ->
  (`OK, completion_response ~model ~content:reply)
| Error e ->
  (`Internal_server_error,                            (* always 500 *)
   error_response ~status:"server_error"               (* always server_error *)
     ~message:(Printf.sprintf "Cascade error: %s" e))
```

All cascade errors flatten to HTTP **500 / "server_error"**, regardless
of whether the underlying `sdk_error` was auth, rate-limit, timeout,
validation, or model-not-found.

**OpenAI envelope** (`server_openai_compat.ml:21-30`):

```ocaml
let error_response ~(status : string) ~(message : string) : string =
  Yojson.Safe.to_string
    (`Assoc [
      ("error", `Assoc [
        ("message", `String message);
        ("type", `String status);
        ("param", `Null);
        ("code", `Null);        (* typed code never emitted *)
      ]);
    ])
```

The envelope's `code` field is hardcoded `null`. Even if a typed
`sdk_error` were preserved upstream, this surface would not expose it.

### 2.4 Severity scoping

- Surface affected: OpenAI-compat surface only. MCP transport surface
  (RFC-0098 target) and dashboard surface unaffected.
- Failure mode: clients cannot distinguish retryable (rate-limit,
  timeout) from non-retryable (auth, validation) errors. All look like
  HTTP 500.
- Workaround signature alignment: typed → string compression is adjacent
  to the §워크어라운드 시그니처 #2 family (string/substring classifier),
  but presents as *typed-to-untyped collapse* rather than
  *substring-additive*. Same `Parse, Don't Validate` violation, different
  direction.

## 3. Background — why RFC-0098 closeout deferred this

RFC-0098 §8 originally listed three call sites:

1. `keeper_exec_proactive.ml:185` — no longer exists in main (moved to
   typed `Agent_sdk.Error.t`).
2. `Llm_orchestration.run_prompt_cascade` — same.
3. `server_mcp_transport_http` mapping — turned out to need no work
   (already typed via PR-1/2/3/4).

The closeout body correctly observed that the *original* plan's call
sites are all resolved. The boundary site this RFC addresses
(`server_openai_compat.ml`) was **not in RFC-0098's scope** at all — it
is a sibling surface that consumes the same `Agent_sdk.Error.t` shape
via `Masc_oas_bridge.run_with_caller`. Treating it under a separate RFC
keeps RFC-0098 Implemented and avoids re-opening a closed cycle.

## 4. Design

### 4.1 Typed mapping module (new)

```ocaml
(* lib/server/openai_compat_error_map.mli *)

(** Pure mapping from [Agent_sdk.Error.t] to OpenAI-compat HTTP envelope
    parts. No I/O, no logging — those remain at the caller. *)

type http_status =
  [ `Bad_request           (* 400: validation, malformed input *)
  | `Unauthorized          (* 401: auth missing / invalid *)
  | `Forbidden             (* 403: auth valid but not permitted *)
  | `Not_found             (* 404: model or resource not found *)
  | `Request_timeout       (* 408: client-cancelled *)
  | `Too_many_requests     (* 429: rate-limit / quota *)
  | `Internal_server_error (* 500: unclassified backend failure *)
  | `Bad_gateway           (* 502: upstream provider error *)
  | `Service_unavailable   (* 503: provider unavailable / cascade exhausted *)
  | `Gateway_timeout       (* 504: structural timeout from oas_bridge *)
  ]

type openai_error_kind = string  (* OpenAI's "type" field: invalid_request_error | authentication_error | rate_limit_error | server_error | ... *)

type t = {
  http_status : http_status;
  openai_kind : openai_error_kind;
  openai_code : string option;   (* envelope "code" — null today; this RFC populates it *)
  message     : string;          (* human-readable, derived from sdk_error *)
}

val of_sdk_error : Agent_sdk.Error.sdk_error -> t
```

The implementation `of_sdk_error` is **total** (covers every
`sdk_error` variant exhaustively — OCaml compiler enforces). Adding a
new SDK error variant breaks the build at this site, which is the
intended forcing function.

### 4.2 Callsite changes

**`route_cascade` widens the Error tag from `string` to `t`:**

```ocaml
let route_cascade ~message ~system_prompt ~max_tokens ~temperature
  : (string, Openai_compat_error_map.t) result =
  ...
  | Error err -> Error (Openai_compat_error_map.of_sdk_error err)
```

**`handle_chat_completions` Error arm consumes typed mapping:**

```ocaml
| Error mapped ->
  let { http_status; openai_kind; openai_code; message } : Openai_compat_error_map.t = mapped in
  (http_status,
   error_response ~status:openai_kind ?code:openai_code ~message)
```

**`error_response` accepts optional typed code:**

```ocaml
let error_response ~(status : string) ?(code : string option) ~(message : string) : string =
  Yojson.Safe.to_string
    (`Assoc [
      ("error", `Assoc [
        ("message", `String message);
        ("type", `String status);
        ("param", `Null);
        ("code", match code with None -> `Null | Some c -> `String c);
      ]);
    ])
```

### 4.3 What is intentionally NOT changed

- `route_keeper` (server_openai_compat.ml:115-127, sibling Keeper route)
  is **not** included in this RFC. It returns `(_, string) result` from
  a different upstream path (`Keeper_turn_driver.run_with_keeper`) that
  does not surface `Agent_sdk.Error.t`. Wider audit of that path is
  out of scope; if found lossful later, it deserves its own scoped RFC.
- `server_mcp_transport_http` is **not** touched. RFC-0098 closeout's
  observation stands.
- `Mcp_error_code` (JSON-RPC numeric code SSOT) is **not** extended.
  The mapping module above is HTTP/OpenAI-specific. JSON-RPC and HTTP
  are different envelopes with different code semantics; collapsing them
  into one type would couple two surfaces that should evolve
  independently.

## 5. Acceptance

- [ ] `Openai_compat_error_map.of_sdk_error` is total (exhaustive
      `match` over `Agent_sdk.Error.sdk_error`, no catch-all `_ ->`).
- [ ] `route_cascade` signature returns `(string, Openai_compat_error_map.t) result`
      (typed Error tag, not `string`).
- [ ] `handle_chat_completions` Error arm uses `mapped.http_status`
      (no `\`Internal_server_error` hardcode for cascade errors).
- [ ] `error_response` envelope populates `code` field with `openai_code`
      when present (no permanent `\`Null`).
- [ ] `rg -n "Agent_sdk.Error.to_string" lib/server/server_openai_compat.ml` returns 0 matches. *Scope clarification (added in implementation PR #15899)*: the lossful boundary this RFC targets is the typed→string collapse at the caller site. The mapping module `lib/server/openai_compat_error_map.ml` legitimately uses `Agent_sdk.Error.to_string` to populate the structured `message` field — that is a typed→structured projection that preserves the typed `http_status`/`kind`/`code` alongside the human-readable message, not the collapse this RFC eliminates. The acceptance check therefore narrows to the caller file.
- [ ] Unit test: every `Agent_sdk.Error.sdk_error` variant has a
      deterministic `(http_status, openai_kind)` row, verified by
      table-driven Alcotest. No mocks; map function is pure.

## 6. Test plan

1. **Unit (pure)**: `test/server/test_openai_compat_error_map.ml` —
   table-driven Alcotest covering each `sdk_error` variant. Asserts
   `(http_status, openai_kind, openai_code option)` triple per variant.
2. **Boundary (no integration)**: `test/server/test_route_cascade_error_typed.ml`
   — stub `Masc_oas_bridge.run_with_caller` returns each `sdk_error`
   variant, assert `route_cascade` propagates the *typed* mapping
   unchanged. Asserts return type is `Openai_compat_error_map.t`, not
   `string`.
3. **No integration test**: handle_chat_completions wire-up is verified
   by typechecker (signature change forces compile error on stale
   caller). Adding HTTP-level integration would couple this RFC to
   server lifecycle tests; out of scope.

## 7. Migration & rollback

- Single PR, surgical. Changes are local to `server_openai_compat.ml`
  + new `openai_compat_error_map.ml` + dune stanza addition.
- Rollback: revert the PR. No state migration, no env var, no flag.
- Behavioral compatibility: clients that previously parsed HTTP 500 +
  `"type": "server_error"` will receive richer responses (e.g., 429
  for rate-limit). This is **not** a breaking change for clients that
  follow the OpenAI client retry contract (which already distinguishes
  4xx/5xx semantics).

## 8. Why this is not a workaround

Per `software-development.md` §워크어라운드 거부 기준:

| Signature | Match? | Why |
|---|---|---|
| Counter-as-fix | No | This RFC removes the lossful boundary, doesn't instrument it |
| String classifier | No | Removes a typed→string collapse, doesn't add string match |
| N-of-M | No | Single boundary, complete migration in one PR |
| Cap/cooldown/dedup/repair | No | No symptom suppression — fixes the type-level information loss |
| Test backdoor | No | Pure map function, no test-only mutation |

The fix is structural (Parse-Don't-Validate at the boundary), single
PR, and removes an existing lossful site rather than adding any
classifier. RFC-0088 (Counter-as-Fix umbrella) rejection bar does not
apply.

## 9. Open questions

- Should `Openai_compat_error_map.t` live in `lib/server/` or
  `lib/openai_compat/`? Current proposal: `lib/server/` co-located with
  the sole consumer, until a second consumer appears. Avoids premature
  abstraction (Simple Made Easy).
- Does `Agent_sdk.Error.sdk_error` itself need any new variants for
  full HTTP coverage? Audit during implementation; if so, file upstream
  SDK issue, do not extend with `Other of string`.
