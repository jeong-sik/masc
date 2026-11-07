(** RFC-0085 PR-5 — Unified dispatch post-processing helper.

    Every dispatch path (keeper [guarded_dispatch], MCP [dispatch_by_tag],
    inline workspace) must call
    one of these after the handler completes so the five typed observers
    fire uniformly regardless of which path produced the result. *)

(** [finalize ~outcome r] fires
    [Tool_dispatch.run_dispatch_observers outcome r] and returns [r]
    unchanged.

    [outcome] should be the typed {!Dispatch_outcome.t} chosen by the
    caller — [Handled] when the handler returned a result, [No_handler]
    when the handler registry had none. *)
val finalize
  :  outcome:Dispatch_outcome.t
  -> Tool_result.result option
  -> Tool_result.result option

(** [finalize_from_handler r] is the common case where the caller has
    no structural information about the outcome — it picks
    [Handled]/[No_handler] based on [Some]/[None]. *)
val finalize_from_handler : Tool_result.result option -> Tool_result.result option
