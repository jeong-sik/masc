(** RFC-0085 PR-5 — Unified dispatch post-processing helper.

    Centralises the two side-effects that every dispatch path must run
    after the handler completes:

    1. Apply the registered [result_transformer] (e.g. Tool_output_validation
       output cap) when the [Handled] arm fires.
    2. Fire [run_typed_post_hooks] with the typed {!Dispatch_outcome.t}
       so all five observers (Tool_metrics, Tool_usage_log,
       Otel_dispatch_hook, Tool_output_validation, server_bootstrap_loops)
       see every external MCP / keeper / inline call uniformly.

    Before PR-5, only [Tool_dispatch.guarded_dispatch] fired typed
    hooks, so external MCP [tools/call] traffic flowed silently
    through [Tool_metrics] et al.  RFC-0085 §"Root Gap 1". *)

let finalize ~(outcome : Dispatch_outcome.t) (r : Tool_result.t option)
  : Tool_result.t option
  =
  let r' =
    match r with
    | Some tr -> Some (Tool_dispatch.apply_result_transformer tr)
    | None -> r
  in
  Tool_dispatch.run_typed_post_hooks outcome r';
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
