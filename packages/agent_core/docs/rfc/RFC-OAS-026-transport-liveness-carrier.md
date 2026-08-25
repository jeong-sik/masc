# RFC-OAS-026: Transport Liveness Carrier (stream-idle deadline through the transport boundary)

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-06-09 |
| Target | `agent_sdk` (oas) + masc consumer |
| Invariant | I2 (the only legitimate timeout is the provider transport idle/connect timeout; no heuristic per-turn/wall-clock deadlines as control flow) |
| Sibling | RFC-OAS-019 (stream-lifecycle-aggregation), RFC-OAS-020 (ttft-instrumentation) |
| Audit source | `/Users/dancer/me/.tmp/masc-fiber-audit-2026-06-09/DIAGNOSIS.md` §3 (S1), §5, §F1 |

## 0. Summary

A streaming liveness deadline has two halves — an inter-chunk idle timeout (a `float`, data) and an Eio `clock` (a capability) — and `read_sse` arms the timeout only when **both** are present (http_client.ml:771-773). The OAS streaming dispatch carries both down the *built-in HTTP* (`None`-transport) path, but the **idle half is structurally dropped at the transport boundary**: when a caller supplies a `Llm_transport.t` (the production path for masc keepers), the dispatch's `Some t` arm passes only `{ config; messages; tools }` into `t.complete_stream` — there is no field on `completion_request` and no parameter on `complete_stream` to carry the idle deadline. The transport falls to `read_sse … ?idle_timeout:None` → bare `Eio.Buf_read.line` with no per-line deadline. A provider that stops mid-stream with the socket held open hangs the read; the only backstop is a masc-side 1800s heuristic attempt watchdog, exactly the timeout I2 forbids. This is the mechanism of the 2026-06-08 fleet stall (DIAGNOSIS §3, 1772s ≈ 1800s cap), confirmed below to have run on a pre-0.204.5 SDK where the idle half was fully dropped.

**Current live state (not the historical incident state)** — three distinct defects, plus a clock-side hole this RFC does not fully close:

1. The dispatch `Some t` arm discards the high-level idle argument (complete.ml:1671-1690), unchanged through v0.204.5.
2. `transport_openai_compat.create` builds a transport that closes no clock over construction (transport_openai_compat.ml:68), so a caller through it reaches the bare-read hang.
3. The dropped idle deadline is *representable* — a transport author who forgets the construction-capability silently reintroduces the hang. `agent_sdk` v0.204.5 (released 2026-06-09 01:53, after the incident) patched the *symptom* for masc's own transport by closing `clock`/`stream_idle_timeout_s` over `make_http_transport`; it did not close the root.
4. **Clock-side silent-disarm (orthogonal to the idle carrier, §4.6)**: masc derives the clock as `match Process_eio.get_clock () with Ok c -> Some c | Error _ -> Eio_context.get_clock_opt ()` (runtime_agent.ml ~365, ~471), and both yield `None` when their runtime state is uninitialised. A `None` clock disarms `read_sse` regardless of the idle field. F1's idle carrier closes defects 1–3; the clock half requires a separate fail-fast (§4.6), or the idle deadline can still be silently disarmed.

