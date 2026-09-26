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
  Server_dashboard_http_runtime_info.clear_dashboard_runtime_probe_runner_for_tests ();
  Server_dashboard_http_runtime_info.clear_dashboard_runtime_probe_cache_for_tests ()

(* P1: failure-visibility contract. When the background refresh raises, the
   failure envelope persisted to the cache must carry probe_ok=false and a
   distinct [unreachable] status (not [warming_up]) so the dashboard can tell
   "probe failed" apart from "probe still warming up". If this regresses to
   "log only, never cache the cause", the operator loses the failure reason. *)

let test_failure_envelope_carries_unreachable_status () =
  let envelope =
    Server_dashboard_http_runtime_info.dashboard_runtime_probe_failure_envelope_of_exn
      (Failure "simulated ollama timeout")
  in
  check bool "failure envelope probe_ok false" false (envelope_probe_ok envelope);
  check string "failure envelope status unreachable" "unreachable"
    (envelope_status envelope)

(* Cold start: no cache value. The route must return a warming-up placeholder
   without ever invoking the (synchronous) runner. *)
let test_cold_start_returns_warming_up_without_probe () =
  reset_probe_seams ();
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_runner_for_tests
    slow_runner;
  slow_runner_invoked := 0;
  let json =
    Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json ()
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
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_runner_for_tests
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
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_cache_for_tests
    ~probe:stale_probe ~age_sec:100.0 ();
  let json =
    Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json
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
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_runner_for_tests
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
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_cache_for_tests
    ~probe:recent_probe ~age_sec:1.0 ();
  let json =
    Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json
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
   stops being [fresh] and this fails. That the background refresh actually
   fires and pre-warms the cache is pinned under a server switch by
   [test_switch_soft_ttl_hit_fires_background_refresh] below. *)
let test_soft_ttl_fresh_hit_serves_fresh_without_sync_probe () =
  reset_probe_seams ();
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_runner_for_tests
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
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_cache_for_tests
    ~probe:fresh_probe ~age_sec:20.0 ();
  let json =
    Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json ()
  in
  check int "slow runner never invoked on soft-TTL fresh hit" 0 !slow_runner_invoked;
  check string "refresh_state is fresh" "fresh" (refresh_state_of json);
  check bool "cache_hit true (value still within TTL)" true (cache_hit_of json);
  check (option string) "fresh value served verbatim" (Some "soft-ttl-fresh-value")
    (probe_marker_of json);
  reset_probe_seams ()

