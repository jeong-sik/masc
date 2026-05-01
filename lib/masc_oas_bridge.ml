(* lib/masc_oas_bridge.ml *)
(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces strict structural timeouts, cancellation safety, and type isolation. *)

(** Safe execution of a generic OAS operation.
    Applies timeout handling when an Eio clock is available, and converts
    [Eio.Time.Timeout] into an error result.
    [Eio.Cancel.Cancelled] is always re-raised to preserve structured concurrency.

    [caller] (#10094) is a free-form identifier ("auto_responder",
    "tool_deep_review", ...) that flows into the timeout label so
    operators can distinguish fantasy budgets from intentional ones
    when both fire timeouts in the same session.  Defaults to
    "unknown" so legacy callers still compile; new code should
    pass [~caller] explicitly or use {!run_with_caller}, which
    accepts a typed caller and pulls the configured budget from
    [Env_config_oas_bridge]. *)
let run_safe ?(caller = "unknown") ~timeout_s fn =
  let clock_opt =
    match Masc_eio_env.get_opt () with
    | Some { clock; _ } -> clock
    | None -> None
  in
  let t0 =
    match clock_opt with
    | Some clock -> Eio.Time.now clock
    | None -> Unix.gettimeofday ()
  in
  let elapsed () =
    match clock_opt with
    | Some clock -> Eio.Time.now clock -. t0
    | None -> Unix.gettimeofday () -. t0
  in
  let do_timeout fn =
    match clock_opt with
    | Some clock -> Eio.Time.with_timeout_exn clock timeout_s fn
    | None -> fn ()
  in
  try
    do_timeout fn
  with
  | Eio.Time.Timeout ->
    (* #10094: per-caller timeout counter so the operator can see
       WHICH caller is timing out at WHICH configured budget — log
       lines alone collapsed all 27 [auto_responder] 60s-timeouts
       and the 1 [tool_deep_review] 180s-timeout into the same
       "after N.Ns" string. *)
    Prometheus.inc_counter
      Prometheus.metric_oas_bridge_timeout
      ~labels:[
        ("caller", caller);
        ("timeout_s", Printf.sprintf "%.1f" timeout_s);
      ] ();
    Log.Misc.warn
      "masc_oas_bridge: OAS execution timed out after %.1fs (caller=%s)"
      timeout_s caller;
    Error (Agent_sdk.Error.Api (Timeout { message = Printf.sprintf "Execution timed out after %.1fs" timeout_s }))
  | Eio.Cancel.Cancelled inner_exn as exn ->
    (* Mirror of #10942 (keeper_llm_bridge) for masc_oas_bridge: same opaque
       cancel message ate both wall-duration class and the inner cancel reason.
       Bucket boundaries are kept identical so PromQL can union the two
       sources into one bimodal view (fast/short_tail/mid_tail/long_mid/
       long_tail). [inner=...] surfaces the parent fiber's exception payload
       so [Eio.Cancel.Cancel_hook] vs supervisor-pause vs cascade-rotation
       can be told apart at the WARN line. *)
    let bt = Printexc.get_raw_backtrace () in
    let wall = elapsed () in
    let bucket =
      if wall < 60.0 then "fast"
      else if wall < 300.0 then "short_tail"
      else if wall < 600.0 then "mid_tail"
      else if wall < 1800.0 then "long_mid"
      else "long_tail"
    in
    let inner_str =
      match inner_exn with
      | Failure msg -> "Failure(" ^ msg ^ ")"
      | _ -> Printexc.to_string inner_exn
    in
    Prometheus.inc_counter
      Prometheus.metric_oas_bridge_cancel
      ~labels:[
        ("caller", caller);
        ("bucket", bucket);
      ] ();
    Log.Misc.warn
      "masc_oas_bridge: OAS execution cancelled caller=%s wall=%.1fs bucket=%s inner=%s (re-raising)"
      caller wall bucket inner_str;
    Printexc.raise_with_backtrace exn bt
  | exn ->
    let bt = Printexc.get_backtrace () in
    Log.Misc.error "masc_oas_bridge: OAS execution error (caller=%s): %s\n%s"
      caller (Printexc.to_string exn) bt;
    Error (Agent_sdk.Error.Internal (Printexc.to_string exn))

(** [run_with_caller ~caller fn] — single entry point that resolves
    the per-caller timeout from [Env_config_oas_bridge] and labels
    the resulting Prometheus counter.  Replaces the seven hardcoded
    [run_safe ~timeout_s:N.N] literals scattered across the lib
    tree.  The original tuned values for autoresearch / deep_review
    / anti_rationalization are preserved as per-caller defaults;
    the two fantasy 60s budgets ([auto_responder],
    [dashboard_provider_runs]) are raised to the global default
    (300s) since the original 60s did not match observed p50
    latency.  See [Env_config_oas_bridge] for the full table and
    env-var override layout. *)
let run_with_caller ~caller fn =
  let timeout_s = Env_config_oas_bridge.timeout_sec ~caller () in
  run_safe ~caller:(Env_config_oas_bridge.caller_key caller) ~timeout_s fn
