(** Home projections and selection operations. Core identities and state remain
    in {!Masc_tui_types}; approval rows and readings come from their model. *)

val home_request_of_approval : Masc_tui_approvals_model.approval_row -> Masc_tui_types.home_request
val home_decision_rows : Masc_tui_types.state -> (Masc_tui_types.home_action * string) list
val clear_ask_answering : Masc_tui_types.state -> unit
val reconcile_home_request_detail : Masc_tui_types.state -> unit
val home_continue_rows : Masc_tui_types.state -> (Masc_tui_types.home_action * string) list
val home_actions : Masc_tui_types.state -> Masc_tui_types.home_action list
val home_selected_action : Masc_tui_types.state -> Masc_tui_types.home_action option
val home_initial_reading_ready : Masc_tui_types.state -> Masc_tui_types.home_action option -> bool
(** Action notices rendered before the decision window, in display order. *)
val home_notice_lines : Masc_tui_types.state -> string list
val home_decision_window : Masc_tui_types.state -> budget:int -> int * int
val home_step : Masc_tui_types.state -> backwards:bool -> unit
