(** Complete immutable Task documents shared by actual list and source readers. *)
val body_lines : cols:int -> goal_lines:string list -> Masc_domain.task -> string list
val history_lines : width:int -> view:Masc.Tui_decode.task_history_event list Masc_tui_fetched.view -> in_flight:bool -> string list
