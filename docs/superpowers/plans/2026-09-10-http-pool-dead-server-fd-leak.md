# HTTP Pool Dead-Server FD Leak Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the HTTP connection pool from leaking one file descriptor per request against a dead server, and stop hammering dead hosts, so a down server no longer kills the TUI with `Unix.EMFILE` within a minute on a stock macOS `ulimit -n 256`.

**Architecture:** Resource ownership and failure suppression in `lib/masc_http_client/pool.ml`, per spec `docs/superpowers/specs/2026-09-10-dead-server-resilience-design.md` (PR C section):
1. **Per-client scope** — the TCP probe has a short-lived switch; actual Piaf creation also has a dedicated child switch, owned by a daemon on the pool switch. Failed or cancelled creation closes and joins that scope before returning. Successful clients keep it through reuse; eviction and shutdown close it. This covers the construction sockets that a successful TCP probe cannot clean up, including TLS failures and cancellation.
2. **Per-host connect-failure backoff** — the existing cooldown suppresses subsequent requests after a reported failure. Already concurrent requests can still attempt connections. Backoff does not establish leak freedom; each client scope owns cleanup independently.
3. **Selected address handoff (#35386)** — pass the successful probe address to Piaf's initial DNS lookup, leaving the URI hostname and Unix socket unchanged. Disable the override after construction, including errors/cancellation, because Piaf retains the environment for later reconnects. This does not add HTTP retries or race addresses; a stalled earlier TCP probe can still consume the shared establishment deadline.

**Validation boundary:** Regression cases disable cooldown and exercise refused TCP, malformed TLS responses, stalled TLS cancellation, healthy HTTP reuse, and shutdown using real loopback sockets. These cases require execution in CI at the changed commit before claiming measured TLS FD stability; adding the tests or passing syntax checks is not that evidence. The detailed checklist below records the initial probe/backoff implementation, not a verified TLS lifetime result.

**Tech Stack:** OCaml 5, Eio (`Eio.Net`, `Eio.Switch`, `Eio.Fiber.first`), piaf 0.2.0, Alcotest, dune. Repo workflow note: the constitution's execution protocol makes CI the build boundary (no mandatory local dune builds); the regression test is committed first so CI shows it failing, then the fix turns it green.

---

### Task 1: Regression test — fd stays flat against a dead port

**Files:**
- Create: `test/test_pool_dead_server_fd.ml`
- Modify: `test/dune` (the big `(tests (names ...))` stanza starting at line 102 — add the module name next to `test_pool`, which appears around line 174)

This test compiles against the CURRENT pool code and FAILS pre-fix (measured manually before: fd 50 → 554 over 120 s of refused connects). That is the TDD red. It uses `Fd_accountant.fd_snapshot ()` (field `fd_open : int option`), which reads `/dev/fd` then `/proc/self/fd` — both available in CI (Linux) and locally (macOS).

- [ ] **Step 1: Write the failing test**

Create `test/test_pool_dead_server_fd.ml`:

```ocaml
(* Regression: requests to a dead server must not leak file descriptors.

   Pre-fix, each Pool.request against a refused port called
   [Piaf.Client.create ~sw:pool_sw] whose connect-failure path never
   released the socket bound to the pool's long-lived switch: one fd
   per request. The TUI's 2-second refresh tick issues ~9 surface GETs,
   so a dead server exhausted the stock macOS nofile=256 within a
   minute and the TUI died with Unix.EMFILE (2026-09-10, vincent mac).

   The fix (probe-first connect + per-host backoff) must hold the
   process fd count flat across 50 refused requests. *)

let closed_port () =
  (* Bind port 0, learn the assigned port, close. The address is now
     refused for the practical life of the test (nothing races to claim
     it on CI). *)
  let listen = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close listen)
    (fun () ->
       Unix.bind listen (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
       match Unix.getsockname listen with
       | Unix.ADDR_INET (_, port) -> port
       | Unix.ADDR_UNIX _ -> failwith "expected inet sockaddr")

let test_dead_server_fd_flat () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Masc_http_client.Pool.create ~sw ~env () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" (closed_port ()) in
  let fd_before = (Fd_accountant.fd_snapshot ()).fd_open in
  for _ = 1 to 50 do
    ignore
      (Masc_http_client.Pool.request pool ~method_:`GET ~url ()
        : (Masc_http_client.Pool.response, string) result)
  done;
  (* Let the scheduler run pending closes before counting. *)
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.2;
  let fd_after = (Fd_accountant.fd_snapshot ()).fd_open in
  match fd_before, fd_after with
  | Some before_, Some after_ ->
    Alcotest.(check int) "fd growth after 50 refused requests" 0
      (Int.max 0 (after_ - before_))
  | _ ->
    (* No observable fd dir on this platform: nothing to assert. *)
    ()

