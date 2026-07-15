(* lib/masc_oas_bridge.ml *)
(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Preserves cancellation safety and type isolation. Provider transport owns
    the only LLM timeout boundary. *)

(** Safe execution of a generic OAS operation.
    [Eio.Cancel.Cancelled] is always re-raised to preserve structured concurrency.

    [caller] (#10094) is a free-form identifier
    ("anti_rationalization", "operator_judge", ...) for attribution. *)
let run_safe ~caller fn =
  let t0 = Unix.gettimeofday () in
  let elapsed () = Unix.gettimeofday () -. t0 in
  try fn () with
  | Eio.Cancel.Cancelled inner_exn as exn ->
    (* Preserve wall-duration class and the inner cancellation reason.
       [inner=...] surfaces the parent fiber's exception payload so
       supervisor-pause and runtime-rotation remain distinguishable. *)
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

(** Typed-caller entry point. The bridge observes cancellation and exceptions;
    OAS Provider transport owns LLM timeout enforcement. *)
let run_with_caller ~caller fn =
  run_safe ~caller:(Env_config_oas_bridge.caller_key caller) fn
