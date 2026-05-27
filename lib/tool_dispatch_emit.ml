(** Unified dispatch post-processing helper.

    MCP dispatch paths that resolve handlers outside
    {!Tool_dispatch.guarded_dispatch} call this helper after a handler
    returns.  It centralises the two side-effects that every dispatch
    path must run after the handler completes:

    1. Apply the registered [result_transformer] (e.g. Tool_output_validation
       output cap) when the [Handled] arm fires.
    2. Fire [run_dispatch_observers] with the typed {!Dispatch_outcome.t}
       so telemetry, metrics, and audit observers see external MCP,
       keeper, and inline calls uniformly.

    The same ordering is mirrored in [Tool_dispatch.guarded_dispatch]
    because [Tool_dispatch] cannot depend on this module without
    creating a dependency cycle. *)

let finalize ~(outcome : Dispatch_outcome.t) (r : Tool_result.t option)
  : Tool_result.t option
  =
  let r' =
    match r with
    | Some tr -> Some (Tool_dispatch.apply_result_transformer tr)
    | None -> r
  in
  Tool_dispatch.run_dispatch_observers outcome r';
  r'
;;

let finalize_from_handler (r : Tool_result.t option) : Tool_result.t option =
  let outcome : Dispatch_outcome.t =
    match r with
    | Some _ -> Handled
    | None -> No_handler
  in
  finalize ~outcome r
;;