(* ---- Switch-bearing pins (#22067) -------------------------------------------

   The tests above run without an Eio server switch, so the two branches that
   only exist under one stay unexercised there: the concurrent provider fan-out
   in [dashboard_runtime_probe_payload_json_of_runtimes] and the soft-TTL
   background refresh forked by [maybe_fork_dashboard_runtime_probe_refresh].
   Each pin below installs a switch as the server root switch (as the server
   boot path does) for the duration of one test and restores the previous Eio
   context afterwards, so the switch never leaks into the switch-less tests. *)

let with_server_switch f =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let saved = Eio_context.snapshot_state () in
  Fun.protect
    ~finally:(fun () -> Eio_context.restore_state saved)
    (fun () ->
       Eio_context.set_switch sw;
       f sw)

(* Two runtimes on two distinct providers, so the fan-out has two
   representatives (one metadata GET per provider). The record literals mirror
   the fixtures in test_runtime_provider_auth_headers.ml. *)

let fanout_url_a = "https://probe-a.proxy.runpod.net/v1"
let fanout_url_b = "https://probe-b.proxy.runpod.net/v1"
let fanout_models_url_a = fanout_url_a ^ "/models"
let fanout_models_url_b = fanout_url_b ^ "/models"

let fanout_provider ~id ~url =
  { Runtime_schema.id
  ; enabled = true
  ; display_name = id
  ; protocol = "openai-compatible-http"
  ; api_format = Chat_completions_api
  ; wire_kind = None
  ; transport = Http url
  ; is_non_interactive = true
  ; credentials = Some (Inline "probe-test-token")
  ; capabilities = None
  ; healthcheck_path = None
  ; headers = None
  ; connect_timeout_s = None
  ; exact_body_timeout_s = None
  ; antigravity_cli = None
  ; usage_read = None
  }

let fanout_model =
  { Runtime_schema.id = "qwen"
  ; api_name = "qwen"
  ; tools_support = true
  ; max_context = Some 160000
  ; thinking_support = Some true
  ; preserve_thinking = Some false
  ; streaming = true
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_uncontrolled = false
  ; reasoning_effort = None
  ; turn_timeout_s = None
  ; wall_clock_ceiling_s = None
  ; max_prompt_bytes = None
  ; capabilities = None
  }

let fanout_binding ~provider_id ~is_default =
  { Runtime_schema.provider_id
  ; model_id = "qwen"
  ; enabled = true
  ; is_default
  ; wizard_default = false
  ; max_concurrent = None
  ; disable_parallel_tool_use = false
  ; context_marks = None
  ; max_tokens = None
  ; price_input = None
  ; price_output = None
  ; keep_alive = None
  ; num_ctx = None
  ; repeat_penalty = None
  ; repeat_last_n = None
  ; return_progress = None
  }

let fanout_runtimes () =
  let binding_a = fanout_binding ~provider_id:"probe_a" ~is_default:true in
  let binding_b = fanout_binding ~provider_id:"probe_b" ~is_default:false in
  let config =
    { Runtime_schema.providers =
        [ fanout_provider ~id:"probe_a" ~url:fanout_url_a
        ; fanout_provider ~id:"probe_b" ~url:fanout_url_b
        ]
    ; models = [ fanout_model ]
    ; bindings = [ binding_a; binding_b ]
    ; default_runtime_id = None
    ; keeper_assignments = []
    ; media_failover = []
    ; lane_decls = []
    ; exact_output_lane_decls = []
    ; exec_ssh_endpoints = []; typesafeai = Runtime_schema.default_typesafeai
    ; egress_allowlists = []
    ; lsp_servers = []
    }
  in
  let materialize binding =
    match Runtime.of_binding config binding with
    | Ok runtime -> runtime
    | Error reason ->
      failf "expected fan-out runtime to materialize: %s"
        (Runtime.string_of_drop_reason reason)
  in
  [ materialize binding_a; materialize binding_b ]

let with_provider_http_get hook f =
  Server_dashboard_http_runtime_info.set_dashboard_runtime_provider_http_get_for_tests
    hook;
  Fun.protect
    ~finally:(fun () ->
      Server_dashboard_http_runtime_info.clear_dashboard_runtime_provider_http_get_for_tests ())
    f

let models_ok_response =
  Ok (200, [ "content-type", "application/json" ], {|{"data":[]}|})

let index_of item items =
  let rec go i = function
    | [] -> None
    | x :: rest -> if String.equal x item then Some i else go (i + 1) rest
  in
  go 0 items

(* Fan-out concurrency: under a server switch the providers are probed
   concurrently, and rows still come back in input order.

   Provider A's GET yields mid-request. With the concurrent fan-out, B's GET
   starts while A is suspended, so "b-start" is recorded before "a-end". If the
   [Some _sw] branch collapses back to a sequential [List.map], the trace
   becomes a-start, a-end, b-start, b-end and this fails: one slow or dead
   provider would again serialize every probe behind it (latency = sum of
   probes instead of max). Row order and the summary guard the order
   preservation the counts / errors projection relies on. *)
let test_switch_fanout_runs_providers_concurrently_in_order () =
  let runtimes = fanout_runtimes () in
  let trace = ref [] in
  let record event = trace := event :: !trace in
  let json =
    with_server_switch @@ fun _sw ->
    with_provider_http_get
      (fun ~url ~headers:_ ~timeout_sec:_ ->
         if String.equal url fanout_models_url_a
         then (
           record "a-start";
           Eio.Fiber.yield ();
           record "a-end")
         else if String.equal url fanout_models_url_b
         then (
           record "b-start";
           record "b-end")
         else record ("unexpected:" ^ url);
         models_ok_response)
      (fun () ->
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_of_runtimes
           runtimes)
  in
  let trace = List.rev !trace in
  let trace_text = String.concat "," trace in
  check int ("two events per provider GET: " ^ trace_text) 4 (List.length trace);
  (match index_of "b-start" trace, index_of "a-end" trace with
   | Some b_start, Some a_end ->
     check bool ("B probed while A was suspended: " ^ trace_text) true
       (b_start < a_end)
   | _ -> failf "missing probe events: %s" trace_text);
  let providers = Yojson.Safe.Util.(member "providers" json |> to_list) in
  check (list string) "rows keep input order"
    (List.map (fun (rt : Runtime.t) -> rt.id) runtimes)
    (List.map
       (fun row -> Yojson.Safe.Util.(member "runtime_id" row |> to_string))
       providers);
  check int "both providers reachable" 2
    Yojson.Safe.Util.(member "summary" json |> member "reachable" |> to_int);
  check bool "probe_ok" true Yojson.Safe.Util.(member "probe_ok" json |> to_bool)

(* Fan-out isolation (the M1 fix): a non-Cancel exception from one provider
   probe must surface at the fan-out call site and must NOT fail the server
   root switch.

   The regressed shape forked each probe with [Eio.Fiber.fork ~sw] onto the
   root switch: the raise called [Switch.fail sw], which cancelled every other
   fiber on the server switch and left the caller's await cancelled or hung.
   A sentinel fiber here stands in for a sibling server background fiber. With
   the fix ([Eio.Fiber.List.map] on its own internal switch) the [Failure] is
   re-raised to the caller, the root switch carries no error, and the sentinel
   finishes once released. With the regression the call site sees [Cancelled]
   instead of the [Failure], [Switch.get_error] is [Some _], and the sentinel
   is cancelled. *)
let test_switch_fanout_raise_does_not_fail_root_switch () =
  let runtimes = fanout_runtimes () in
  let sentinel_finished = ref false in
  let outcome, root_switch_error =
    with_server_switch @@ fun sw ->
    let released, release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.await released;
      sentinel_finished := true);
    let outcome =
      with_provider_http_get
        (fun ~url ~headers:_ ~timeout_sec:_ ->
           if String.equal url fanout_models_url_a
           then failwith "probe-hook-boom"
           else models_ok_response)
        (fun () ->
           match
             Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_of_runtimes
               runtimes
           with
           | _ -> "returned"
           | exception Failure message -> "failure:" ^ message
           | exception exn -> "other:" ^ Printexc.to_string exn)
    in
    Eio.Promise.resolve release ();
    Eio.Fiber.yield ();
    outcome, Eio.Switch.get_error sw
  in
  check string "raise surfaces at the call site" "failure:probe-hook-boom"
    outcome;
  check (option string) "root switch not failed" None
    (Option.map Printexc.to_string root_switch_error);
  check bool "sibling fiber on the root switch not cancelled" true
    !sentinel_finished

