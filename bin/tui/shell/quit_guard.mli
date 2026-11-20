(** Two-step quit confirmation over unsaved drafts or in-flight dispatches. *)

val arm : Masc_tui_types.state -> kind:Masc_tui_action_notice.quit_kind -> key:string -> unit
(** Compute the unsaved-work summary, report it on the action line, and
    capture an immutable snapshot for confirming the second press. *)

val withdraw : Masc_tui_types.state -> unit
(** Clear an armed quit confirmation and withdraw its action notice if it is
    still the active notice. *)
