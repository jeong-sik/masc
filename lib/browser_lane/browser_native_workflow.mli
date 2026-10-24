(** A finite list of native Ego Page calls followed by one native snapshot.
    Locators and waits belong to the SDK. This is a browser capability, not
    host JavaScript, a ref registry or a composition interpreter. *)
type element_state = Attached | Detached | Visible | Hidden
type load_state = Dom_content_loaded | Load | Network_idle
type selection = One of string | Many of string list
type action =
  | Click of string | Double_click of string | Hover of string
  | Fill of { selector : string; text : string }
  | Press of { selector : string; key : string }
  | Select_option of { selector : string; selection : selection }
  | Goto of string | Wait_for_url of string
  | Wait_for_selector of { selector : string; state : element_state }
  | Wait_for_load_state of load_state
type step = { action : action; timeout_ms : int option }
type snapshot_scope = Viewport | Full_page
type t = private { tab_id : int; expected_url : string; steps : step list;
  snapshot_scope : snapshot_scope; max_chars : int }

(** Strict decoder, with no fallback for unknown methods/fields. [maxChars]
    must be supplied after the caller applies its existing snapshot size policy.
    [steps] may contain at most {!max_steps} calls and at most {!max_budget_ms}
    of total execution budget (including {!snapshot_timeout_ms} for initial URL
    and final snapshot reads). [timeoutMs] is an explicit SDK timeout up to
    {!max_step_timeout_ms}; absence budgets {!default_step_timeout_ms}. *)
val max_steps : int
val default_step_timeout_ms : int
val max_step_timeout_ms : int
val snapshot_timeout_ms : int
val max_budget_ms : int
val max_window_s : float
val budget_ms : t -> int
val window_s : t -> float
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val is_effect : action -> bool

val method_name : action -> string
