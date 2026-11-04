(** Pure response normalization for one Keeper turn. Turn orchestration
    supplies the runtime result; this module neither reads history nor
    performs dispatch or persistence. *)

val normalize_response_text_for_finalization
  :  run_result:Runtime_agent.run_result
  -> text:string
  -> string
(** Preserves response whitespace. A typed control stop or a blank text
    becomes an empty reply. Hidden reasoning is never promoted to response
    text. *)
