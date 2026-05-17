---
title: RFC-0107 Prior Art — piaf / Ocsigen-Eio / cohttp keep-alive / Eio FD safety
date: 2026-05-17
relates_to: RFC-0107
status: research
confidence: medium-high (5/5 references fetched, 2 only partially)
---

# 1. Five references summarized

| # | Source | Fetch | One-line takeaway | RFC-0107 section mapping |
|---|---|---|---|---|
| 1 | piaf (anmonteiro) GitHub source + `piaf.mli` | OK (full read of `lib/client.ml`, `lib/connection.ml`, `lib/config.ml`, `lib/piaf.mli`) | piaf has **no multi-host connection pool**; `Client.t` is a *per-endpoint* persistent client whose lifetime is bound to a user-supplied Switch. Idle eviction / `idle_ttl` / `max_idle` do not exist. | §3.1 transport candidate, §3.2 L2 pool design (we have to build pool *on top of* piaf; we do not get it for free) |
| 2 | Tarides Ocsigen→Eio announcement (2025-03-13) | Partial (announcement only, no technical retrospective) | The 2025-03-13 post is an *announcement*, not a retrospective. The substantive Eio-migration tooling lessons live in the 2026-03-05 follow-up `ciao-lwt` post. | §1.3 Switch hierarchy gap (only thin signal) |
| 2b | Tarides ciao-lwt follow-up (2026-03-05) | OK | Main concrete lesson: **implicit forks** are the dominant Lwt→Eio migration trap; type-checker is the principal validator. No concrete FD-leak / Switch-hierarchy bug stories yet. | §1.3 (weak — implicit-fork pattern ≠ our FD-pinning bug, but adjacent) |
| 3 | ocaml-cohttp issue #85 "Support HTTP Keep-Alive" | OK | **Closed 2014.** Resolved for `cohttp-lwt` + `cohttp-async` only (PR #88, rgrinberg + avsm). `cohttp-eio` is **not** covered — see §4 for the open cohttp-eio FD/close issues. | §3.1 — `cohttp-eio upstream patch` candidate is **not viable**: keep-alive work is finished, cohttp-eio inherited none of it |
| 4 | Eio issue #244 "close: file descriptor used after calling close!" | OK (header + body via `gh api`, comments thread empty/locked) | **Server-side bug** in `Eio.Net.accept_fork` (Eio 0.3, June 2022), closed 2022-07-01 via PR #245. Talex5 author. Workaround quoted verbatim: *"avoid manually closing the socket (there's no very good reason to continue handling a connection after closing it)"* | §1.2 — supports our hypothesis that Eio's response to "FD used after close" is structural (own the close path), not lock-the-FD. Phase C TLA+ motivation. |
| 5 | Eio.Switch official docs | OK | Five axioms cleanly quoted (see §6). The key invariant is "**The resource cannot outlive its switch.**" on_release runs LIFO, under `Cancel.protect`, after all child fibers finish. | §3 axiom for every L2/L3 design |

# 2. piaf — switch-lifetime-bound *per-endpoint* client (not a pool)

## 2.1 What piaf actually is

From `lib/piaf.mli` (verbatim):

> There are two options for issuing requests with Piaf:
>   + client: useful if multiple requests are going to be sent to the remote endpoint, avoids setting up a TCP connection for each request. Or if HTTP/1.0, you can think of this as effectively a connection manager.
>   + oneshot: issues a single request and tears down the underlying connection once the request is done. Useful for isolated requests.

And the `Client.create` doc says:

> A client instance represents a connection to a **single remote endpoint**, and the remaining functions in this module will issue requests to that endpoint only.

Translation: piaf gives **single-host keep-alive** + **redirect-aware reconnect**, not a `Host → Pool[Connection]` data structure.

## 2.2 The Client.t shape (`lib/client.ml:38`)

```ocaml
type t =
  { mutable conn : Connection.t  (* single connection, mutated on reconnect *)
  ; env : Eio_unix.Stdenv.base
  ; sw : Switch.t                 (* captured user switch *)
  }
```

Pool semantics live in `reuse_or_set_up_new_connection` (client.ml:~190) and key off two flags:

- `conn.persistent : bool` — set from `Request.persistent_connection request` on every `call`, then later refreshed from `Response.persistent_connection response`. Inherits `Connection: close` semantics from httpun/h2.
- `Http_impl.is_closed` — checked before reuse.

The decision tree:

