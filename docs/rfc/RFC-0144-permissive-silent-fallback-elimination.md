---
rfc: "0144"
title: "Permissive-Silent-Fallback Elimination"
status: Draft
created: 2026-05-20
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0088", "0109"]
implementation_prs: []
---

# RFC-0144 — Permissive-Silent-Fallback Elimination

## 1. Motivation

`~/me/.tmp/pr-audit-2026-05-20/AUDIT-REPORT.md` Cluster A documents an
iter-reproducible chain of 7 merged PRs that wrap silent parse failures
with a warn + Prometheus counter while explicitly preserving the
`None`/`[]`/default return value. CLAUDE.md §"워크어라운드 거부 기준"
signature #1 (Telemetry-as-Fix) classifies this exact shape as a
workaround: the counter is an *alarm*, not a *fix*.

Predecessor PRs (umbrella scope; not modified by this RFC):

| PR | Site | Fallback shape |
|---|---|---|
| #15820 | `mcp-ws` SSE parse | `\| exception _ -> None` |
| #15840 | `cascade-http-probe` (iter 29) | same |
| #15866 | `sidecar schema_field_types` | `\| exception _ -> []` |
| #15883 | `bg_task drain_fd_to_buf` (iter 30) | `\| exception _ -> true` |
| #15980 | `memory_jsonl parse_line` (RFC-0109 V15) | `-> None` with closed reason vocab |
| #15781 | `keeper_memory_recall` load-history | `-> None` |
| #15954 | `tool_keeper.cache_ttl_seconds` env parse | wildcard fallback to default |

Each PR is reproducible: the *next* parse site repeated the same shape,
demonstrating that the pattern is being learned as a precedent.

## 2. Pattern definition

The targeted pattern is:

```ocaml
match f input with
| value -> handle value
| exception _ -> None  (* or [] or default *)
```

This swallows every exception (Yojson, Unix, Sys, *any future exception
introduced by `f` or its dependencies*). Callers receive `None` and
cannot distinguish "input invalid" from "parser bug" from "FD closed
mid-read" from "cancellation".

## 3. Anti-goals

This RFC does NOT:

- Remove `Eio.Cancel.Cancelled` re-raise semantics. Cancellation is
  re-raised, never absorbed.
- Centralize all error types into a single sum. Each call site keeps
  its own domain error type; `Parse_outcome` is a *boundary helper*,
  not a unifier.
- Mandate Yojson as a base dependency. The helper must be linkable
  from sub-libraries that do not use JSON at all.
- Touch the 7 predecessor PR sites except for #15954 as the
  demonstration site. Migration is one PR per site.

## 4. Design

### 4.1 Helper module

`lib/parse_outcome/` — stdlib + Eio only, no Yojson link dependency.

```ocaml
type error =
  [ `Json_parse_error of string
  | `Other of exn ]

type 'a t = ('a, error) result

val parse_safe : (string -> 'a) -> string -> 'a t
val of_exn    : exn -> error
val bind      : 'a t -> ('a -> 'b t) -> 'b t
val map       : ('a -> 'b) -> 'a t -> 'b t
val to_option : 'a t -> 'a option   (* migration shim only *)
```

### 4.2 Cancellation protocol

```ocaml
let parse_safe f s =
  try Ok (f s)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (of_exn exn)
```

`Eio.Cancel.Cancelled` MUST re-raise. Test
`test/test_parse_outcome.ml::cancellation` pins this property.

### 4.3 Yojson without a link

`of_exn` recognises `Yojson.Json_error` by `Printexc.exn_slot_name`
string comparison. Sites that already link Yojson can keep their typed
exception handling and use `parse_safe` for the residual catch-all
boundary; sites that do not link Yojson still get a useful
`` `Other exn`` payload.

### 4.4 Why this is not itself a workaround

CLAUDE.md signatures 1–3 require the change to *suppress* visibility or
*add* a classifier without removing the underlying ambiguity. The
opposite holds here:

- The wildcard `| _ -> None` is replaced with an exhaustive
  `match … with Ok | Error (`Json_parse_error _ | `Other _)`. New
  failure modes surface at the call site, not in a counter.
- Compiler enforces dispatch. A caller that drops `Error` must do so
  via `to_option`, which is intentionally named to signal the
  migration shim status.

## 5. Migration plan

Migration order is lowest-call-site-count first. Each site is a
separate PR; this RFC is the umbrella. Predecessor PRs are not
reverted; their counter remains until the site migrates and is removed
in the per-site closeout commit.

| Order | Site | Predecessor PR | Notes |
|---|---|---|---|
| 1 | `tool_keeper.cache_ttl_seconds` | #15954 | **Included in this PR as demonstration.** |
| 2 | `keeper_memory_recall` load-history | #15781 | Single caller; bounded label already in place. |
| 3 | `bg_task drain_fd_to_buf` | #15883 | EOF-shaped fallback; demands `Unix_error` classification. |
| 4 | `sidecar schema_field_types` | #15866 | Returns `[]`; `to_option` shim acceptable transitionally. |
| 5 | `mcp-ws` SSE parse | #15820 | Hot path; benchmark before/after. |
| 6 | `cascade-http-probe` | #15840 | Mirror of #5. |
| 7 | `memory_jsonl parse_line` | #15980 | RFC-0109 V15 — coordinate with that RFC's closeout. |

## 6. Sunset criteria

This RFC moves to `Implemented` when:

1. 6 of 7 sites are migrated to `Parse_outcome.parse_safe`.
2. The per-site Prometheus counter from the predecessor PR is removed
   in the same per-site migration PR (no counter outlives its
   workaround tracker).
3. A grep gate in CI rejects new `| exception _ -> (None|\[\]|true)`
   patterns introduced after this RFC merges. The remaining 1-of-7
   site is permitted only if it has an active dependency RFC blocking
   its migration.

## 7. Override exemption (transitional)

Until per-site migration, the 7 predecessor PRs' counters remain.
They are tracked as legacy in §5 and do not require the standard
`WORKAROUND:` label retroactively. New sites added under this RFC
MUST NOT introduce a counter alongside `Parse_outcome` — the typed
error is the operator-visible signal.

## 8. Out of scope

- Backpressure for FD parse storms (separate concern; see Cluster B
  audit findings).
- Yojson protocol-level enforcement at the write side (RFC-0107 +
  RFC-0109 family).
- Removing catch-all `_ ->` arms in non-parse code (RFC-OAS Cluster C
  candidate).

## 9. Risk

- `Printexc.exn_slot_name`-based classification is a string match. If
  the Yojson maintainers rename the constructor, `of_exn` silently
  falls back to `` `Other``. Mitigation: the contract is documented as
  best-effort; consumers that *require* typed Yojson errors should
  link Yojson and classify explicitly.
- `to_option` provides a migration shim that re-introduces the
  ambiguity. It is named and documented as such; CI may add a
  `--warn-on Parse_outcome.to_option` lint after sunset.

## 10. Implementation in this PR

- `lib/parse_outcome/dune` + `parse_outcome.mli` + `parse_outcome.ml`.
- `test/test_parse_outcome.ml` covers Ok / Error / `of_exn` /
  bind / map / to_option / Cancellation-reraise (Alcotest + Eio_main).
- `lib/tool_keeper.ml` `cache_ttl_seconds` migrated as demonstration
  site #1. Predecessor counter preserved (per §7).
- `lib/dune` adds `masc_mcp.parse_outcome` to the main library
  dependency list.
