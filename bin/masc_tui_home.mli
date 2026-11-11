(** Home projections and selection operations. Core identities and state remain
    in {!Masc_tui_types}; approval rows and readings come from their model. *)

val home_request_of_approval : Masc_tui_approvals_model.approval_row -> Masc_tui_types.home_request
val open_approvals : Masc_tui_types.state -> navigate:(Masc_tui_types.surface -> unit) -> unit
(** Open the complete approval list and preserve the caller as its return
    destination. [navigate] performs the ordinary destination preparation. *)

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
val home_operator_rows : prepared -> (Masc_tui_types.home_action * string) list
val operator_action_label : Masc_tui_types.state -> Masc.Operator_action_reason.t -> string
val home_selected_action : prepared -> Masc_tui_types.home_action option
val home_initial_reading_ready : prepared -> bool
(** Action notices rendered before the decision window, in display order. *)
val home_notice_lines : prepared -> string list
type body = private {
  hb_help : bool;
  hb_shortcuts : bool;
  hb_notices : string list;
  hb_selection_changed : bool;
  hb_rows : (Masc_tui_types.home_action * string) list;
  hb_first : int;
  hb_total : int;
  hb_spare : int;
}
val home_body : prepared -> scroll:int -> budget:int -> body
(** Renderer and loop share this body allocation. A positive available body
    reserves a selected destination row before optional chrome and notices. *)
val home_step : Masc_tui_types.state -> backwards:bool -> unit