```
if (not persistent) || is_closed connection
  then change_connection  (* fork shutdown + open new *)
else if equal_without_resolving info new_info
  then reuse                (* same host/port/scheme *)
else if equal info new_info (* after DNS *)
  then reuse
else
  change_connection
```

**Critical**: this is per `Client.t`, not a global pool. If you want a host → N connections pool, you must wrap `Client.t` yourself.

## 2.3 Switch lifetime binding (the part RFC-0107 actually needs)

piaf binds resources to switches in two places:

1. **`Client.create ~sw env uri`** captures the user's `Switch.t` into `t.sw`. All forked work (`Fiber.fork ~sw:t.sw`) — including async shutdown of stale connections during redirects (`change_connection`, client.ml:~165) — is bound to it.
2. **`Eio.Net.connect ~sw network address`** in `Connection.connect` (connection.ml:~190) binds the socket FD to the same switch.

This means: when the user-provided switch finishes, *all* live FDs from this client are released by Eio. piaf does no manual `Eio.Flow.close` on the FD in the happy path — it relies on the switch contract (§6). `shutdown_conn` calls `Http_impl.shutdown` (which closes the underlying gluten runtime), but Eio's switch is still the FD's owner of record.

## 2.4 Idle eviction / TLS context caching: **absent**

- `Config.t` (config.ml:38–105, verbatim full struct read) has **no** `idle_ttl`, `max_idle`, `keep_alive_timeout`, `pool_size` fields. The closest fields are `connect_timeout : float`, `buffer_size`, `body_buffer_size`.
- TLS context: `Openssl.connect` is called *per connection open* in `create_https_connection` (client.ml:~75). The returned `ssl_ctx` rides inside `Connection.t`. There is no `Ssl.Context.t` cache at the Client layer — each new TCP connect rebuilds it.

## 2.5 h1 + h2 + ALPN + WebSocket

- h1: `lib/http1.ml` (httpun)
- h2: `lib/http2.ml` (h2 library)
- ALPN: `Versions.ALPN`, negotiated in `create_https_connection`
- WebSocket: `Ws` module + `Client.ws_upgrade` (yes, present)
- h2c upgrade: `Config.h2c_upgrade`

