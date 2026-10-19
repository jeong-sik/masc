(** Exact read-only Task inspection. No list/current-Keeper fallback. *)
type detail =
  { task : Masc_domain.task
  ; canonical_goal_id : string option
  ; diagnostics : Masc_domain.task_decode_diagnostics }
val detail : task_id:string -> Yojson.Safe.t -> (detail, string) result
val history : task_id:string -> Yojson.Safe.t -> (Tui_decode.task_history_event list, string) result
(** History rows must name the captured Task through [task] or [task_id].
    Conflicting identities are rejected rather than shown under that Task. *)
