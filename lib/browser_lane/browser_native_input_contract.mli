(** Input completion contracts of the supported native Ego API. These are
    method semantics, not SDK-version guesses or physical key-state probes. *)
type method_ =
  | Click | Double_click | Drag_and_drop | Mouse_click | Press
  | Keyboard_press | Keyboard_paste | Keyboard_type | Keyboard_insert_text
  | Raw_pointer_drag

type unavailable = Raw_pointer_drag_void
type t = No_hold | Observed_receipt | Observed_native_window
  | Unattestable_raw_hold of unavailable

val contract : method_ -> t
(** [No_hold] creates no key/button-down state. [Observed_receipt] still needs
    the actual SDK receipt and the existing release judge after execution.
    [Observed_native_window] needs local interval validation before following
    effects and independent Host classification before Input settlement.
    [Unattestable_raw_hold] must be refused before any input is dispatched. *)

val unavailable : t -> unavailable option
(** [None] means this contract does not require a pre-effect refusal. It does
    not attest completion, release, or application success. *)

val message : unavailable -> string
(** Explain the native gap and explicit supported alternatives; never performs
    a replacement action or authorizes repeating uncertain input. *)