(* Stale-while-revalidate: a soft-TTL hit actually fires the background
   refresh under a server switch.

   A non-force hit aged past the soft-TTL (15s) but inside the cache TTL (30s)
   must fork exactly one background run of the probe and replace the cached
   value with its output, so the next poll is pre-warmed. The switch-less
   [test_soft_ttl_fresh_hit_serves_fresh_without_sync_probe] above only shows
   the request path does not probe synchronously; it still passes if the
   soft-TTL branch stops scheduling the refresh at all, which brings back the
   TTL == poll-interval trap where every other poll lands on an expired cache.
   This pin fails in that case (runner count 0, the next poll keeps the seeded
   marker). It does not pin single-flight: the refresh finishes and clears its
   in-flight flag before the second poll, which reads a fresh cache. *)
let background_runner_invoked = ref 0

let background_runner () : Yojson.Safe.t =
  incr background_runner_invoked;
  `Assoc
    [ "probe_ok", `Bool true
    ; "status", `String "reachable"
    ; "marker", `String "background-refreshed-value"
    ]

let seeded_probe marker : Yojson.Safe.t =
  `Assoc
    [ "probe_ok", `Bool true
    ; "status", `String "reachable"
    ; "marker", `String marker
    ]

let test_switch_soft_ttl_hit_fires_background_refresh () =
  reset_probe_seams ();
  Fun.protect ~finally:reset_probe_seams @@ fun () ->
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_runner_for_tests
    background_runner;
  background_runner_invoked := 0;
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_cache_for_tests
    ~probe:(seeded_probe "soft-ttl-seeded-value") ~age_sec:20.0 ();
  let first, second =
    with_server_switch @@ fun _sw ->
    let first =
      Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json ()
    in
    Eio.Fiber.yield ();
    let second =
      Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json ()
    in
    first, second
  in
  check string "soft-TTL hit still served as fresh" "fresh"
    (refresh_state_of first);
  check (option string) "soft-TTL hit serves the seeded value"
    (Some "soft-ttl-seeded-value") (probe_marker_of first);
  check int "background refresh ran exactly once" 1 !background_runner_invoked;
  check (option string) "next poll sees the refreshed value"
    (Some "background-refreshed-value") (probe_marker_of second);
  check string "next poll is a fresh hit" "fresh" (refresh_state_of second)

(* Soft-TTL threshold: below the soft-TTL (age 5s < 15s) a hit must NOT
   schedule a refresh, even with a switch available. If the age comparison is
   dropped or the soft-TTL collapses toward 0, every poll forks a probe and the
   runner count here becomes 1. *)
let test_switch_below_soft_ttl_does_not_refresh () =
  reset_probe_seams ();
  Fun.protect ~finally:reset_probe_seams @@ fun () ->
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_runner_for_tests
    background_runner;
  background_runner_invoked := 0;
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_cache_for_tests
    ~probe:(seeded_probe "young-cache-value") ~age_sec:5.0 ();
  let json =
    with_server_switch @@ fun _sw ->
    let json =
      Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json ()
    in
    Eio.Fiber.yield ();
    json
  in
  check int "no background refresh below soft-TTL" 0 !background_runner_invoked;
  check string "young hit is fresh" "fresh" (refresh_state_of json);
  check (option string) "young value served verbatim"
    (Some "young-cache-value") (probe_marker_of json)

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
    ; ( "server switch",
        [ test_case "fan-out probes providers concurrently, rows in order" `Quick
            test_switch_fanout_runs_providers_concurrently_in_order
        ; test_case "fan-out raise does not fail the root switch" `Quick
            test_switch_fanout_raise_does_not_fail_root_switch
        ; test_case "soft-TTL hit fires one background refresh" `Quick
            test_switch_soft_ttl_hit_fires_background_refresh
        ; test_case "below soft-TTL no background refresh" `Quick
            test_switch_below_soft_ttl_does_not_refresh
        ] )
    ]
