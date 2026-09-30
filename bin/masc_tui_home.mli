(** Home reads the shared state and approval model without making the state
    module depend on a surface projection. *)

val home_request_of_approval :
  Masc_tui_approvals_model.approval_row -> Masc_tui_types.home_request

val home_decision_rows :
  Masc_tui_types.state -> (Masc_tui_types.home_action * string) list

val home_continue_rows :
  Masc_tui_types.state -> (Masc_tui_types.home_action * string) list

val home_selected_action :
  Masc_tui_types.state -> Masc_tui_types.home_action option
(** [None] means a previously selected action is no longer present, or no
    action is available. An unselected state projects the first action. *)

val home_initial_reading_ready :
  Masc_tui_types.state -> Masc_tui_types.home_action option -> bool

val home_decision_window : Masc_tui_types.state -> budget:int -> int * int
(** Pure viewport projection: first decision row and visible capacity.
    Frame preparation stores the result; drawing does not mutate state. *)

val home_step : Masc_tui_types.state -> backwards:bool -> unit
(** Move selection through current decisions and continuation destinations. *)

val reconcile_home_request_detail : Masc_tui_types.state -> unit
(** Keep a followed request selected by authoritative identity, or return
    to Home when it is no longer current. *)
