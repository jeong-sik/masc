(* lib/masc_oas_bridge.ml *)
(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces cancellation safety and type isolation. Wall-clock budgets are
    advisory only and do not force-kill execution (fail-open directive). *)

(** Safe execution of a generic OAS operation.
    Requires a domain-local Eio clock and runs the operation to natural
    completion; [timeout_s] is advisory and is not used to force-kill it.
    A genuine inner transport [Eio.Time.Timeout] is converted into an error
    result.
    [Eio.Cancel.Cancelled] is always re-raised to preserve structured concurrency.

    [caller] (#10094) is a free-form identifier
    ("anti_rationalization", "operator_judge", ...) that flows into
    the timeout label so operators can distinguish which trusted OAS
    caller timed out at which configured budget.  Callers must pass
    [~caller] explicitly or use {!run_with_caller}, which accepts a
    typed caller and pulls the configured budget from
    [Env_config_oas_bridge]. *)
let timeout_overshoot_warn_ratio = 2.0

let run_safe ~caller ~timeout_s fn =
  if
    Float.classify_float timeout_s = FP_nan
    || Float.classify_float timeout_s = FP_infinite
    || Float.compare timeout_s 0.0 <= 0
  then
    invalid_arg
      (Printf.sprintf
         "Masc_oas_bridge.run_safe: timeout_s must be positive and finite \
          (got %.6g)"
         timeout_s);
  match Masc_eio_env.get_opt () with
  | None ->
    let message =
      Printf.sprintf
        "Masc_oas_bridge.run_safe: Eio environment not initialized; refusing \
         to run without timeout enforcement (caller=%s, budget=%.1fs)"
        caller timeout_s
    in
    Log.Misc.error "%s" message;
    Error
      (Keeper_internal_error.sdk_error_of_masc_internal_error
         (Keeper_internal_error.Internal_bridge_exception
            { caller; exn_repr = message }))
  | Some { Masc_eio_env.clock; _ } ->
    let t0 = Eio.Time.now clock in
    let elapsed () = Eio.Time.now clock -. t0 in
    (* No wall-clock budget kill (fail-open; RFC-0156 withdrew the MASC turn-budget
       timeout policy — total attempt time is observable, not a kill decision).
       [timeout_s] is advisory only and is NOT used to force-kill the OAS
       execution: a wall budget that fired while a provider was legitimately still
       streaming turned slow-but-healthy calls into kill -> Error -> retry churn.
       The call runs to natural completion. A genuine inner transport timeout (the
       provider's own connect/idle deadline raising [Eio.Time.Timeout]) is still
       surfaced below, and structured cancellation is still re-raised. *)
    try
      fn ()
    with
  | Eio.Time.Timeout ->
    (* #10094: per-caller timeout counter so the operator can see
       WHICH caller is timing out at WHICH configured budget instead
       of collapsing all OAS timeouts into the same "after N.Ns"
       string. *)
    let wall = elapsed () in
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_oas_bridge_timeout
      ~labels:[
        ("caller", caller);
        ("timeout_s", Printf.sprintf "%.1f" timeout_s);
      ] ();
    (* #18476: wall-clock overshoot detection. Eio cancel propagation
       through the runtime runner's nested Switch layers can take
       significant time after the budget fires.  Log the overshoot
       ratio so operators can distinguish "timeout fired at 45s" from
       "timeout fired but cleanup took 121s". *)
    let overshoot_ratio = wall /. timeout_s in
    if overshoot_ratio > timeout_overshoot_warn_ratio then
      Log.Misc.warn
        "masc_oas_bridge: timeout overshoot — budget=%.1fs wall=%.1fs \
         (ratio=%.1fx, caller=%s). Cancel propagation through runtime \
         runner Switch hierarchy is delayed."
        timeout_s wall overshoot_ratio caller
    else
      Log.Misc.warn
        "masc_oas_bridge: OAS execution timed out after %.1fs (caller=%s, wall=%.1fs)"
        timeout_s caller wall;
    Error
      (Agent_sdk.Error.Api
         (Timeout
            { message = Printf.sprintf "Execution timed out after %.1fs" timeout_s
            ; phase = None
            }))
  | Eio.Cancel.Cancelled inner_exn as exn ->
    (* Mirror of #10942 (keeper_llm_bridge) for masc_oas_bridge: same opaque
       cancel message ate both wall-duration class and the inner cancel reason.
       Bucket boundaries come from the shared Cancel_wall_bucket SSOT so metric
       queries can union the two sources into one bimodal view. [inner=...]
       surfaces the parent fiber's exception payload so [Eio.Cancel.Cancel_hook]
       vs supervisor-pause vs runtime-rotation can be told apart at the WARN
       line. *)
    let bt = Printexc.get_raw_backtrace () in
    let wall = elapsed () in
    let bucket = Cancel_wall_bucket.of_wall wall in
    let inner_str =
      match inner_exn with
      | Failure msg -> "Failure(" ^ msg ^ ")"
      | _ -> Printexc.to_string inner_exn
    in
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_oas_bridge_cancel
      ~labels:[
        ("caller", caller);
        ("bucket", bucket);
      ] ();
    (* Treat every [Eio.Cancel.Cancelled] as a routine cancellation and log it
       at INFO level. We intentionally avoid matching on Eio internal exception
       names (e.g. Fiber's Not_first race exception) because those strings are
       not a stable API and will break if Eio renames the underlying exception. *)
    Log.Misc.info
      "masc_oas_bridge: OAS execution cancelled caller=%s wall=%.1fs bucket=%s inner=%s (re-raising)"
      caller wall bucket inner_str;
    Printexc.raise_with_backtrace exn bt
  | exn ->
    let bt = Printexc.get_backtrace () in
    Log.Misc.error "masc_oas_bridge: OAS execution error (caller=%s): %s\n%s"
      caller (Printexc.to_string exn) bt;
    (* RFC-0159 Phase A: emit typed [Internal_bridge_exception] so the
       classifier can route bridge-boundary failures off the
       [Reason_internal_error] catch-all. *)
    Error
      (Keeper_internal_error.sdk_error_of_masc_internal_error
         (Keeper_internal_error.Internal_bridge_exception
            { caller; exn_repr = Printexc.to_string exn }))

(** [run_with_caller ~caller fn] — single entry point that resolves
    the per-caller timeout from [Env_config_oas_bridge] and labels
    the resulting Otel_metric_store counter.  The remaining trusted OAS
    callers are evaluator/advisory flows with caller-specific defaults
    owned by [Env_config_oas_bridge]; removed runtime-invocation
    surfaces must not reappear as hidden timeout configuration. *)
let run_with_caller ~caller fn =
  let timeout_s = Env_config_oas_bridge.timeout_sec ~caller () in
  run_safe ~caller:(Env_config_oas_bridge.caller_key caller) ~timeout_s fn
