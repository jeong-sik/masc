open Alcotest
open Masc

(* Regression tests for the runtime-probe route's non-blocking background
   refresh.

   Before the fix, a cache-miss [dashboard_runtime_probe_http_json] waited
   synchronously for [run_dashboard_runtime_probe] (up to
   [dashboard_runtime_probe_timeout_sec] = 15s), stalling the whole dashboard
   shell on every cache-miss poll and every force=1 request. The fix triggers a
   background refresh via [maybe_fork_dashboard_runtime_probe_refresh] and
   returns a stale or warming-up envelope immediately.

   The contract these tests pin is "no synchronous probe on the request path".
   That is asserted with a deterministic invocation COUNTER ([slow_runner_invoked]),
   not a wall-clock threshold: a unit test has no Eio server switch, so
   [maybe_fork_dashboard_runtime_probe_refresh] skips the background fork and the
   runner is never invoked from the request path. The [refresh_state] field of
   the response is asserted directly, so every freshness branch (warming_up /
   served_stale / recent) is verified by state transition rather than by timing.
   If a future change reintroduces a synchronous [run_dashboard_runtime_probe]
   call on the request path, [slow_runner_invoked] becomes 1 and these tests
   fail. *)

let slow_runner_invoked = ref 0

let slow_runner () : Yojson.Safe.t =
  incr slow_runner_invoked;
  (* Simulate an expensive probe (e.g. cold Ollama model load). The tests assert
     on [slow_runner_invoked], not on elapsed time; the sleep only makes a
     synchronous-call regression additionally visible as a slow run. *)
  Unix.sleepf 3.0;
  `Null

(* Inspectors for the [http_json] response envelope (top-level fields wrapping
   the [probe] value). *)

let probe_ok_of = function
  | `Assoc fields ->
    (match List.assoc_opt "probe" fields with
     | Some (`Assoc inner) ->
       (match List.assoc_opt "probe_ok" inner with
        | Some (`Bool b) -> b
        | _ -> true)
     | _ -> true)
  | _ -> true

let cache_hit_of = function
  | `Assoc fields ->
    (match List.assoc_opt "cache_hit" fields with
     | Some (`Bool b) -> b
     | _ -> false)
  | _ -> false

let refresh_state_of = function
  | `Assoc fields ->
    (match List.assoc_opt "refresh_state" fields with
     | Some (`String s) -> s
     | _ -> "?")
  | _ -> "?"

(* Pull a marker string out of the [probe] field, to prove the cached value was
   served verbatim (not replaced by a placeholder). *)
let probe_marker_of = function
  | `Assoc fields ->
    (match List.assoc_opt "probe" fields with
     | Some (`Assoc inner) ->
       (match List.assoc_opt "marker" inner with
        | Some (`String s) -> Some s
        | _ -> None)
     | _ -> None)
  | _ -> None

(* Inspectors for a bare envelope value (top-level fields), used by the
   failure-envelope contract test. *)

let envelope_probe_ok = function
  | `Assoc fields ->
    (match List.assoc_opt "probe_ok" fields with
     | Some (`Bool b) -> b
     | _ -> true)
  | _ -> true

let envelope_status = function
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | Some (`String s) -> s
     | _ -> "?")
  | _ -> "?"

let reset_probe_seams () =
  Server_runtime_probe.clear_dashboard_runtime_probe_runner_for_tests ();
  Server_runtime_probe.clear_dashboard_runtime_probe_cache_for_tests ()

(* P1: failure-visibility contract. When the background refresh raises, the
   failure envelope persisted to the cache must carry probe_ok=false and a
   distinct [unreachable] status (not [warming_up]) so the dashboard can tell
   "probe failed" apart from "probe still warming up". If this regresses to
   "log only, never cache the cause", the operator loses the failure reason. *)

let test_failure_envelope_carries_unreachable_status () =
  let envelope =
    Server_runtime_probe.dashboard_runtime_probe_failure_envelope_of_exn
      (Failure "simulated ollama timeout")
  in
  check bool "failure envelope probe_ok false" false (envelope_probe_ok envelope);
  check string "failure envelope status unreachable" "unreachable"
    (envelope_status envelope)

(* Cold start: no cache value. The route must return a warming-up placeholder
   without ever invoking the (synchronous) runner. *)
let test_cold_start_returns_warming_up_without_probe () =
  reset_probe_seams ();
  Server_runtime_probe.set_dashboard_runtime_probe_runner_for_tests
    slow_runner;
  slow_runner_invoked := 0;
  let json =
    Server_runtime_probe.dashboard_runtime_probe_http_json ()
  in
  check int "slow runner never invoked on cold start" 0 !slow_runner_invoked;
  check bool "warming-up envelope returned (probe_ok false)" false (probe_ok_of json);
  check bool "cache_hit false on cold start" false (cache_hit_of json);
  check string "refresh_state is warming_up" "warming_up" (refresh_state_of json);
  reset_probe_seams ()

(* force=1 with a stale cache value: the route must serve the stale value
   immediately (no synchronous probe) and tag it [served_stale] so the client
   knows a refresh was scheduled and the fresh value arrives on the next poll. *)
let test_force_with_stale_cache_serves_stale_without_probe () =
  reset_probe_seams ();
  Server_runtime_probe.set_dashboard_runtime_probe_runner_for_tests
    slow_runner;
  slow_runner_invoked := 0;
  let stale_probe =
    `Assoc
      [ "probe_ok", `Bool true
      ; "status", `String "reachable"
      ; "marker", `String "stale-cache-value"
      ]
  in
  (* Older than both the TTL (30s) and the force window (10s). *)
  Server_runtime_probe.set_dashboard_runtime_probe_cache_for_tests
    ~probe:stale_probe ~age_sec:100.0 ();
  let json =
    Server_runtime_probe.dashboard_runtime_probe_http_json
      ~force:true ()
  in
  check int "slow runner never invoked on force=1 stale" 0 !slow_runner_invoked;
  check string "refresh_state is served_stale" "served_stale" (refresh_state_of json);
  check bool "cache_hit false (value is stale, refresh scheduled)" false
    (cache_hit_of json);
  check (option string) "stale value served verbatim" (Some "stale-cache-value")
    (probe_marker_of json);
  reset_probe_seams ()

(* force=1 within the recent-value window: the recent value is served as a hit
   and tagged [recent]; no refresh is scheduled (force rate limit) and the
   runner is not invoked. *)
let test_force_within_recent_window_serves_recent () =
  reset_probe_seams ();
  Server_runtime_probe.set_dashboard_runtime_probe_runner_for_tests
    slow_runner;
  slow_runner_invoked := 0;
  let recent_probe =
    `Assoc
      [ "probe_ok", `Bool true
      ; "status", `String "reachable"
      ; "marker", `String "recent-cache-value"
      ]
  in
  (* Within the force window (10s). *)
  Server_runtime_probe.set_dashboard_runtime_probe_cache_for_tests
    ~probe:recent_probe ~age_sec:1.0 ();
  let json =
    Server_runtime_probe.dashboard_runtime_probe_http_json
      ~force:true ()
  in
  check int "slow runner never invoked on force=1 recent" 0 !slow_runner_invoked;
  check string "refresh_state is recent" "recent" (refresh_state_of json);
  check bool "cache_hit true (recent value within force window)" true
    (cache_hit_of json);
  check (option string) "recent value served verbatim" (Some "recent-cache-value")
    (probe_marker_of json);
  reset_probe_seams ()

