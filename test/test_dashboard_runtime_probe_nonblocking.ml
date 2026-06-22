open Alcotest
open Masc

(* Regression test for the runtime-probe route's non-blocking background
   refresh.

   Before the fix, a cache-miss [dashboard_runtime_probe_http_json] waited
   synchronously for [run_dashboard_runtime_probe] (up to
   [dashboard_runtime_probe_timeout_sec] = 15s), stalling the whole dashboard
   shell on every cache-miss poll and every force=1 request. The fix triggers a
   background refresh via [maybe_fork_dashboard_runtime_probe_refresh] and
   returns a stale or warming-up envelope immediately.

   This test pins that contract: a runner hook that would block for seconds if
   called synchronously must NOT delay the [http_json] response. A unit test has
   no Eio server switch, so [maybe_fork_dashboard_runtime_probe_refresh] skips
   the background fork (no switch reachable) and [http_json] returns the
   warming-up envelope without ever invoking the runner -- the exact behavior
   that distinguishes the non-blocking route from the old synchronous one. If a
   future change reintroduces a synchronous [run_dashboard_runtime_probe] call
   on the request path, [slow_runner_invoked] becomes 1 and the wall-clock
   budget is blown, failing this test. *)

let slow_runner_invoked = ref 0

let slow_runner () : Yojson.Safe.t =
  incr slow_runner_invoked;
  (* Simulate an expensive probe (e.g. cold Ollama model load). If the route
     ever regresses to calling the runner synchronously, the wall-clock budget
     below is blown and [slow_runner_invoked] becomes 1. *)
  Unix.sleepf 3.0;
  `Null

let probe_ok_of = function
  | `Assoc fields ->
    (match List.assoc_opt "probe" fields with
     | Some (`Assoc inner) ->
       (match List.assoc_opt "probe_ok" inner with
        | Some (`Bool b) -> b
        | _ -> true)
     | _ -> true)
  | _ -> true

let test_http_json_does_not_block_on_cold_start () =
  Server_dashboard_http_runtime_info.clear_dashboard_runtime_probe_cache_for_tests ();
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_runner_for_tests
    slow_runner;
  slow_runner_invoked := 0;
  let t0 = Unix.gettimeofday () in
  let json =
    Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json ()
  in
  let elapsed = Unix.gettimeofday () -. t0 in
  check int "slow runner never invoked (no synchronous probe)" 0 !slow_runner_invoked;
  check bool "warming-up envelope returned (probe_ok false)" false (probe_ok_of json);
  check bool "http_json returns within the non-blocking budget" false
    (elapsed >= 2.0);
  Server_dashboard_http_runtime_info.clear_dashboard_runtime_probe_runner_for_tests ();
  Server_dashboard_http_runtime_info.clear_dashboard_runtime_probe_cache_for_tests ()

let () =
  run "dashboard_runtime_probe_nonblocking"
    [ "non-blocking",
        [ test_case "cold start does not block" `Quick
            test_http_json_does_not_block_on_cold_start ] ]
