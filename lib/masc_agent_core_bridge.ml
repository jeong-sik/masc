(* lib/masc_agent_core_bridge.ml *)
(** Centralized boundary between MASC subsystems and agent core.
    Enforces cancellation safety and type isolation. MASC does not own a
    wall-clock budget at this boundary. *)

type caller =
  | Anti_rationalization
  | Fusion_judge
  | Fusion_panel

let caller_key = function
  | Anti_rationalization -> "anti_rationalization"
  | Fusion_judge -> "fusion_judge"
  | Fusion_panel -> "fusion_panel"
;;

let run_safe ~caller fn =
  let caller = caller_key caller in
  let timing =
    match Masc_eio_env.get_opt () with
    | None -> None
    | Some { Masc_eio_env.clock; _ } -> Some (clock, Eio.Time.now clock)
  in
  let elapsed () =
    Option.map (fun (clock, started_at) -> Eio.Time.now clock -. started_at) timing
  in
  try fn () with
  | Eio.Time.Timeout ->
    let wall = elapsed () in
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_agent_core_bridge_timeout
      ~labels:[ "caller", caller ]
      ();
    (match wall with
     | Some wall ->
       Log.Misc.warn
         "masc_agent_core_bridge: inner AGENT_CORE timeout observed caller=%s wall=%.1fs"
         caller wall
     | None ->
       Log.Misc.warn
         "masc_agent_core_bridge: inner AGENT_CORE timeout observed caller=%s wall_unavailable"
         caller);
    let message =
      match wall with
      | Some wall -> Printf.sprintf "Inner AGENT_CORE timeout observed after %.1fs" wall
      | None -> "Inner AGENT_CORE timeout observed"
    in
    Error
      (Agent_core.Error.Api
         (Timeout
            { message; phase = None }))
  | Eio.Cancel.Cancelled inner_exn as exn ->
    let bt = Printexc.get_raw_backtrace () in
    let wall = elapsed () in
    let bucket =
      match wall with
      | Some wall -> Cancel_wall_bucket.of_wall wall
      | None -> "wall_unavailable"
    in
    let inner_str =
      match inner_exn with
      | Failure msg -> "Failure(" ^ msg ^ ")"
      | _ -> Printexc.to_string inner_exn
    in
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_agent_core_bridge_cancel
      ~labels:[
        ("caller", caller);
        ("bucket", bucket);
      ] ();
    (match wall with
     | Some wall ->
       Log.Misc.info
         "masc_agent_core_bridge: AGENT_CORE execution cancelled caller=%s wall=%.1fs bucket=%s inner=%s (re-raising)"
         caller wall bucket inner_str
     | None ->
       Log.Misc.info
         "masc_agent_core_bridge: AGENT_CORE execution cancelled caller=%s wall_unavailable inner=%s (re-raising)"
         caller inner_str);
    Printexc.raise_with_backtrace exn bt
  | exn ->
    let bt = Printexc.get_backtrace () in
    Log.Misc.error "masc_agent_core_bridge: AGENT_CORE execution error (caller=%s): %s\n%s"
      caller (Printexc.to_string exn) bt;
    (* RFC-0159 Phase A: emit typed [Internal_bridge_exception] so the
       classifier can route bridge-boundary failures off the
       [Reason_internal_error] catch-all. *)
    Error
      (Keeper_internal_error.core_error_of_masc_internal_error
         (Keeper_internal_error.Internal_bridge_exception
            { caller; exn_repr = Printexc.to_string exn }))