(* SWR soft-TTL fresh hit: a non-force value aged past the soft-TTL (15s) but
   within the cache TTL (30s) must still be served as a [fresh] hit WITHOUT a
   synchronous probe on the request path. The background refresh the soft-TTL
   schedules is forked under a server switch in production; a unit test has no
   switch, so [maybe_fork_dashboard_runtime_probe_refresh] is a no-op here and
   the runner stays uninvoked. This pins the request-path contract for the SWR
   branch: if a future change makes the soft-TTL hit refresh synchronously (or
   downgrade the envelope), [slow_runner_invoked] becomes 1 or [refresh_state]
   stops being [fresh] and this fails. The switch-bearing assertion that the
   background refresh actually fires and pre-warms the cache needs an
   [Eio.Switch] harness and is tracked as a follow-up. *)
let test_soft_ttl_fresh_hit_serves_fresh_without_sync_probe () =
  reset_probe_seams ();
  Server_runtime_probe.set_dashboard_runtime_probe_runner_for_tests
    slow_runner;
  slow_runner_invoked := 0;
  let fresh_probe =
    `Assoc
      [ "probe_ok", `Bool true
      ; "status", `String "reachable"
      ; "marker", `String "soft-ttl-fresh-value"
      ]
  in
  (* Past the soft-TTL (15s), still within the cache TTL (30s) and outside the
     force window (10s): the soft-TTL refresh branch is taken. *)
  Server_runtime_probe.set_dashboard_runtime_probe_cache_for_tests
    ~probe:fresh_probe ~age_sec:20.0 ();
  let json =
    Server_runtime_probe.dashboard_runtime_probe_http_json ()
  in
  check int "slow runner never invoked on soft-TTL fresh hit" 0 !slow_runner_invoked;
  check string "refresh_state is fresh" "fresh" (refresh_state_of json);
  check bool "cache_hit true (value still within TTL)" true (cache_hit_of json);
  check (option string) "fresh value served verbatim" (Some "soft-ttl-fresh-value")
    (probe_marker_of json);
  reset_probe_seams ()

let () =
  run "dashboard_runtime_probe_nonblocking"
    [ ( "non-blocking",
        [ test_case "cold start returns warming_up, no probe" `Quick
            test_cold_start_returns_warming_up_without_probe
        ; test_case "force=1 stale serves served_stale, no probe" `Quick
            test_force_with_stale_cache_serves_stale_without_probe
        ; test_case "force=1 recent serves recent hit, no probe" `Quick
            test_force_within_recent_window_serves_recent
        ; test_case "soft-TTL fresh hit serves fresh, no sync probe" `Quick
            test_soft_ttl_fresh_hit_serves_fresh_without_sync_probe
        ] )
    ; ( "failure visibility",
        [ test_case "failure envelope carries unreachable status" `Quick
            test_failure_envelope_carries_unreachable_status
        ] )
    ]