let () =
  Alcotest.run "Pool_dead_server_fd"
    [ ( "dead-server",
        [ Alcotest.test_case "fd stays flat over 50 refused requests"
            `Quick test_dead_server_fd_flat ] ) ]
```

Add `test_pool_dead_server_fd` to the `(names ...)` list of the `(tests ...)` stanza at `test/dune:102`, directly after the existing `test_pool` entry. That stanza's `(libraries ...)` already reaches `masc_test_deps` (which re-exports `Masc_http_client`), `fd_accountant`, `unix`, and `eio_main` — the same stanza builds `test_server_runtime_bootstrap`, whose compile line shows all four `-I` paths.

- [ ] **Step 2: Push and watch the new test fail in CI**

```bash
git add test/test_pool_dead_server_fd.ml test/dune
git commit -m "test(pool): regression — fd flat over 50 refused requests (red)"
git push -u origin fix/pool-dead-server-fd-leak
gh pr create --title "fix(pool): stop fd leak against dead servers" --body "Spec: docs/superpowers/specs/2026-09-10-dead-server-resilience-design.md (PR C). First commit is the red regression test; the fix follows."
```

Expected: the dune test job fails on `Pool_dead_server_fd` with fd growth ≈ 50 (refused port) — proving the leak in CI. If the runner's ulimit is low the suite may instead fail with EMFILE, which is equally the red we want. Continue to Task 2 without waiting idly; check `gh pr checks` before opening the fix commits.

### Task 2: Config field `connect_failure_cooldown_seconds`

**Files:**
- Modify: `lib/masc_http_client/pool.ml:22-34` (config record + `default_config`)
- Modify: `lib/masc_http_client/pool.mli:38-47` (config record + doc)
- Test: `test/test_pool.ml:94-96` (existing default-config bounds block)

The record is only constructed literally in `default_config` — no other call sites to update (verified by grepping `connect_timeout_seconds`/`max_total_idle` across lib/bin/test/packages).

- [ ] **Step 1: Write the failing bounds test**

In `test/test_pool.ml`, immediately after the existing `connect_timeout_seconds <= 30s` check (~line 96), add:

```ocaml
  Alcotest.(check bool) "connect_failure_cooldown_seconds > 0"
    true (c.connect_failure_cooldown_seconds > 0.0);
  Alcotest.(check bool) "connect_failure_cooldown_seconds <= 30s"
    true (c.connect_failure_cooldown_seconds <= 30.0);
```

- [ ] **Step 2: Verify it fails to compile**

Field does not exist yet → compile error. (In this repo the boundary is CI: push with Task 1's red test still red is fine; or a local `dune build test/test_pool.exe` for the fast loop.)

- [ ] **Step 3: Add the field**

In `lib/masc_http_client/pool.ml`:

```ocaml
type config = {
  max_idle_per_host : int;
  max_total_idle    : int;
  idle_ttl_seconds  : float;
  connect_timeout_seconds : float;
  connect_failure_cooldown_seconds : float;
}

let default_config = {
  max_idle_per_host = 8;
  max_total_idle    = 256;
  idle_ttl_seconds  = 60.0;
  connect_timeout_seconds = 5.0;
  (* TUI refresh ticks every 2 s and issues ~9 surface GETs. 5 s caps
     connect attempts against a dead host at one per 5 s (was: 9 per
     2 s), while a restarted server is picked up again within one
     operator-perceptible delay. *)
  connect_failure_cooldown_seconds = 5.0;
}
```

In `lib/masc_http_client/pool.mli`, add the field to the record and extend the doc comment after the `connect_timeout_seconds` paragraph:

```ocaml
type config = {
  max_idle_per_host : int;
  max_total_idle    : int;
  idle_ttl_seconds  : float;
  connect_timeout_seconds : float;
  connect_failure_cooldown_seconds : float;
}
```

Doc addition:

```
    [connect_failure_cooldown_seconds]: after a connect to a host fails,
    requests to that host fast-fail without opening a socket for this
    long. Suppresses requests after a reported failure; concurrent cold
    requests can already be connecting. Each client scope owns socket
    cleanup independently of the cooldown.
```

And update `default_config`'s doc line to include the new field value `5.0`.

- [ ] **Step 4: Verify the bounds test passes**

`dune build test/test_pool.exe && _build/default/test/test_pool.exe` (or CI) — the config section passes.

- [ ] **Step 5: Commit**

```bash
git add lib/masc_http_client/pool.ml lib/masc_http_client/pool.mli test/test_pool.ml
git commit -m "feat(pool): config field connect_failure_cooldown_seconds (default 5.0)"
```

### Task 3: Probe-first connect + per-host backoff in the pool

**Files:**
- Modify: `lib/masc_http_client/pool.ml` — `type t` (:113-121), `create` (:203-215), `create_fresh` (:291-299), `do_request` call site (:451), `do_request_streaming` call site (:653)
- Test: `test/test_pool_dead_server_fd.ml` (extend with backoff tests)

- [ ] **Step 1: Add backoff state to the pool**

In `type t` add one field (kept next to `idle`; same mutex discipline — no network IO under `mu`):

```ocaml
type t = {
  sw       : Eio.Switch.t;
  env      : Eio_unix.Stdenv.base;
  config   : config;
  mu       : Eio.Mutex.t;
  mutable idle : idle_entry list Host_map.t;
  (* Last connect-failure timestamp per host. A host inside
     [connect_failure_cooldown_seconds] of its last failure fast-fails
     without opening a socket. Entries age out by time comparison, so
     the map needs no sweeper; it holds at most one float per distinct
     failing host. *)
  mutable connect_failures : float Host_map.t;
  stop     : bool Atomic.t;
  counters : stats_counters;
}
```

In `create` add `connect_failures = Host_map.empty;` to the record literal.

Add the two helpers just above `create_fresh`:

```ocaml
(* ── Connect backoff ───────────────────────────────────────────── *)

let now_ts t =
  Eio.Time.now (Eio.Stdenv.clock t.env)

let connect_backoff_active t key ~now =
  with_mu t (fun () ->
    match Host_map.find_opt key t.connect_failures with
    | Some ts -> now -. ts < t.config.connect_failure_cooldown_seconds
    | None -> false)

let record_connect_failure t key ~now =
  with_mu t (fun () ->
    t.connect_failures <- Host_map.add key now t.connect_failures)
```

- [ ] **Step 2: Add the probe**

Just above `create_fresh`, add:

```ocaml
(* ── Probe-first connect ───────────────────────────────────────── *)

(* TCP-reachability probe on a short-lived child switch. piaf 0.2.0
   (pinned) does not release the socket when [Piaf.Client.create]'s
   connect fails, and the client would be bound to the pool's
   long-lived switch, so nothing ever reclaims it — one fd per failed
   request (#dead-server-emfile, 2026-09-10). Probing first confines
   the failure socket to [probe_sw], whose teardown closes it
   immediately.

   Cost: one extra TCP connect+close per fresh client, only on cache
   miss; idle-reuse requests skip this entirely. The probe is
   TCP-level for https too — TLS problems still surface from
   [Piaf.Client.create] and feed the same backoff.

   A success here followed by a refused [Piaf.Client.create] (server
   died in between) can still leak one fd; the window is narrow and
   the backoff bounds the rate. Cancelled must propagate so a dying
   fiber unwinds instead of reporting "unreachable" (RFC-0106). *)
let probe_connectable t key =
  let net = Eio.Stdenv.net t.env in
  let clock = Eio.Stdenv.clock t.env in
  let addrs =
    try
      Eio.Net.getaddrinfo_stream net key.Host_key.host
        ~service:(string_of_int key.Host_key.port)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> []
  in
  let try_addr addr =
    Eio.Fiber.first
      (fun () ->
         Eio.Switch.run (fun probe_sw ->
           try
             let flow = Eio.Net.connect ~sw:probe_sw net addr in
             Eio.Flow.close flow;
             true
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | _ -> false))
      (fun () ->
         Eio.Time.sleep clock t.config.connect_timeout_seconds;
         false)
  in
  List.exists try_addr addrs
```

- [ ] **Step 3: Rewrite `create_fresh` to gate on backoff and probe**

Replace `create_fresh` (:291-299) with:

```ocaml
(* Build a fresh piaf client for [key], gated on the per-host
   connect-failure backoff and a TCP reachability probe (see
   [probe_connectable]). Returns [Result] mirroring piaf's API so
   callers can surface DNS/TCP/TLS failures distinctly. *)
let create_fresh t key uri =
  let now = now_ts t in
  if connect_backoff_active t key ~now then
    Error
      (Printf.sprintf
         "connect backoff: %s failed recently (cooldown %.0fs)"
         (Host_key.to_string key)
         t.config.connect_failure_cooldown_seconds)
  else if not (probe_connectable t key) then begin
    record_connect_failure t key ~now:(now_ts t);
    Error
      (Printf.sprintf "connect refused: %s unreachable"
         (Host_key.to_string key))
  end
  else
    match Piaf.Client.create ~sw:t.sw t.env uri with
    | Ok c ->
      t.counters.create_count_total <- t.counters.create_count_total + 1;
      Ok c
    | Error err ->
      (* Probe passed but create failed (TLS error, or the server died
         in the narrow window): feed the same backoff so a broken
         endpoint is not hammered either. *)
      record_connect_failure t key ~now:(now_ts t);
      Error (Piaf.Error.to_string (err :> Piaf.Error.t))
```

- [ ] **Step 4: Update the two call sites**

In `do_request` (:448-452) and `do_request_streaming` (:650-654), pass `key`:

```ocaml
  let acquired =
    match try_acquire_idle t key ~now:(Eio.Time.now (Eio.Stdenv.clock t.env)) with
    | Some c -> Ok c
    | None -> create_fresh t key host_origin
  in
```

- [ ] **Step 5: Extend the regression file with backoff tests**

Append to `test/test_pool_dead_server_fd.ml`, before the `let () = Alcotest.run ...` block:

```ocaml
let error_message = function
  | Ok _ -> Alcotest.fail "expected Error from a dead server"
  | Error msg -> msg

let test_backoff_fast_fails_without_socket () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* Cooldown long enough that the second request must hit it. *)
  let config =
    { Masc_http_client.Pool.default_config with
      connect_failure_cooldown_seconds = 30.0 }
  in
  let pool = Masc_http_client.Pool.create ~sw ~env ~config () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" (closed_port ()) in
  let first = Masc_http_client.Pool.request pool ~method_:`GET ~url () in
  let first_msg = error_message first in
  Alcotest.(check bool) "first failure is a connect failure"
    true
    (Astring.String.is_prefix ~affix:"connect refused:" first_msg
     || Astring.String.is_infix ~affix:"connect" first_msg);
  let fd_mid = (Fd_accountant.fd_snapshot ()).fd_open in
  let second = Masc_http_client.Pool.request pool ~method_:`GET ~url () in
  Alcotest.(check bool) "second request fast-fails from backoff"
    true
    (Astring.String.is_prefix ~affix:"connect backoff:"
       (error_message second));
  let fd_after = (Fd_accountant.fd_snapshot ()).fd_open in
  (match fd_mid, fd_after with
   | Some mid, Some after_ ->
     Alcotest.(check int) "backoff opened no socket" 0
       (Int.max 0 (after_ - mid))
   | _ -> ())

let test_backoff_expires_and_retries () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config =
    { Masc_http_client.Pool.default_config with
      connect_failure_cooldown_seconds = 0.1 }
  in
  let pool = Masc_http_client.Pool.create ~sw ~env ~config () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" (closed_port ()) in
  ignore (Masc_http_client.Pool.request pool ~method_:`GET ~url ());
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.3;
  let retry = Masc_http_client.Pool.request pool ~method_:`GET ~url () in
  Alcotest.(check bool) "after cooldown the probe runs again"
    false
    (Astring.String.is_prefix ~affix:"connect backoff:"
       (error_message retry))

let test_probe_success_still_creates_client () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* A listener that accepts and immediately closes: TCP connectable,
     so the probe passes and [Piaf.Client.create] runs (counted), then
     the request fails at the HTTP layer — never as "connect refused"
     or "connect backoff". *)
  let listen = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listen Unix.SO_REUSEADDR true;
  Unix.bind listen (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listen 4;
  let port =
    match Unix.getsockname listen with
    | Unix.ADDR_INET (_, p) -> p
    | Unix.ADDR_UNIX _ -> assert false
  in
  let acceptor_finished = ref false in
  Eio.Fiber.fork ~sw (fun () ->
    (try
       let conn, _ = Unix.accept ~cloexec:true listen in
       Unix.close conn
     with Unix.Unix_error _ -> ());
    acceptor_finished := true);
  let pool = Masc_http_client.Pool.create ~sw ~env () in
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  let result = Masc_http_client.Pool.request pool ~method_:`GET ~url () in
  ignore (result : (Masc_http_client.Pool.response, string) result);
  let stats = Masc_http_client.Pool.stats pool in
  Alcotest.(check int) "piaf client created after successful probe" 1
    stats.create_count_total;
  ignore !acceptor_finished;
  Unix.close listen
```

And register the three new cases in the `Alcotest.run` block:

```ocaml
let () =
  Alcotest.run "Pool_dead_server_fd"
    [ ( "dead-server",
        [ Alcotest.test_case "fd stays flat over 50 refused requests"
            `Quick test_dead_server_fd_flat;
          Alcotest.test_case "backoff fast-fails without a socket"
            `Quick test_backoff_fast_fails_without_socket;
          Alcotest.test_case "backoff expires and retries" `Quick
            test_backoff_expires_and_retries;
          Alcotest.test_case "probe success still creates client" `Quick
            test_probe_success_still_creates_client ] ) ]
```

(`test_probe_success_still_creates_client` uses blocking `Unix.accept` in a forked fiber; on Eio's single domain that blocks the scheduler briefly, which is acceptable in a test — the accept unblocks as soon as the probe connects. `stats.create_count_total` is already exposed by `Pool.stats`.)

- [ ] **Step 6: Run the suite — regression test now passes**

`dune build test/test_pool_dead_server_fd.exe && _build/default/test/test_pool_dead_server_fd.exe` locally, or push and check CI. Expected: all four cases pass; fd growth 0. `test_pool` and the other pool-adjacent suites (`test_pool_metrics`, `test_host_fd_pressure_poller`) still pass.

- [ ] **Step 7: Commit and push**

```bash
git add lib/masc_http_client/pool.ml lib/masc_http_client/pool.mli test/test_pool_dead_server_fd.ml
git commit -m "fix(pool): probe-first connect + per-host connect-failure backoff

Piaf.Client.create on the pool's long-lived switch leaked one socket
per failed connect (piaf 0.2.0 pinned). Probe TCP reachability on a
short-lived child switch first so refusal reclaims the fd at switch
teardown, and back off failing hosts for
connect_failure_cooldown_seconds (default 5s) so the 2s refresh tick
no longer hammers dead servers. Regression: 50 refused requests hold
the process fd count flat (was +1 per request -> EMFILE on macOS
nofile=256 within a minute)."
git push
```

Expected: `gh pr checks` goes green, including the previously-red `Pool_dead_server_fd` suite.

## Self-review notes (done while writing)

- Spec coverage: probe-first connect → Task 3 Step 2-3; host backoff + config field with rationale → Tasks 2-3; regression test ×50 + fd flat + fail-before/pass-after via CI → Task 1 + Task 3 Step 6; piaf pinned acknowledged in probe comment and commit message. All four spec bullets have tasks.
- No placeholders: every code step shows the complete code; every verification names the command.
- Type consistency: `create_fresh t key uri` signature used identically in both call sites; `connect_failures` field name matches between `type t`, `create`, and helpers; config field name `connect_failure_cooldown_seconds` identical in ml/mli/tests; `stats.create_count_total` already exists in the public `stats` record (pool.mli:203).
- Deliberately out of scope (YAGNI): clearing a host's backoff entry on later success (time comparison already expires it), new stats counters for backoff skips (the Error message prefix is the observable), exposing `probe_connectable` in `For_testing` (covered end-to-end by the regression file).