This RFC adds a typed idle carrier to `completion_request` so the idle deadline travels *as data through the dispatch the same record already passes*, making the idle drop unrepresentable (Parse, don't validate), and specifies a clock fail-fast (§4.6) so a configured deadline with no clock is an error, not a silent no-op. It arms the I2-legitimate inter-chunk idle detector that already exists in `read_sse`; it introduces no new heuristic. Precedent: httpx exposes connect + per-chunk read timeouts with no wall-clock total; gRPC propagates a deadline as a field across every boundary.

## 1. Problem (line-pinned)

Verified against:
- oas `main` HEAD `3ab74d58` (release 0.204.3)
- oas tag `v0.204.5` (the version masc pins: `masc.opam:31 (agent_sdk {>= "0.204.5"})`, `dune-project:56`)
- masc HEAD `c3f308a`

### 1.1 The carrier does not exist on the transport boundary

`oas lib/llm_provider/llm_transport.ml:28-33` — `completion_request` has four fields, none liveness-bearing:

```ocaml
type completion_request =
  { config : Provider_config.t
  ; messages : Types.message list
  ; tools : Yojson.Safe.t list
  }
```

`oas lib/llm_provider/llm_transport.ml:93-100` (and the contract in `llm_transport.mli:63-70`) — the transport interface's `complete_stream` takes only `?on_telemetry` and `~on_event` besides the request:

```ocaml
type t =
  { complete_sync : completion_request -> sync_result
  ; complete_stream :
      ?on_telemetry:(Telemetry_event.t -> unit)
      -> on_event:(Types.sse_event -> unit)
      -> completion_request
      -> stream_result
  }
```

There is no slot — neither a record field nor a labeled parameter — through which a clock or idle deadline can reach the transport implementation.

### 1.2 The dispatch drops liveness on the transport arm

`oas lib/llm_provider/complete.ml:1671-1690` — the high-level `complete_stream` (whose own signature accepts `?clock` and `?stream_idle_timeout_s`, complete.ml:1638-1639) branches:

```ocaml
match transport with
| Some t ->
  t.complete_stream
    ?on_telemetry:transport_on_telemetry
    ~on_event
    { Llm_transport.config = request_config; messages; tools }
| None ->
  complete_stream_http
    ~sw ~net
    ?clock                 (* <- present *)
    ?stream_idle_timeout_s (* <- present *)
    ?on_telemetry ~metrics
    ~config:request_config ~messages ~tools ~on_event ()
```

The `None` arm threads `?clock` and `?stream_idle_timeout_s` into `complete_stream_http`. The `Some t` arm cannot — there is nowhere to put them (§1.1) — so both are **structurally discarded**. This is unchanged between 0.204.3 and v0.204.5 (verified `git show v0.204.5:lib/llm_provider/complete.ml`).

The high-level call site populates both: `oas lib/pipeline/pipeline_stage_route.ml:90-95` passes `?clock`, `?stream_idle_timeout_s:agent.options.stream_idle_timeout_s`, and `?transport:agent.options.transport`. When `transport` is `Some _` (the keeper path), the idle deadline the operator configured is silently lost at the dispatch.

### 1.3 The read degrades to a deadline-free line read

`oas lib/llm_provider/http_client.ml:759-792` — `read_sse` arms the idle deadline only when **both** clock and idle_timeout are present:

```ocaml
let read_sse ?clock ?idle_timeout ~reader ~on_data () =
  ...
  let read_meaningful_line () =
    let rec inner () =
      let line = Eio.Buf_read.line reader in
      if is_keepalive_comment line then inner () else line
    in
    match clock, idle_timeout with
    | Some c, Some t -> Eio.Time.with_timeout_exn c t inner   (* armed *)
    | Some _, None | None, Some _ | None, None -> inner ()    (* bare line read *)
  in
  ...
```

With liveness dropped at §1.2, the transport reaches the `None, None` arm: `Eio.Buf_read.line reader` with no per-line deadline. The loop returns only on `End_of_file` (http_client.ml:789), which fires on socket EOF/RST — not on a provider that goes silent mid-stream with the socket held open. That stall has no OAS-side escape.

### 1.4 The 0.204.5 partial fix and its residual gap

`agent_sdk` v0.204.5 changed `make_http_transport` to close `clock`/`stream_idle_timeout_s` over construction (verified `git show v0.204.5:lib/llm_provider/complete.ml:1719`):

```ocaml
let make_http_transport ?clock ?stream_idle_timeout_s ?body_timeout_s ~sw ~net () : Llm_transport.t =
  { ...
  ; complete_stream =
      (fun ?on_telemetry ~on_event req ->
        complete_stream_http ~sw ~net ?clock ?stream_idle_timeout_s ...) }
```

At v0.204.5, masc consumed this by building the transport with `make_http_transport ?clock ?stream_idle_timeout_s ?body_timeout_s ~sw ~net ()`, so its keeper transport was armed via the closed-over capability. masc also set the SDK side through `Builder.with_stream_idle_timeout`, populating `agent.options.stream_idle_timeout_s` read by the pipeline.

Two defects remain:

1. **The dispatch still drops the high-level liveness** (§1.2). masc only escapes because its transport closed the clock over itself, not because the dispatch preserves the deadline. Any caller that passes the high-level `?stream_idle_timeout_s` *and* a transport that did not close one over gets silent drop.
2. **`transport_openai_compat.create` builds an unarmed transport** — `git show v0.204.5:lib/llm_provider/transport_openai_compat.ml:68`: `Complete.make_http_transport ~sw ~net ()` with no clock/idle closed over. A caller using this transport reaches the §1.3 bare-read hang. This is a latent reproduction of the original defect, sitting in the SDK.

The construction-capability is a per-transport-author obligation enforced by nobody: the dropped-deadline is *still representable*. F1 makes it unrepresentable at the boundary.

## 2. Goal

1. Add a typed liveness carrier to `Llm_transport.completion_request` so a stream-idle deadline travels as data through the dispatch — the dispatch cannot drop what it must pass through.
2. Thread the carrier from `completion_request` into `read_sse`/`read_ndjson` so a stalled stream raises the typed `Eio.Time.Timeout` → mapped to `Http_client.TimeoutError` → `Retry.Timeout` / `Llm_provider.Error.Timeout` → keeper FSM `Cancelled_provider_timeout`.
3. Arm only the inter-chunk idle detector that already exists. Introduce no new wall-clock or per-turn deadline.
4. Ship the OAS change back-compatible (no simultaneous masc compile break): a new optional field on a record threaded by functional update, released as a minor `feat`, then masc pins and populates it.

## 3. Non-goals

- Removing or re-tuning the masc 1800s attempt watchdog or the 1800s livelock stuck-age threshold. Those are downgraded from load-bearing to dormant by this RFC (DIAGNOSIS §5) and re-tuned in a *follow-up* (F2 in the audit). Reordering — touching the watchdog before this lands — resurrects the I1 infinite hang. See §7.
- Adding a wall-clock total-stream deadline. I2 forbids it; httpx omits it deliberately (§8).
- Changing `complete_stream_http`'s own `?clock ?stream_idle_timeout_s` parameters; they already work on the `None` arm. This RFC only makes the `Some t` arm equivalent.
- The `Discovery.discover` clock gap (audit F2) — same shape (carrier absent) but a separate surface; addressed in its own RFC.

## 4. Design

### 4.1 The clock is a capability, not data — split the carrier

`?clock` in OAS is `_ Eio.Time.clock` (oas `complete.mli:69`), an Eio capability resource. Storing it in `completion_request` would force a type parameter onto a record that is otherwise monomorphic pure data, polluting every consumer of the type. So the carrier is split by nature:

- **Clock**: closed over at transport construction, exactly as `sw` and `net` already are (`make_http_transport ~sw ~net`, complete.ml:1713). A transport without a clock can never arm a timeout regardless; making the clock a construction argument (not request data) is the honest encoding. 0.204.5 already added `?clock` to `make_http_transport`; this RFC keeps that.
- **Idle deadline**: a plain `float`, pure data, belongs on `completion_request` where it rides the dispatch.

This keeps `completion_request` a pure data record (no capability, no type parameter) while making the idle deadline impossible for the dispatch to drop.

### 4.2 New field on `completion_request`

`oas lib/llm_provider/llm_transport.ml` (and `.mli`):

```ocaml
type completion_request =
  { config : Provider_config.t
  ; messages : Types.message list
  ; tools : Yojson.Safe.t list
  ; stream_idle_timeout_s : float option
    (** Inter-chunk idle deadline for streaming reads, in seconds.
        Bounds the gap between streamed SSE/NDJSON lines, not total
        stream duration. [None] preserves pre-0.205.0 behaviour
        (no idle deadline; read blocks until the provider closes).
        Armed only when the transport also holds a clock (closed over
        at construction). @since 0.205.0 *)
  }
```

`option` is deliberate: `None` is the explicit "no idle deadline" state, not a silent absence. The previous failure mode was an *absent* parameter that defaulted to `None` independently at each hop; here the value is carried in the record the dispatch already forwards, so once a caller sets it, no hop can lose it without a visible record field change.

### 4.3 Dispatch passes the field through (drop becomes impossible)

`oas lib/llm_provider/complete.ml:1671-1690`, `Some t` arm:

```ocaml
| Some t ->
  t.complete_stream
    ?on_telemetry:transport_on_telemetry
    ~on_event
    { Llm_transport.config = request_config
    ; messages
    ; tools
    ; stream_idle_timeout_s   (* threaded from the high-level ?stream_idle_timeout_s *)
    }
```

The high-level `complete_stream`'s `?stream_idle_timeout_s` (complete.ml:1639) is written into the record. Because the field is mandatory in the record literal, the compiler forces every dispatch construction site to supply it — the §1.2 drop cannot recur silently.

### 4.4 Transport implementations read the field

`make_http_transport.complete_stream` passes `req.stream_idle_timeout_s` into `complete_stream_http`. The request field is the sole idle-deadline source; the transport constructor has no parallel timeout parameter. The closed-over `?clock` is retained as the capability that arms an explicit request deadline (§4.1):

```ocaml
; complete_stream =
    (fun ?on_telemetry ~on_event (req : Llm_transport.completion_request) ->
      complete_stream_http ~sw ~net ?clock
        ?stream_idle_timeout_s:req.stream_idle_timeout_s
        ~config:req.config ~messages:req.messages ~tools:req.tools
        ~on_event ?on_telemetry ())
```

`transport_openai_compat.create` (transport_openai_compat.ml:67-80) — the same: it forwards `req` (now carrying the field) to `http_transport.complete_stream`, so it inherits the deadline from the request even though `create` itself closes over no clock. This closes the §1.4 #2 latent defect: the construction-time clock can stay absent there as long as the *outer* `make_http_transport` is built with one. (If `transport_openai_compat` is used standalone with no clock anywhere, the deadline still cannot arm — documented as a known limitation; arming always requires a clock somewhere in the chain.)

### 4.5 The armed path is the existing typed-timeout chain (no new mechanism)

With the field set and a clock present, `read_sse`/`read_ndjson` reach the `Some c, Some t -> Eio.Time.with_timeout_exn c t inner` arm (http_client.ml:772, read_ndjson:804). On a mid-stream stall:

1. `Eio.Time.Timeout` raised by `with_timeout_exn` (http_client.ml:772).
2. Caught at `complete_stream_http` (complete.ml:1500) → mapped to `Http_client.TimeoutError { phase; message = "stream_idle_timeout_s deadline exceeded while …" }` (complete.ml:1521-1525). Telemetry `Telemetry_event.Timeout { timeout_type = Stream_idle … }` emitted (complete.ml:1505-1509).
3. `Http_client.TimeoutError` / `Eio.Time.Timeout` map to `Llm_provider.Error.Timeout` (verified consumer: `masc lib/keeper/keeper_error_classify.ml:185-188`, `Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _) -> true`).
4. `masc lib/keeper/keeper_unified_turn.ml:624-631`: `if EC.is_provider_timeout_error err then emit_transition … (Cancelled Cancelled_provider_timeout)`.

Every link in this chain already exists and is exercised by the `None` arm today. F1 only routes the `Some t` arm into it. The only timeout armed is the inter-chunk idle detector — I2-legitimate (a progress-based detector on transport silence, not a heuristic turn budget).

### 4.6 Clock fail-fast (close the other half of the silent-disarm)

`read_sse` arms only on `Some clock, Some idle` (http_client.ml:771-773). §4.2–4.5 make the *idle* impossible to drop, but the *clock* reaches the transport through a silent fallback that can yield `None`:

```ocaml
(* masc runtime_agent.ml ~365 (build) and ~471 (resume_from_checkpoint) *)
let clock =
  match Process_eio.get_clock () with
  | Ok c -> Some c
  | Error _ -> Eio_context.get_clock_opt ()   (* itself an option; can be None *)
```

`Process_eio.get_clock` returns `Error` when the process runtime atomic is uninitialised (`process_eio.ml:104-107`, `init not called`); `Eio_context.get_clock_opt` returns `Atomic.get current_clock` (`eio_context.ml:121-122`), which is `None` until set. If both are empty, `clock = None` flows to `read_sse` → the `None, Some t` arm → bare `Buf_read.line` → the same hang the idle carrier was meant to prevent. This is silent disarm — the manifesto's anti-pattern and a direct violation of "Parse, don't validate" — and the idle field alone does not close it.

Design item (masc-side, part of this RFC's consumer scope): when a `stream_idle_timeout_s` is configured but no clock is resolvable, **fail-fast**, do not silently proceed unarmed.

```ocaml
let clock =
  match Process_eio.get_clock (), Eio_context.get_clock_opt () with
  | Ok c, _ -> Some c
  | Error _, (Some _ as c) -> c
  | Error e, None ->
    (* A configured idle deadline cannot be armed without a clock.
       Proceeding would silently disarm the only I2-legitimate
       timeout and let a mid-stream stall hang to the 1800s watchdog. *)
    (match config.stream_idle_timeout_s with
     | Some _ -> failwith ("runtime_agent: idle deadline configured but no clock: " ^ e)
     | None -> None)
```

The exact failure form (raise vs `Error` return vs a startup assertion that a clock is always installed before any keeper turn) is an implementation choice for the masc PR; the constraint is that `Some idle, None clock` must not silently become a no-op. Production keepers always run inside an initialised `Process_eio` runtime, so this fires only on a genuine wiring regression — which is exactly when it must be loud.

## 5. Files & signatures changed

### 5.1 OAS (`agent_sdk`)

| File | Change |
|---|---|
| `lib/llm_provider/llm_transport.ml` | Add `stream_idle_timeout_s : float option` to `completion_request`. |
| `lib/llm_provider/llm_transport.mli` | Mirror the field + doc comment. |
| `lib/llm_provider/complete.ml:1671-1690` | `Some t` arm: write `stream_idle_timeout_s` into the request record. |
| `lib/llm_provider/complete.ml:1726-1737` | `make_http_transport.complete_stream`: read only `req.stream_idle_timeout_s`; no construction-time timeout fallback. |
| `lib/llm_provider/transport_openai_compat.ml:67-80` | No signature change; forwards `req` (now carrying the field). Verify no `{ config; messages; tools }` literal needs the new field — there is one literal at complete.ml dispatch; the compiler enumerates all. |
| `lib/sdk_version.ml` | Bumped by release-please (RFC-OAS-010); minor `feat`. |

Compiler enumeration: every `{ Llm_transport.config = …; … }` record literal must now supply `stream_idle_timeout_s`. `rg 'Llm_transport.config =' lib/ test/ bin/` and `rg '{ config =' lib/llm_provider` enumerate them. Each is updated with the value it has in scope, or `stream_idle_timeout_s = None` if it has none. This is the Parse-don't-validate payoff — the compiler, not a reviewer, finds every construction site.

### 5.2 masc (consumer)

masc populates the request-borne idle through `Builder.with_stream_idle_timeout`; `patch_request` uses `{ req with config = … }`, which carries the field untouched. The transport constructor accepts the clock capability but no idle value, so there is one timeout source. masc must also enforce the §4.6 clock fail-fast because a configured deadline without a clock cannot arm.

| File | Change |
|---|---|
| `lib/runtime/runtime_agent.ml` ~365 / ~471 (clock derivation in `build` / `resume_from_checkpoint`) | **Required** — §4.6 fail-fast: a configured `stream_idle_timeout_s` with no resolvable clock must error, not silently proceed unarmed. |
| `lib/runtime/runtime_agent.ml:236-240` (`patch_request`) | Preserve the request-borne `stream_idle_timeout_s`; it is the only idle-timeout source. |
| `masc.opam:31`, `dune-project:56` | Bump pin to the OAS release carrying the field (`>= 0.205.0`). |

Back-compat verified: masc constructs `Llm_transport.completion_request` only via `{ req with … }` (the single site `runtime_agent.ml:236`; `rg 'Llm_transport.completion_request' lib/` returns one hit). Adding an `option` field to the OAS record therefore does not break masc compilation. This is what makes the migration ordering (§6) non-breaking on the masc side.

## 6. Migration order (neither repo breaks)

1. **OAS PR**: add the optional field, fix the dispatch arm and transport readers, add the test (§7.1). The field is `option` and threaded by record literal/functional update; existing OAS callers compile after the compiler-enumerated literals are updated. Back-compatible for downstream: masc's `{ req with … }` carries the new field for free.
2. **OAS release**: release-please minor bump → `0.205.0`. Release note describes only the `agent_sdk` surface (§9).
3. **masc pin bump + clock fail-fast**: `masc.opam` / `dune-project` to `>= 0.205.0`. Remove any constructor-time idle argument, keep the request field authoritative, and reject a configured deadline when no clock is available.
4. **Verify armed** (§7.2 + §7.4): confirm a stalled stream produces `Cancelled_provider_timeout` at the keeper FSM with the configured idle deadline (120s), not the 1800s watchdog; and that a `None`-clock keeper fails fast rather than hanging.
5. **Only after step 4**: the F2 follow-up may downgrade/retune the 1800s attempt watchdog and livelock threshold (DIAGNOSIS §5). Doing this before step 4 removes the only backstop while the real idle detector is still proven-or-not — resurrecting I1. This ordering is a hard constraint, not a preference.

## 7. Test plan

### 7.1 OAS — the test must drive the `Some t` transport arm

The bug lives only in the transport arm. `complete_stream_http` (the `None` arm) already arms idle correctly, so a test calling it directly **passes with the bug present** and guards nothing. The regression test must construct a transport via `make_http_transport` and drive the dispatch with `~transport:(Some …)`:

`test/test_transport_liveness.ml` (new):

1. In-process slow line server (reuse the `line_server` pattern from `test/test_eio_cancellability.ml:31-83`): send `HTTP/1.1 200` SSE headers, emit one `data:` line, then go silent with the socket held open.
2. Build a transport: `Complete.make_http_transport ~clock ~sw ~net ()`.
3. Drive `Complete.complete_stream ~sw ~net ~clock ~stream_idle_timeout_s:0.2 ~transport:(Some t) ~config ~messages ~on_event …`.
4. Assert the result is `Error (Http_client.TimeoutError { phase = Stream_idle _ ; _ })` (the `timeout_phase` constructor at http_client.ml:45 is `Stream_idle of stream_idle_state`) — or `Llm_provider.Error.Timeout` after the retry mapping — within `idle_timeout + tolerance`, **not** a hang and **not** `End_of_file`.
5. Second case — dispatch with high-level `~stream_idle_timeout_s:0.2`; assert the request-borne field arms the timeout through the transport arm. This is the §4.3 guarantee.
6. Negative case: `stream_idle_timeout_s = None` everywhere → bare read → server then sends `End_of_file`; assert normal completion, no spurious timeout (preserves pre-0.205.0 behaviour).

### 7.2 masc — typed timeout reaches the keeper FSM

`test/test_keeper_provider_timeout_fsm.ml` (or extend the existing keeper turn test):

1. Inject a `Llm_provider.Error.Timeout` (or drive a stub transport that raises `Eio.Time.Timeout` mid-stream) through the keeper turn path.
2. Assert `Keeper_error_classify.is_provider_timeout_error` returns `true` (keeper_error_classify.ml:188).
3. Assert the FSM emits `Keeper_turn_fsm.Cancelled Cancelled_provider_timeout` (keeper_unified_turn.ml:630-631), not a generic `Failure_provider_error`.
4. Assert the elapsed deadline matches the configured `stream_idle_timeout_sec` (120s default, env_config_keeper.ml:398-402), not the 1800s attempt watchdog. This is the I2-vs-heuristic discriminator: a legitimate idle timeout fires in seconds-to-minutes; the 1800s watchdog identifies itself by its duration.

### 7.4 masc — clock fail-fast (§4.6)

1. Drive the keeper turn clock-resolution path with `Process_eio` uninitialised and `Eio_context.current_clock = None`, and `config.stream_idle_timeout_s = Some 120.`.
2. Assert it raises (or returns `Error`) with a message naming the missing clock — **not** a `None` clock that proceeds to a bare read.
3. Companion: with a clock resolvable and `stream_idle_timeout_s = None`, assert no failure and unarmed read (legitimate opt-out path).

### 7.3 Build gates

- `scripts/dune-local.sh build` clean in OAS; the compiler-enumerated record literals (§5.1) all updated.
- `scripts/check-sdk-independence.sh` passes — the field is plain OCaml (`float option`), no masc/keeper naming leaks into `lib/`.
- masc builds against the bumped pin; the only masc code change is the §4.6 fail-fast (no `completion_request` literal change needed — §5.2 confirms masc constructs the request only via `{ req with … }`).

## 8. Why a typed carrier / tradeoffs

### 8.1 Why a `completion_request` field, not `?clock ?stream_idle_timeout_s` params on the transport

Adding labeled params to the transport's `complete_stream` function type changes that type. masc assigns a lambda to it (`runtime_agent.ml:251`, `transport_openai_compat.ml:73-79`); changing the type means those lambdas no longer unify — a **simultaneous cross-repo break**, a broken-main window during the version bump. A field on `completion_request` rides through untouched: the dispatch forwards the record, masc's wrapper uses `{ req with config = … }` (runtime_agent.ml:236-240) which carries a new field without naming it, and OAS ships it as non-breaking minor `feat`, not `feat!`. The field approach is also the only one that makes the drop *unrepresentable* — optional params that default to `None` at each hop are precisely the failure mode that caused S1 (§1.2). Putting the deadline in the value the dispatch already threads makes losing it a visible record-field change, caught by the compiler.

### 8.2 Why the clock stays a construction capability

`Eio.Time.clock` is a capability resource (`_ Eio.Time.clock`), not data. Forcing it into `completion_request` adds a type parameter to a pure data record, polluting every consumer. Closing it over at construction (like `sw`/`net`) is the honest encoding: a transport with no clock cannot arm a timeout, period, and the type should not pretend otherwise. Tradeoff: a transport author who builds with no clock anywhere in the chain silently has no idle deadline. The masc clock derivation (`runtime_agent.ml` ~365/~471) has an `Error _ -> get_clock_opt ()` branch that can resolve to `None`, so the production path does **not** unconditionally supply a clock — this is the silent-disarm the §4.6 fail-fast closes. The idle carrier (this RFC's core) and the clock fail-fast (§4.6) are both required to make "configured deadline is actually armed" hold; the carrier alone closes the dispatch drop but leaves the clock half open. This RFC scopes both because they are the two halves of the same `Some c, Some t` precondition.

### 8.3 Precedent — httpx and gRPC

- **httpx** (the transport under the Anthropic and OpenAI Python SDKs) exposes `connect`, `read` (per-chunk/socket-read idle), `write`, and `pool` timeouts, and deliberately has **no total/wall-clock timeout** for streaming responses. Empirical proof that a per-chunk idle deadline is sufficient to bound a stalled stream without a heuristic total. This RFC arms exactly that: an inter-chunk idle deadline, no total.
- **gRPC** propagates a `deadline` as an explicit field carried across every call boundary (client → channel → server), not as an ambient or per-hop-defaulted parameter. The `completion_request` field is the same shape: the deadline is data that travels with the request, so no boundary can drop it.

### 8.4 Alternative — keep the 0.204.5 construction-capability and patch `transport_openai_compat`

Rejected. Closing the clock over each transport is a per-author obligation enforced by nobody; the dropped-deadline stays representable, and the next transport added to the SDK reintroduces the hang. v0.204.5 already demonstrates the spiral: it fixed one transport (masc's) and left `transport_openai_compat` unarmed (§1.4 #2). Patching that one transport repeats the N-of-M anti-pattern (CLAUDE.md §Workaround Rejection Bar §3). The field makes the property hold by construction for all transports.

### 8.5 Alternative — a `stream_liveness : { clock; idle } option` blob on the request

Rejected. It pulls the clock capability into the pure data record (§8.2) and couples two things with different lifetimes (clock = construction capability; idle = per-request data). The split in §4.1 is cleaner and keeps the record monomorphic.

## 9. Backward compatibility & release

- The field is `float option`; existing record literals updated to `None` preserve current behaviour. Downstream consumers using `{ req with … }` (masc) compile unchanged.
- Breaking only for code that constructs `completion_request` from a positional/exhaustive literal — within OAS, enumerated and fixed by the compiler (§5.1). masc has one consumer and it uses functional update (§5.2), so masc does not break.
- Release-please entry: `feat(transport): carry stream_idle_timeout_s on completion_request (RFC-OAS-026)` → minor bump `0.205.0`.
- Release note (SDK-surface only):
  > Starting `agent_sdk` 0.205.0, `Llm_transport.completion_request` carries an optional `stream_idle_timeout_s`. When set (and a clock is available to the transport), a streaming read that stalls mid-stream beyond the deadline raises `Http_client.TimeoutError` instead of blocking until the provider closes the socket. The built-in HTTP transport and any transport that forwards the request inherit this automatically. Consumers constructing `completion_request` literals must add the field (`None` preserves prior behaviour).

2026-07-14 hard cut: `make_http_transport` no longer accepts a parallel construction-time idle value, and OAS no longer injects provider-kind defaults when the request field is `None`. Callers that relied on the constructor argument must move the value to the request/agent option; there is deliberately no compatibility fallback. `None` now means disabled throughout the transport boundary.

## 10. Risks

### 10.0 Does F1 prevent the 2026-06-08 recurrence? (reconciled)

The DIAGNOSIS forensic measured the incident stall at 1772s ≈ the 1800s watchdog cap (§3), implying masc's idle deadline was disarmed at incident; but §1.4 shows masc's transport is armed today. The reconciliation, verified by date:

- `agent_sdk` v0.204.5 (the version that added `?clock ?stream_idle_timeout_s` to `make_http_transport`) is tagged **2026-06-09 01:53** (`git log -1 --format=%ci v0.204.5`) — **after** the 2026-06-08 incident. At incident, masc ran a pre-0.204.5 SDK where the idle half was *fully* dropped (no carrier, no construction-capability). The forensic 1772s is consistent: the only backstop was the 1800s watchdog. This is DIAGNOSIS finding #1, confirmed — not a clock-None or TLS case.
- F1 therefore *completes* and *structurally locks* a fix that v0.204.5 began as a per-transport construction-capability. It prevents recurrence on the dispatch/idle axis **provided a clock is present** — which makes §4.6 (clock fail-fast) and §10.1 (TLS interrupt) the two remaining ways a stall could still reach the watchdog. Both are scoped here (§4.6) or tracked as a precondition (§10.1). The honest claim: F1 + §4.6 close the idle and clock halves of the typed-error path; §10.1 governs whether the *physical* TLS interrupt also lands.

### 10.1 TLS read cancellability (confidence: medium)

`test/test_eio_cancellability.ml` proves `Eio.Time.with_timeout_exn` interrupts `Buf_read.line` over **raw TCP loopback** (`line_server`, test_eio_cancellability.ml:31-83) — no TLS. Production https providers run the same `Buf_read.line` over a TLS-wrapped flow. The masc owner comment at `keeper_llm_bridge.ml` names TLS as a suspect for an unidentified ≥1170s production hang. After F1 arms the idle deadline, it is still unverified that `with_timeout_exn` cancellation actually interrupts a `single_read` blocked inside a TLS session (the TLS layer may buffer or hold the read in a way that does not propagate cancellation to the socket). Mitigation: extend the regression test with a TLS-wrapped in-process server (self-signed cert) and assert the timeout fires within tolerance. If TLS read cancellation does not propagate, F1 arms the *typed error path* but the *physical interrupt* still depends on the watchdog — which would mean §6 step 5 (downgrading the watchdog) must wait for a TLS-specific fix. This risk does not block F1; it bounds how far the follow-up watchdog removal can go.

### 10.2 Idle-deadline SSOT

`completion_request.stream_idle_timeout_s` is the only idle-deadline value. The HTTP transport constructor owns only capabilities (`clock`, `sw`, `net`) and cannot introduce a competing timeout.

### 10.3 Telemetry volume

The armed path emits a `Telemetry_event.Timeout` on each stall (complete.ml:1505). At the configured 120s idle this is rare; no expected volume regression. Cross-ref RFC-OAS-019 (the stream-summary already emits a terminal classification).

## 11. Open items

- Whether `transport_openai_compat.create` should also accept `?clock` at construction for the standalone case (no outer `make_http_transport`). Deferred — its production use is always wrapped.
- Whether the `phase` in `TimeoutError` should distinguish first-byte stall (TTFT) from mid-stream stall for operator attribution. The `stream_idle_state` label already carries this (complete.ml:1502); confirm it survives the retry mapping.
- TLS cancellability (§10.1) is tracked as a precondition for the F2 watchdog-removal follow-up, not for this RFC.
