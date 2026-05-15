(** RFC-0085 PR-5 — Unified dispatch post-processing helper.

    Every dispatch path (keeper [guarded_dispatch], MCP [dispatch_by_tag],
    MCP [dispatch_internal_keeper_runtime_tool], inline coord) must call
    one of these after the handler completes so the five typed observers
    fire uniformly regardless of which path produced the result. *)

(** [finalize ~outcome r] applies [Tool_dispatch.apply_result_transformer]
    on the result (when [Some _]) and fires
    [Tool_dispatch.run_typed_post_hooks outcome r'].

    [outcome] should be the typed {!Dispatch_outcome.t} chosen by the
    caller — [Handled] when the handler returned a result, [No_handler] /
    [Rejected_by_pre_hook] / [Rejected_by_capability] / [Handler_error]
    for the corresponding arms. *)
val finalize
  :  outcome:Dispatch_outcome.t
  -> Tool_result.t option
  -> Tool_result.t option

(** [finalize_from_handler r] is the common case where the caller has
    no structural information about the outcome — it picks
    [Handled]/[No_handler] based on [Some]/[None]. *)
val finalize_from_handler : Tool_result.t option -> Tool_result.t option
