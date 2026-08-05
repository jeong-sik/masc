(** Unified dispatch observation helper.

    MCP dispatch paths that resolve handlers outside
    {!Tool_dispatch.guarded_dispatch} call this helper after a handler
    returns.  It fires [run_dispatch_observers] with the typed
    {!Dispatch_outcome.t} so telemetry, metrics, and audit observers see
    external MCP, keeper, and inline calls uniformly without changing the
    handler result.

    The same observation is mirrored in [Tool_dispatch.guarded_dispatch]
    because [Tool_dispatch] cannot depend on this module without
    creating a dependency cycle. *)

let finalize ~(outcome : Dispatch_outcome.t) (r : Tool_result.result option)
  : Tool_result.result option
  =
  Tool_dispatch.run_dispatch_observers outcome r;
  r
;;

let finalize_from_handler (r : Tool_result.result option) : Tool_result.result option =
  finalize ~outcome:(Dispatch_outcome.of_result_option r) r
;;