Pro: full protocol surface, including h2 multiplexing (we'd benefit on /v1/messages, /v1/responses).

Con: SSL stack is openssl (via `eio-ssl` + native bindings). Adds a transitive on `eio-ssl`, `openssl` C lib. Compare to `mirage-crypto` / `tls` (pure OCaml) used by `http-mirage-client`.

## 2.6 Activity

- Last release: 0.2.0 (2024-09-06). ~256 commits on master. Active maintainer (anmonteiro = author of httpun, h2, gluten). Not abandoned.
- Open issues search for `pool`, `keep-alive idle`, `connection pool` returned **zero** hits — confirming piaf does not advertise itself as a pool library.

# 3. Tarides Ocsigen → Eio: signal vs noise

## 3.1 What we got

| Post | Date | Useful for RFC-0107? |
|---|---|---|
| "We're Moving Ocsigen from Lwt to Eio!" | 2025-03-13 | No technical content — pure announcement. Names Eliom / Js_of_ocaml / Ocsigen Server / Lwt as migration scope. Funded by NLnet / NGI Zero Core. |
| "Announcing `ciao-lwt`" | 2026-03-05 | Some signal: the dominant migration pitfall is **implicit forks** (Lwt promises that get scheduled by `bind` rather than an explicit `fork`). Repo: github.com/tarides/ciao-lwt. |

## 3.2 What's missing (and why)

Neither post documents:
- Switch hierarchy bugs
- FD leak patterns uncovered during migration
- Connection-pool design lessons
- Concrete cancellation propagation mistakes

The 2026-03-05 post explicitly says "Your resulting code will likely not typecheck" — implying that they're treating the OCaml compiler as the primary correctness gate, not a retrospective on runtime failures.

**Implication for RFC-0107 §1.3**: We cannot lean heavily on Tarides as prior art for our specific Switch-hierarchy / FD-pinning concerns. The ciao-lwt repo source itself may contain transformation rules worth a Phase C revisit. **확인 필요**: read `github.com/tarides/ciao-lwt` source for any "wrap in Switch.run" or "attach to switch" rewrite rules.

# 4. cohttp issue #85 status (as of 2026-05-17)

**Status: CLOSED 2014-era. Keep-alive landed for cohttp-lwt + cohttp-async only.**

Verbatim comment thread from `gh issue view 85`:

1. rgrinberg: *"I believe the lwt server Keep-Alive so this only applies to the Async backend"*
2. rgrinberg (correction): *"cohttp/lwt only supports keep-alive behaviour against http 1.1 clients. It does not respect 'connection: keep-alive' from http 1.0 clients. It also does not send 'connection: close' headers when it should."*
3. rgrinberg: *"P.S. I'm making an attempt to make the async backend support persistent connections at #88..."*
4. avsm: *"#88 has been merged now, but we still need to add some keep-alive test cases"*
5. rgrinberg: *"Some tests have been added as well now."*

PR #88 was merged. Issue closed.

**Why this is not enough for cohttp-eio**: `cohttp-eio` is a newer (2022+) backend, written independently from cohttp-lwt/async. Adjacent open issues confirm cohttp-eio's client side has no keep-alive and active FD-handling problems:

| Issue | State | Date | Summary |
|---|---|---|---|
| #965 cohttp-eio: "handle used after calling close" | OPEN | 2023-02-02, 12 comments | FD-after-close panics on body > a few KB; smondet repro. Mirrors masc-mcp's `connection: close` workaround. |
| #1121 cohttp-eio `expert` mode doesn't allow closing of the stream | OPEN | 2026-03-01 | `Eio.Buf_read` has no close, workaround = `exception Die`. |
| #676 How to close connections? (cohttp client) | OPEN | 2022-01-02 | Long-standing close-API gap. |
| #1101 cohttp-eio: take executor pool instead of creating domains | CLOSED | 2024-12-29 | Pool of *domains*, not connections. |

**Decision unblocked**: `cohttp-eio upstream patch` is **not viable** as our L1 transport for RFC-0107. We would inherit known open FD bugs and zero keep-alive. piaf direct.

**Confidence**: HIGH (issue #85 comment thread fully fetched; #965/1121 metadata fetched).

# 5. Eio issue #244 — Unix FD safety, ground truth

## 5.1 What the issue actually says

Verbatim body from `gh api repos/ocaml-multicore/eio/issues/244`:

> In Eio 0.3 `accept_fork` always closes then socket when the function returns. However, the function is supposed to be allowed to close it itself first if it wants to. This results errors such as:
>
> &nbsp;&nbsp;&nbsp;&nbsp;`Error handling connection: Cancelled: Invalid_argument("close: file descriptor used after calling close!")`
>
> A work-around is to avoid manually closing the socket (there's no very good reason to continue handling a connection after closing it).

Closed: 2022-07-01 via PR #245. Author: talex5 (Eio lead).

## 5.2 What it actually demonstrates (the part useful for RFC-0107)

The `Invalid_argument("close: file descriptor used after calling close!")` exception is **OCaml's `Unix.close` panicking on double-close**. The user (talex5 himself, who maintains both Eio and the cohttp-eio shim) hit it because the Eio scheduler was closing the FD that user code had already closed.

This is the *exact same* error class as the cohttp-eio #965 bug ("handle used after calling close"). The fix wasn't "add a guard around close" — it was changing the `accept_fork` API so the scheduler *does not pre-emptively close*.

## 5.3 Implications for libraries wrapping raw Unix sockets

The pattern Eio enforces, post-#244:

1. **Exactly one owner** per FD. Either the scheduler closes it (on switch finish) or user code closes it explicitly, never both.
2. **No double-close panic recovery**. There is no `try Unix.close fd with _ -> ()` pattern endorsed by Eio — instead, the API surface is shaped so it never happens.
3. **Talex5 quote on the workaround** (verbatim above): *"A work-around is to avoid manually closing the socket (there's no very good reason to continue handling a connection after closing it)."*

## 5.4 What's NOT in the issue (caveat)

The originally hypothesised statement *"OCaml's Unix module is not safe, possible to leak FDs"* is **not present verbatim in issue #244**. That phrasing may come from talex5's Eio README or talks (Eio README WebFetch attempt did not surface it either — see §6 caveat). For RFC-0107 quoting purposes, we should attribute the FD-ownership rule to:

- `Eio.Switch` doc (§6 below) — formal invariant
- Eio issue #244 — concrete bug + endorsed workaround
- *Not* to a "Unix module is unsafe" quote (확인 필요 — likely a talk/discussion comment, not in headline docs)

## 5.5 Phase C TLA+ spec motivation

We can cite Eio #244 directly as the *prior art* for "exactly-one-owner" as a TLA+ invariant. The state-space we'd model:

```
FdOwnership ∈ [fd → {SchedulerOwned, UserOwned, Closed}]
NoDoubleClose ≡ ∀ fd : owner state transitions never go Closed → Closed
ExactlyOneCloser ≡ Cardinality({s ∈ History : s closes fd}) ≤ 1
```

This is materially the same property Eio's design enforces operationally via Switch.

# 6. Eio.Switch contract — resource lifetime axiom

Verbatim from the Eio.Switch ocamldoc:

| Property | Quote |
|---|---|
| Lifetime invariant | **"The resource cannot outlive its switch."** |
| `run` signature | `val run : ?name:string -> (t -> 'a) -> 'a` |
| `run` contract | "When `fn` finishes, `run` waits for all fibers registered with the switch to finish, and then releases all attached resources." |
| `on_release` ordering | "Release handlers are run in LIFO order, in series." |
| `on_release` execution timing | "Hooks run once `t`'s main function has returned and all fibers have finished." |
| `on_release` cancellation immunity | "They execute within `Cancel.protect`, preventing cancellation interruption during cleanup." |
| Cancellation propagation | "[`fail`] cancels all fibers attached to the switch and, once they have exited, reports the error." It "ensures that the switch's cancellation context is cancelled, to encourage all fibers to exit as soon as possible." |
| Outlasting parent switch | Prevented by API shape: resources "require a switch to be provided when they are created"; functions cannot return resources whose switch finishes first. |

**Caveat**: the broader README-level Eio docs ("Switches and resources" section, full `rationale.md`) could not be fetched with our tools (WebFetch returned summarised/truncated content for GitHub source pages). The 7 quotes above all originate from the ocamldoc page `ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html`.

## 6.1 RFC-0107 axiom mapping

| RFC-0107 design choice | Eio.Switch backing |
|---|---|
| L1 transport must accept a `~sw` argument | "resource cannot outlive its switch" — every FD must have a switch |
| L2 pool's `acquire` returns a connection bound to a *child switch* | `Switch.run` nesting; child switch finishes before parent → connection cleanup deterministic |
| L3 client API never returns an FD past the user's `Switch.run` boundary | API shape rule (§6 bottom row) |
| Backpressure / cancellation | `fail` propagates structurally; we lean on `Cancel.protect` for the release path |

# 7. RFC-0107 §3.1 transport candidate ranking (informed by §2–§6)

| 후보 | h1 / h2 / ws | per-host KA | TLS context caching | switch-clean exit | dependencies | recommendation |
|---|---|---|---|---|---|---|
| **piaf 0.2.0** | h1 + h2 + ws + h2c + ALPN | YES (single conn, redirect-aware) | NO (per-connect) | YES (sw threaded through) | httpun, h2, gluten, eio-ssl, openssl C | **DEFAULT L1 candidate**. We build pool/idle eviction/TLS-ctx cache *on top* (L2). Mature maintainer, no abandoned issue queue, full HTTP/2 we need for Anthropic. |
| **cohttp-eio + upstream patch** | h1 only (cohttp-eio); h2 separate library | NO (open issues #676/#965/#1121, no roadmap) | N/A | UNRELIABLE (double-close bug class) | mirage-cohttp ecosystem | **REJECT**. Issue #85 keep-alive work is closed but only covers lwt/async backends; cohttp-eio has known FD-hygiene bugs (§4 table). |
| **http_eio (experimental)** | varies | unclear | N/A | unclear | n/a | **REJECT** (experimental, no production uptake, drops upstream-pressure leverage) — confirm in Phase C if surfaced. 확인 필요: no canonical "http_eio" library was found in our searches, this name may be a placeholder. |
| **http-mirage-client (robur)** | h1 + h2 via paf+h2 | host-pinned, MirageOS-flavoured | mirage-crypto-based | YES (mirage style) | mirage stack | **DEFER**. Cleaner TLS story (no openssl C), but MirageOS-shaped API; mismatches our Eio-direct calling convention. Re-evaluate if `eio-ssl` proves a pain. |

**Decision**: piaf 0.2.0 as L1. RFC-0107 §3.2 (L2 pool) must build:
1. `Host_key.t = { host : string; port : int; scheme : Scheme.t }` → `(Client.t * idle_since : float) Eio.Stream.t` (or queue).
2. `idle_ttl` field on our pool config; eviction fiber that closes Client.t whose `idle_since` exceeds TTL.
3. `Ssl.Context.t` cache, since piaf rebuilds per connect.
4. `Switch.t` per pool-entry (child of user's switch), so `Pool.release` can `Switch.fail` to evict.

# 8. Anti-prior-art (피해야 할 패턴)

Patterns that surface in §2–§6 and that RFC-0107 must NOT replicate:

1. **자체 connection pool 재구현**
   - Don't write a per-piaf-Client.t custom pool layer that ignores piaf's own redirect-reconnect logic. Use `Client.t` as the *unit* in the pool and let piaf own intra-host state.
   - Don't add a second FD-ownership owner. Piaf already owns the FD via the user's `~sw`. Our pool wrapper *attaches a child switch*, never closes the FD directly.

2. **자체 Switch 추상화 wrapper**
   - Don't invent a `Pool_switch` type. Use `Eio.Switch.t` directly; if we need richer events (idle-timer firing → close), add an `Eio.Condition` or fiber, not a new type.
   - Don't bypass `Switch.run`'s LIFO `on_release` ordering with manual cleanup queues.

3. **자체 FD 회계 시스템**
   - Don't track FDs by integer ID. Eio's typed `Eio.Net.stream_socket` *is* the accounting unit. Our metrics (`fd_high_watermark`, `connections_idle`) should derive from pool-entry counts, not from `getrlimit` polling.
   - Don't add `try Unix.close fd with _ -> ()` defensive code. Eio #244's lesson: shape the API so the single owner is unambiguous.

4. **`cohttp-eio` 기반 keep-alive 시도**
   - Wasted move (§4). Issue #85 is closed; cohttp-eio has not inherited it; #965/#676/#1121 are open and the failure mode mirrors our existing `connection: close` workaround in `lib/masc_http_client/masc_http_client.ml:13`.

5. **TLS handshake per request**
   - Don't accept piaf's per-connect `Openssl.connect` as the steady state. Cache `Ssl_ctx` at L2; only rebuild on cert/CA rotation.

6. **자체 텔레메트리-as-fix counters around FD lifecycle**
   - Per `software-development.md` §워크어라운드 거부 기준 / signature #1: a `fd_double_close_counter` is a workaround, not a fix. The Phase C TLA+ spec (`NoDoubleClose`) is the structural answer.

---

## Appendix A — Fetch status table

| Ref | URL | Method | Result |
|---|---|---|---|
| piaf README | github.com/anmonteiro/piaf | WebFetch | OK (truncated, sufficient) |
| piaf source | raw.githubusercontent.com/.../master/lib/{client,connection,config,piaf.mli,http_impl}.ml | `curl -o` then read | OK (full files, primary evidence source) |
| Tarides 2025-03-13 | tarides.com/blog/2025-03-13-... | WebFetch | OK (announcement, low signal) |
| Tarides 2026-03-05 ciao-lwt | tarides.com/blog/2026-03-05-... | WebFetch | OK (some signal — implicit forks) |
| Tarides blog index | tarides.com/blog | WebFetch | OK (surfaced the 2026-03-05 follow-up) |
| cohttp #85 | gh api / gh issue view | gh CLI | OK (full comment thread, 5 comments) |
| cohttp-eio adjacent issues | gh issue list | gh CLI | OK (titles + dates) |
| Eio #244 | gh api repos/ocaml-multicore/eio/issues/244 | gh CLI | OK (body verbatim; comments endpoint returned empty — talex5 self-closed via PR #245) |
| Eio.Switch docs | ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html | WebFetch | OK (7 verbatim quotes obtained) |
| Eio rationale.md | github.com/.../doc/rationale.md | WebFetch | PARTIAL (focused on 4 design topics, not on FD safety wording) |
| Eio README "Switches and resources" | github.com/.../README.md | WebFetch | PARTIAL (could not surface verbatim "resource cannot outlive its switch" wording at README level — confirmed only in Switch ocamldoc) |

## Appendix B — Items requiring future verification (확인 필요)

1. *"OCaml's Unix module is not safe"* phrasing: probably a talex5 talk/discussion comment, not in headline docs. If RFC-0107 wants to cite it, find the original (eio mailing list, Discuss thread, or RWO talk transcript).
2. `http_eio` as a candidate library: no canonical project surfaced under this name. If RFC body has it, replace with concrete name or drop.
3. `ciao-lwt` source-level transformation rules: the blog hints at "wrap with explicit fork" but does not enumerate. Phase C may benefit from reading `github.com/tarides/ciao-lwt` rules/AST directly.
4. piaf 0.2.0 → 0.3.x roadmap: anmonteiro/piaf may have unreleased master-branch features (we read `master`, not a tag). Cross-check before pinning a specific opam version in Phase D.
