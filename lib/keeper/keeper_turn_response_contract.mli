(** Pure response normalization for one Keeper turn. Turn orchestration
    supplies the runtime result; this module neither reads history nor
    performs dispatch or persistence. *)

val normalize_response_text_for_finalization
  : runtime_id:string
  -> run_result:Runtime_agent.run_result
  -> text:string
  -> tool_names:string list
  -> unit
  -> (string, Agent_core.Error.t) result
(** Preserves response whitespace and typed control-stop suppression. For a
    non-control stop, blank text is accepted only when [tool_names] is
    non-empty. Hidden reasoning is never promoted to response text. Rejection
    keeps the runtime's typed response shape and provider stop reason. *)
