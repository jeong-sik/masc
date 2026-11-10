open Alcotest
open Masc

(* The runtime-probe route never runs a probe: the server's probe loop does.
   A read serves the loop's latest value, or a warming-up envelope before the
   first probe lands.

   "No probe on the request path" is asserted with a deterministic invocation
   COUNTER ([slow_runner_invoked]), not a wall-clock threshold. The
   [refresh_state] field of the response is asserted directly, so every
   freshness branch (warming_up / served_stale / recent / fresh) is verified by
   state transition rather than by timing. If a change makes a read call
   [run_dashboard_runtime_probe], [slow_runner_invoked] becomes 1 and these
   tests fail. *)

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

(* P1: failure-visibility contract. When a probe raises, the
   failure envelope kept as the value must carry probe_ok=false and a
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

(* force=1 with a stale cache value: the route serves the stale value at once
   (no probe on the request path) and tags it [served_stale]: the read woke the
   probe loop, which announces runtime_probe when its probe lands. *)
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
  check bool "cache_hit false (value is stale, the loop was woken)" false
    (cache_hit_of json);
  check (option string) "stale value served verbatim" (Some "stale-cache-value")
    (probe_marker_of json);
  reset_probe_seams ()

(* force=1 within the recent-value window: the recent value is served as a hit
   and tagged [recent]; the loop is not woken (force rate limit) and the
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

(* A value younger than the TTL is served as a [fresh] hit, verbatim, and
   the read runs no probe. *)
let test_fresh_hit_serves_fresh_without_probe () =
  reset_probe_seams ();
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_runner_for_tests
    slow_runner;
  slow_runner_invoked := 0;
  let fresh_probe =
    `Assoc
      [ "probe_ok", `Bool true
      ; "status", `String "reachable"
      ; "marker", `String "fresh-value"
      ]
  in
  (* Within the cache TTL (30s) and outside the force window (10s). *)
  Server_dashboard_http_runtime_info.set_dashboard_runtime_probe_cache_for_tests
    ~probe:fresh_probe ~age_sec:20.0 ();
  let json =
    Server_dashboard_http_runtime_info.dashboard_runtime_probe_http_json ()
  in
  check int "slow runner never invoked on a fresh hit" 0 !slow_runner_invoked;
  check string "refresh_state is fresh" "fresh" (refresh_state_of json);
  check bool "cache_hit true (value within TTL)" true (cache_hit_of json);
  check (option string) "fresh value served verbatim" (Some "fresh-value")
    (probe_marker_of json);
  reset_probe_seams ()

(* ---- Switch-bearing pins (#22067) -------------------------------------------

   The tests above run without an Eio server switch, so the branch that only
   exists under one stays unexercised there: the concurrent provider fan-out in
   [dashboard_runtime_probe_payload_json_of_runtimes]. Each pin below installs
   a switch as the server root switch (as the server boot path does) for the
   duration of one test and restores the previous Eio context afterwards, so
   the switch never leaks into the switch-less tests. *)

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
  ; request_path = None
  ; wire_kind = None
  ; max_context = None
  ; transport = Http url
  ; is_non_interactive = true
  ; credentials = Some (Inline "probe-test-token")
  ; account_home = None
  ; capabilities = None
  ; healthcheck_path = None
  ; headers = None
  ; connect_timeout_s = None
  ; exact_body_timeout_s = None
  ; admission_priority_run_limit = None
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
  ; capabilities = None
  }

let fanout_binding ~provider_id ~is_default =
  { Runtime_schema.provider_id
  ; model_id = "qwen"
  ; enabled = true
  ; is_default
  ; wizard_default = false
  ; max_context = None
  ; max_concurrent = None
  ; disable_parallel_tool_use = false
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
    ; exec_ssh_endpoints = []; browser = Browser_configuration.none; machines = Machine_configuration.default; typesafeai = Runtime_schema.default_typesafeai
    ; egress_allowlists = []
    ; lsp_servers = []
    }
  in
  let materialize binding =
    match Runtime_instance.of_binding config binding with
    | Ok runtime -> runtime
    | Error reason ->
      failf "expected fan-out runtime to materialize: %s"
        (Runtime_config_error.string_of_drop_reason reason)
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
    (List.map (fun (rt : Runtime_instance.t) -> rt.id) runtimes)
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

let () =
  run "dashboard_runtime_probe_nonblocking"
    [ ( "non-blocking",
        [ test_case "cold start returns warming_up, no probe" `Quick
            test_cold_start_returns_warming_up_without_probe
        ; test_case "force=1 stale serves served_stale, no probe" `Quick
            test_force_with_stale_cache_serves_stale_without_probe
        ; test_case "force=1 recent serves recent hit, no probe" `Quick
            test_force_within_recent_window_serves_recent
        ; test_case "fresh hit serves fresh, no probe" `Quick
            test_fresh_hit_serves_fresh_without_probe
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
        ] )
    ]
