(** Home projections and selection operations. Core identities and state remain
    in {!Masc_tui_types}; approval rows and readings come from their model. *)

val home_request_of_approval : Masc_tui_approvals_model.approval_row -> Masc_tui_types.home_request
(** Immutable Home reading for one synchronous UI operation. Prepare again after
    source, selection or notice changes; never retain across an await. Pinning
    its resolved initial selection in the same Build preserves its reading.
    It contains no execution authority and does not store terminal state. *)
type prepared
val prepare : Masc_tui_types.state -> prepared
val home_decision_rows : prepared -> (Masc_tui_types.home_action * string) list
val clear_ask_answering : Masc_tui_types.state -> unit
val reconcile_home_request_detail : Masc_tui_types.state -> unit
val home_continue_rows : prepared -> (Masc_tui_types.home_action * string) list
val home_selected_action : prepared -> Masc_tui_types.home_action option
val home_selection_changed : prepared -> bool
val home_initial_reading_ready : prepared -> bool
(** Action notices rendered before the decision window, in display order. *)
val home_notice_lines : prepared -> string list
val home_requests_budget : prepared -> chrome_budget:int -> int
(** The rows left for the decision window out of the body's [chrome_budget]:
    one less while the one-time help line is shown, and one less for the
    requests link. Never negative. *)
val home_decision_window : prepared -> scroll:int -> budget:int -> int * int
(** [scroll] is the current viewport input, so a Build may store its clamped
    window and render again against a changed terminal height using the same
    immutable reading. *)
val home_step : Masc_tui_types.state -> backwards:bool -> unit
